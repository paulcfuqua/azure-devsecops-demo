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
        param([switch]$NoRetry)
        Invoke-Main -Repository $script:Repository -ReportRoot $script:ReportRoot -NoRetry:$NoRetry
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
        It 'records V1.1-V1.4 as PASS and exits 0' {
            $context = Invoke-AuditForTest
            @($context.Criterion).Count | Should -Be 4
            @($context.Criterion | Where-Object { $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            @($context.Criterion).Id | Should -Be @('V1.1', 'V1.2', 'V1.3', 'V1.4')
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'records the exact query it ran and the expectation for each criterion' {
            $context = Invoke-AuditForTest
            (Get-Row -Context $context -Id 'V1.2').Command | Should -BeLike '*gh api repos/paulcfuqua/azure-devsecops-demo*'
            (Get-Row -Context $context -Id 'V1.2').Expected | Should -Be '{"ss":"enabled","pp":"enabled"}'
            (Get-Row -Context $context -Id 'V1.4').Expected | Should -BeLike '*repo:paulcfuqua/azure-devsecops-demo:environment:demo*'
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
        It 'records V1.4 as FAIL and still evaluates the other three criteria' {
            Mock Invoke-MlsGraph { throw 'Authorization_RequestDenied: Insufficient privileges to complete the operation.' }
            $context = Invoke-AuditForTest -NoRetry
            @($context.Criterion).Count | Should -Be 4
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
