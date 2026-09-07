# Pester tests for verification/layer-01-audit.ps1 - every gh, git and Graph call mocked;
# zero cloud calls, no tenant required.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-01-audit.ps1')
    # NO `Set-StrictMode -Off` here. The audit script sets -Version Latest and CI runs
    # it that way; a harness that relaxes the language mode cannot see the class of
    # bug that mode exists to catch, and did not (F49).

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l01-$([guid]::NewGuid().ToString('n'))"
    $script:Repository = 'paulcfuqua/azure-devsecops-demo'
    $script:TokenVariable = @('MLS_VERIFIER_GH_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')
    $script:IdentityVariable = @('AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'FABRIC_CAPACITY_ID')
    $script:SavedEnvironment = @{}
    foreach ($name in ($script:TokenVariable + $script:IdentityVariable)) {
        $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    function Get-Row {
        param($Context, [string]$Id)
        return @($Context.Criterion | Where-Object { $_.Id -eq $Id })[0]
    }

    function Invoke-AuditForTest {
        param([switch]$NoRetry, [string]$GovernanceModePath = '', [string]$CodeownersPath = '')
        $argument = @{
            Repository = $script:Repository
            ReportRoot = $script:ReportRoot
            NoRetry    = $NoRetry
        }
        if ($GovernanceModePath) { $argument['GovernanceModePath'] = $GovernanceModePath }
        if ($CodeownersPath) { $argument['CodeownersPath'] = $CodeownersPath }
        Invoke-Main @argument
    }
}

AfterAll {
    foreach ($name in $script:SavedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:SavedEnvironment[$name])
    }
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:ReportRoot) {
        Remove-Item -LiteralPath $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'layer-01-audit' {
    BeforeEach {
        $env:GH_TOKEN = 'ghp-verifier-read-only'
        # GENERATED, never committed. These must not be repeating-digit ids - those appear
        # throughout the repo's fixtures and are therefore allowlisted, which made every test
        # look like the estate had laundered its live identifiers into that list (F62). The
        # first fix wrote three realistic-looking LITERALS instead, and V1.3 immediately and
        # correctly flagged them: a committed GUID that is not on the allowlist is exactly
        # what that sweep exists to find, and a test fixture is still a committed file (F68).
        #
        # A fresh guid each run is both: never committed, and never allowlisted.
        $env:AZURE_TENANT_ID = [guid]::NewGuid().ToString()
        $env:AZURE_SUBSCRIPTION_ID = [guid]::NewGuid().ToString()
        $env:FABRIC_CAPACITY_ID = [guid]::NewGuid().ToString()

        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'

        $script:RunConclusion = 'success'
        $script:JobConclusion = 'success'
        $script:SecretScanning = 'enabled'
        $script:PushProtection = 'enabled'
        # V1.5's subjects: what main enforces, and whether this identity can read it.
        $script:RequiredApprovals = 0
        $script:RulesReadable = $true
        # The SECOND switch on the same rule, defaulted OFF so every test written before
        # it existed still describes the case it was written for.
        $script:RequireCodeOwnerReview = $false
        $script:Subject = 'repo:paulcfuqua/azure-devsecops-demo:environment:demo'
        $script:Issuer = 'https://token.actions.githubusercontent.com'

        Mock Invoke-MlsGh {
            $joined = $Argument -join ' '
            if ($joined -like 'run list*') {
                return @([pscustomobject]@{ databaseId = 4242; conclusion = $script:RunConclusion; status = 'completed'; createdAt = '2026-08-24T09:00:00Z' })
            }
            if ($joined -like '*actions/runs/4242/jobs*') {
                return [pscustomobject]@{ jobs = @(
                        [pscustomobject]@{ name = 'oidc-login'; conclusion = $script:JobConclusion }
                        [pscustomobject]@{ name = 'summary'; conclusion = 'success' }
                    )
                }
            }
            if ($joined -like '*rules/branches/main*') {
                # What Invoke-MlsGh -AllowFailure actually yields on a denied or 404 read:
                # $null, not an exception. Mocking a throw here would have tested a
                # different code path from the one production takes.
                if (-not $script:RulesReadable) { return $null }
                return @(
                    [pscustomobject]@{ type = 'deletion' }
                    [pscustomobject]@{
                        type       = 'pull_request'
                        parameters = [pscustomobject]@{
                            required_approving_review_count = $script:RequiredApprovals
                            require_code_owner_review       = $script:RequireCodeOwnerReview
                        }
                    }
                )
            }
            if ($joined -like "api repos/$($script:Repository)") {
                return [pscustomobject]@{
                    security_and_analysis = [pscustomobject]@{
                        secret_scanning                 = [pscustomobject]@{ status = $script:SecretScanning }
                        secret_scanning_push_protection = [pscustomobject]@{ status = $script:PushProtection }
                    }
                }
            }
            throw "unexpected gh call: $joined"
        }

        Mock Invoke-MlsGit {
            # exit code 1 == git grep found nothing == the passing case
            return [pscustomobject]@{ ExitCode = 1; Line = @() }
        }

        Mock Invoke-MlsGraph {
            # federatedIdentityCredentials first: '?' is a single-character wildcard in
            # -like, so an '*applications?*' pattern would also swallow this URI.
            if ($Uri -like '*federatedIdentityCredentials*') {
                return [pscustomobject]@{ value = @([pscustomobject]@{
                            name    = 'github-demo'
                            issuer  = $script:Issuer
                            subject = $script:Subject
                        })
                }
            }
            if ($Uri -like '*/applications*') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'app-object-id'; displayName = 'mls-github-deployer' }) }
            }
            throw "unexpected Graph call: $Uri"
        }
    }

    Context 'all criteria pass' {
        It 'records V1.1-V1.5 as PASS and exits 0' {
            # V1.5 reads the repository's own .github/governance-mode.json here rather than
            # a fixture, so this also asserts the committed declaration agrees with the
            # ruleset the mock reports - development mode, zero required approvals.
            $context = Invoke-AuditForTest
            @($context.Criterion).Count | Should -Be 5
            @($context.Criterion | Where-Object { $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            @($context.Criterion).Id | Should -Be @('V1.1', 'V1.2', 'V1.3', 'V1.4', 'V1.5')
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'records the exact query it ran and the expectation for each criterion' {
            $context = Invoke-AuditForTest
            (Get-Row -Context $context -Id 'V1.2').Command | Should -BeLike '*gh api repos/paulcfuqua/azure-devsecops-demo*'
            (Get-Row -Context $context -Id 'V1.2').Expected | Should -Be '{"ss":"enabled","pp":"enabled"}'
            (Get-Row -Context $context -Id 'V1.4').Expected | Should -BeLike '*repo:paulcfuqua/azure-devsecops-demo:environment:demo*'
        }
    }

    Context 'V1.5: the declared governance mode matches what main actually enforces' {
        # The mode was true, load-bearing and written down nowhere. CODEOWNERS asserted
        # review was enforced - citing NIST 3.4.3 and 3.1.5 - while the ruleset required
        # ZERO approvals, so every reader believed in a control that did not exist. This
        # criterion is what stops the declaration and the enforcement drifting apart, in
        # either direction: declaring operational without flipping the setting is the
        # dangerous one, and it is the one a human is most likely to do.
        BeforeAll {
            # Declared in BeforeAll, not in the Context body: a function defined in the
            # body exists only during Pester DISCOVERY and is gone by the time an It runs.
            # SupportsShouldProcess because the name carries a state-changing verb and it
            # writes a file; PSScriptAnalyzer runs at Error+Warning over verification/ and
            # a test helper is not exempt from the rules the audits are held to.
            function Set-Mode {
                [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
                param([string]$Mode, [int]$Development = 0, [int]$Operational = 1)
                if (-not $PSCmdlet.ShouldProcess($script:ModePath, 'write mode fixture')) { return }
                @{
                    mode        = $Mode
                    enforcement = @{
                        development = @{ requiredApprovingReviewCount = $Development }
                        operational = @{ requiredApprovingReviewCount = $Operational }
                    }
                } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:ModePath -Encoding utf8
            }
        }
        BeforeEach {
            $script:ModePath = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-mode-$([guid]::NewGuid().ToString('n')).json"
        }
        AfterEach {
            Remove-Item -LiteralPath $script:ModePath -Force -ErrorAction SilentlyContinue
        }

        It 'passes in development mode when main requires no approvals' {
            Set-Mode -Mode 'development'
            $script:RequiredApprovals = 0
            $context = Invoke-AuditForTest -GovernanceModePath $script:ModePath
            $row = Get-Row -Context $context -Id 'V1.5'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*development*'
        }

        It 'fails when operational mode is declared but approvals were never turned on' {
            # The transition half-done: someone said production, nobody flipped the switch.
            Set-Mode -Mode 'operational'
            $script:RequiredApprovals = 0
            $row = Get-Row -Context (Invoke-AuditForTest -GovernanceModePath $script:ModePath) -Id 'V1.5'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*operational*declares 1*enforces 0*'
        }

        It 'fails when main enforces more than the declared mode claims' {
            # Drift in the safe direction is still drift: the documents are wrong.
            Set-Mode -Mode 'development'
            $script:RequiredApprovals = 1
            (Get-Row -Context (Invoke-AuditForTest -GovernanceModePath $script:ModePath) -Id 'V1.5').Status |
                Should -Be 'FAIL'
        }

        It 'SKIPs rather than reporting the control absent when the rules cannot be read' {
            # F63/F105: an identity that cannot see a setting must never report it as off.
            # The Verifier's token is deliberately read-only and may not be able to read
            # branch rules at all - that is a property of the identity, not of the control.
            Set-Mode -Mode 'development'
            $script:RulesReadable = $false
            $row = Get-Row -Context (Invoke-AuditForTest -GovernanceModePath $script:ModePath) -Id 'V1.5'
            $row.Status | Should -Be 'SKIP'
            $row.Observed | Should -BeLike '*cannot read*'
            $row.Observed | Should -Not -BeLike '*not enforced*'
        }

        It 'SKIPs when the declared mode file is missing, naming what to create' {
            $row = Get-Row -Context (Invoke-AuditForTest -GovernanceModePath (Join-Path ([IO.Path]::GetTempPath()) 'no-such-mode.json')) -Id 'V1.5'
            $row.Status | Should -Be 'SKIP'
            $row.Observed | Should -BeLike '*governance-mode.json*'
        }

        # THE HALF THIS CRITERION COULD NOT SEE.
        #
        # `require_code_owner_review` is a second, independent switch on the same
        # pull_request rule. With a catch-all CODEOWNERS pattern it requires an approval
        # on EVERY pull request while required_approving_review_count still reads 0 - so
        # a check that compares only the count reports PASS over a repository whose
        # declared policy ("0 reviews, self-approval authorized") is not the enforced one.
        #
        # Measured on this repository, not theorised: PR #174 held 12/12 green required
        # checks, mergeable=MERGEABLE and auto-merge armed for five days, and moved
        # BLOCKED -> CLEAN the moment a code owner approved it.
        Context 'the code-owner switch, which the count cannot see' {
            BeforeEach {
                $script:CodeownersPath = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-codeowners-$([guid]::NewGuid().ToString('n'))"
            }
            AfterEach {
                Remove-Item -LiteralPath $script:CodeownersPath -Force -ErrorAction SilentlyContinue
            }

            It 'FAILS a declared zero when a catch-all owner makes every PR need approval' {
                Set-Mode -Mode 'development'
                $script:RequiredApprovals = 0
                $script:RequireCodeOwnerReview = $true
                Set-Content -LiteralPath $script:CodeownersPath -Encoding utf8 -Value @(
                    '# every path has an owner',
                    '*                       @paulcfuqua',
                    '/verification/          @paulcfuqua')
                $row = Get-Row -Context (Invoke-AuditForTest -GovernanceModePath $script:ModePath -CodeownersPath $script:CodeownersPath) -Id 'V1.5'
                $row.Status | Should -Be 'FAIL'
                $row.Observed | Should -BeLike '*require_code_owner_review is ON*'
                # Names the offending line, so the reader does not have to hunt for it.
                $row.Observed | Should -BeLike '*line 2*'
                $row.Observed | Should -BeLike "*'*'*@paulcfuqua*"
            }

            It 'PASSES when ownership is scoped to the sensitive paths instead' {
                # The policy this repository actually states: the paths that DEFINE safety
                # need a second party, and nothing else does. A heal PR touching a
                # lockfile has no owner and merges unattended, which is the product claim.
                Set-Mode -Mode 'development'
                $script:RequiredApprovals = 0
                $script:RequireCodeOwnerReview = $true
                Set-Content -LiteralPath $script:CodeownersPath -Encoding utf8 -Value @(
                    '/.github/workflows/     @paulcfuqua',
                    '/verification/          @paulcfuqua',
                    '/infra/                 @paulcfuqua')
                (Get-Row -Context (Invoke-AuditForTest -GovernanceModePath $script:ModePath -CodeownersPath $script:CodeownersPath) -Id 'V1.5').Status |
                    Should -Be 'PASS'
            }

            It 'PASSES a catch-all when the code-owner switch is OFF, because then it gates nothing' {
                # Ownership without require_code_owner_review requires no approval. The
                # criterion must not fail on a file that has no effect.
                Set-Mode -Mode 'development'
                $script:RequiredApprovals = 0
                $script:RequireCodeOwnerReview = $false
                Set-Content -LiteralPath $script:CodeownersPath -Encoding utf8 -Value @('*  @paulcfuqua')
                (Get-Row -Context (Invoke-AuditForTest -GovernanceModePath $script:ModePath -CodeownersPath $script:CodeownersPath) -Id 'V1.5').Status |
                    Should -Be 'PASS'
            }

            It 'PASSES a catch-all in operational mode, where an approval is required anyway' {
                # A catch-all is not wrong per se - it only contradicts a declared ZERO.
                Set-Mode -Mode 'operational'
                $script:RequiredApprovals = 1
                $script:RequireCodeOwnerReview = $true
                Set-Content -LiteralPath $script:CodeownersPath -Encoding utf8 -Value @('*  @paulcfuqua')
                (Get-Row -Context (Invoke-AuditForTest -GovernanceModePath $script:ModePath -CodeownersPath $script:CodeownersPath) -Id 'V1.5').Status |
                    Should -Be 'PASS'
            }

            It 'does not treat a pattern with no owner as a catch-all' {
                # `*` alone grants ownership to nobody and therefore gates nothing.
                Set-Mode -Mode 'development'
                $script:RequiredApprovals = 0
                $script:RequireCodeOwnerReview = $true
                Set-Content -LiteralPath $script:CodeownersPath -Encoding utf8 -Value @('*', '# nobody owns anything')
                (Get-Row -Context (Invoke-AuditForTest -GovernanceModePath $script:ModePath -CodeownersPath $script:CodeownersPath) -Id 'V1.5').Status |
                    Should -Be 'PASS'
            }

            It 'does not mistake a commented-out catch-all for a live one' {
                Set-Mode -Mode 'development'
                $script:RequiredApprovals = 0
                $script:RequireCodeOwnerReview = $true
                Set-Content -LiteralPath $script:CodeownersPath -Encoding utf8 -Value @(
                    '#  *   @paulcfuqua   <- removed 2026-09-07',
                    '/verification/          @paulcfuqua')
                (Get-Row -Context (Invoke-AuditForTest -GovernanceModePath $script:ModePath -CodeownersPath $script:CodeownersPath) -Id 'V1.5').Status |
                    Should -Be 'PASS'
            }

            It 'treats a missing CODEOWNERS as no owners rather than as unreadable' {
                # GitHub with no CODEOWNERS has no code owners, so the switch gates
                # nothing. That is a readable state, not a blind spot - the F63/F105 rule
                # is about an API returning emptiness on denial, not a file that is simply
                # not there.
                Set-Mode -Mode 'development'
                $script:RequiredApprovals = 0
                $script:RequireCodeOwnerReview = $true
                (Get-Row -Context (Invoke-AuditForTest -GovernanceModePath $script:ModePath -CodeownersPath (Join-Path ([IO.Path]::GetTempPath()) 'no-such-codeowners')) -Id 'V1.5').Status |
                    Should -Be 'PASS'
            }
        }
    }

    Context 'a criterion fails on a realistic wrong value' {
        It 'fails V1.2 when push protection is disabled, and exits 1' {
            $script:PushProtection = 'disabled'
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V1.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Be '{"ss":"enabled","pp":"disabled"}'
            Get-MlsExitCode -Context $context | Should -Be 1
        }

        It 'fails V1.4 when the federated subject is a branch wildcard instead of the environment binding' {
            $script:Subject = 'repo:paulcfuqua/azure-devsecops-demo:ref:refs/heads/*'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V1.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*refs/heads/**'
            $row.Detail | Should -BeLike '*Do not widen the subject*'
        }

        It 'fails V1.3 when a live identifier has been added to the GUID allowlist' {
            # The allowlist made "make V1.3 green" cheap in two ways: remove the id, or list
            # it. Listing it must be the louder failure of the two, or the check becomes a
            # formality that certifies whatever it was told (F62).
            Mock Get-AllowedGuid { @($env:AZURE_TENANT_ID.ToLowerInvariant(), 'b24988ac-6180-42a0-ab88-20f7382dd24c') }
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V1.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*live estate identifier*'
            $row.Detail | Should -BeLike '*never be allowlisted*'
        }

        It 'fails V1.3 when a committed identifier is found' {
            Mock Invoke-MlsGit {
                if (($Argument -join ' ') -like "*$($env:AZURE_TENANT_ID)*") {
                    return [pscustomobject]@{ ExitCode = 0; Line = @("infra/bicep/main.bicep:12: tenantId: '$($env:AZURE_TENANT_ID)'") }
                }
                return [pscustomobject]@{ ExitCode = 1; Line = @() }
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V1.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*committed identifier*'
        }
    }

    Context 'retry' {
        It 'retries V1.1 while the run is still failing and passes without sleeping the whole window' {
            $script:Calls = 0
            Mock Invoke-MlsGh {
                $joined = $Argument -join ' '
                if ($joined -like 'run list*') {
                    $script:Calls++
                    $conclusion = if ($script:Calls -lt 2) { 'in_progress' } else { 'success' }
                    return @([pscustomobject]@{ databaseId = 4242; conclusion = $conclusion; status = 'completed'; createdAt = '2026-08-24T09:00:00Z' })
                }
                if ($joined -like '*jobs*') {
                    $jobConclusion = if ($script:Calls -lt 2) { 'in_progress' } else { 'success' }
                    return [pscustomobject]@{ jobs = @([pscustomobject]@{ name = 'oidc-login'; conclusion = $jobConclusion }) }
                }
                return [pscustomobject]@{
                    security_and_analysis = [pscustomobject]@{
                        secret_scanning                 = [pscustomobject]@{ status = 'enabled' }
                        secret_scanning_push_protection = [pscustomobject]@{ status = 'enabled' }
                    }
                }
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V1.1'
            $row.Status | Should -Be 'PASS'
            $row.Attempt | Should -Be 2
            # One poll interval, not the whole window - asserted against the row's own
            # cadence rather than a literal, so right-sizing the defaults (F59) cannot
            # silently turn this into a test of a constant nobody re-checked.
            $row.SleptSeconds | Should -Be $row.PollIntervalSecond
            $row.SleptSeconds | Should -BeLessThan ($row.RetryWindowMinutes * 60)
            Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 1
        }
    }

    Context 'a check that throws' {
        It 'records V1.4 as FAIL and still evaluates the other criteria' {
            Mock Invoke-MlsGraph { throw 'Authorization_RequestDenied: Insufficient privileges to complete the operation.' }
            $context = Invoke-AuditForTest -NoRetry
            @($context.Criterion).Count | Should -Be 5
            $row = Get-Row -Context $context -Id 'V1.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*Authorization_RequestDenied*'
            (Get-Row -Context $context -Id 'V1.1').Status | Should -Be 'PASS'
            Get-MlsExitCode -Context $context | Should -Be 1
        }
    }

    Context 'no GUID allowlist on disk' {
        It 'counts zero allowed GUIDs instead of dying before the first criterion' {
            # Reproduces the CI failure directly: "layer-01-audit could not start: The
            # property Count cannot be found on this object." Neither allowlist source
            # exists on a fresh estate - guid-allowlist.txt is not committed, and
            # reports/label-guids.json is written by L4 - so Get-AllowedGuid emitted an
            # empty pipeline, which unrolls to nothing, and the preflight read .Count on
            # it under the Set-StrictMode -Version Latest the script sets at line 42.
            $emptyRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l01-noallow-$([guid]::NewGuid().ToString('n'))"
            New-Item -ItemType Directory -Path $emptyRoot -Force | Out-Null
            try {
                $context = Invoke-Main -Repository $script:Repository -ReportRoot $script:ReportRoot -RepoRoot $emptyRoot -NoRetry
                $row = @($context.Preflight | Where-Object { $_.Name -eq 'GUID allowlist entries' })
                $row.Count | Should -Be 1
                $row[0].Value | Should -Be '0'
            } finally {
                Remove-Item -LiteralPath $emptyRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'missing input' {
        It 'refuses to run without the Verifier GitHub token and names how to supply it' {
            foreach ($name in $script:TokenVariable) { [Environment]::SetEnvironmentVariable($name, $null) }
            { Invoke-AuditForTest } | Should -Throw '*GitHubToken*'
            { Invoke-AuditForTest } | Should -Throw '*MLS_VERIFIER_GH_TOKEN*'
        }

        It 'records V1.3 as SKIP, never a silent pass, when the three identifiers are absent' {
            foreach ($name in $script:IdentityVariable) { [Environment]::SetEnvironmentVariable($name, $null) }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V1.3'
            $row.Status | Should -Be 'SKIP'
            $row.Detail | Should -BeLike '*AZURE_TENANT_ID*'
            Get-MlsExitCode -Context $context | Should -Be 0
        }
    }
}
