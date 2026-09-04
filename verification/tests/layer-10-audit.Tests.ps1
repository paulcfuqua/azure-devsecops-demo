# Pester tests for verification/layer-10-audit.ps1 - every gh and az call mocked;
# zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-10-audit.ps1')
    # No Set-StrictMode -Off: the audit scripts set -Version Latest and CI runs them
    # that way, so the harness must not relax the language mode it is testing (F49).

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l10-$([guid]::NewGuid().ToString('n'))"
    $script:Repository = 'paulcfuqua/azure-devsecops-demo'
    $script:Automation = 'github-actions[bot]'
    $script:EnvironmentVariable = @('MLS_VERIFIER_GH_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN', 'MLS_L10_CODEQL_ALERT',
        'MLS_L10_AUTOFIX_PR', 'MLS_L10_DEPENDABOT_ALERTS', 'MLS_L10_RESEED_MERGED_AT')
    $script:SavedEnvironment = @{}
    foreach ($name in $script:EnvironmentVariable) { $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

    function Get-Row {
        param($Context, [string]$Id)
        return @($Context.Criterion | Where-Object { $_.Id -eq $Id })[0]
    }

    function Invoke-AuditForTest {
        param(
            [switch]$NoRetry,
            [string]$CodeQlAlertNumber = '7',
            [string]$AutofixPrNumber = '31',
            [string[]]$DependabotAlertNumber = @('3', '4', '5'),
            [string]$ReseedMergedUtc = '',
            # The healthy PRECONDITION for the rest of the suite: the select job
            # could read the alert surface. This is an input the chain reports, in
            # the same way $script:Trail is an input - not V10.3's answer, which is
            # exercised explicitly in both directions in its own Context below.
            [string]$AlertSurfaceReadable = 'true'
        )
        Invoke-Main -Repository $script:Repository -CodeQlAlertNumber $CodeQlAlertNumber -AutofixPrNumber $AutofixPrNumber `
            -DependabotAlertNumber $DependabotAlertNumber -VulnLabAppName 'mls-vuln-lab-demo-ca' `
            -ResourceGroupName 'mls-rg-apps' -AutomationLogin $script:Automation -ReseedMergedUtc $ReseedMergedUtc `
            -ChainWindowHours 24 -DependencyPassBar 2 -AlertSurfaceReadable $AlertSurfaceReadable `
            -ReportRoot $script:ReportRoot -NoRetry:$NoRetry
    }
}

AfterAll {
    foreach ($name in $script:EnvironmentVariable) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnvironment[$name]) }
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:ReportRoot) {
        Remove-Item -LiteralPath $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'layer-10-audit' {
    BeforeEach {
        foreach ($name in $script:EnvironmentVariable) { [Environment]::SetEnvironmentVariable($name, $null) }
        $env:GH_TOKEN = 'ghp-verifier-read-only'
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'

        $script:AutofixStatus = 'success'
        $script:AutofixDescription = 'Escape the user-controlled value before interpolating it into the query.'
        $script:CodeQlState = 'fixed'
        $script:DependabotState = 'fixed'
        $script:MergedBy = $script:Automation
        # Merged by default. Set to '' for the state the chain is actually in for most of
        # its life: auto-merge armed, PR still open, nothing merged yet.
        $script:MergedAt = '2026-08-24T10:30:00Z'
        $script:AutoMerge = [pscustomobject]@{ enabledBy = 'github-actions[bot]' }
        $script:CheckConclusion = 'success'
        $script:PrBody = "Autofix says: $($script:AutofixDescription)"
        # The witness revision the deploy stage looks for: created after the merge AND
        # stamped with that merge's commit by .github/workflows/vuln-lab-witness.yml.
        $script:MergeCommit = [pscustomobject]@{ oid = 'mergecommitsha' }
        $script:Revision = @([pscustomobject]@{
                name       = 'mls-vuln-lab-demo-ca--rev7'
                created    = '2026-08-24T11:00:00Z'
                healCommit = 'mergecommitsha'
            })
        $script:DependabotPr = @(
            [pscustomobject]@{ number = 41; title = 'Bump lodash from 4.17.20 to 4.17.21'; headRefName = 'dependabot/npm_and_yarn/lodash-4.17.21' }
            [pscustomobject]@{ number = 42; title = 'Bump minimist from 1.2.5 to 1.2.8'; headRefName = 'dependabot/npm_and_yarn/minimist-1.2.8' }
            [pscustomobject]@{ number = 43; title = 'Bump axios from 0.21.1 to 0.21.4'; headRefName = 'dependabot/npm_and_yarn/axios-0.21.4' }
        )
        $script:DependabotPackage = @{ '3' = 'lodash'; '4' = 'minimist'; '5' = 'axios' }

        Mock Invoke-MlsGh {
            $joined = $Argument -join ' '
            if ($joined -like '*code-scanning/alerts/*/autofix*') {
                return [pscustomobject]@{ status = $script:AutofixStatus; description = $script:AutofixDescription; started_at = '2026-08-24T10:05:00Z' }
            }
            if ($joined -like '*code-scanning/alerts/*') {
                return [pscustomobject]@{ state = $script:CodeQlState; created_at = '2026-08-24T10:00:00Z'; rule = [pscustomobject]@{ id = 'js/sql-injection' } }
            }
            if ($joined -match 'dependabot/alerts/(?<n>\d+)') {
                $number = $Matches['n']
                return [pscustomobject]@{
                    state      = $script:DependabotState
                    created_at = '2026-08-24T10:00:00Z'
                    dependency = [pscustomobject]@{ package = [pscustomobject]@{ name = $script:DependabotPackage[$number] } }
                }
            }
            if ($joined -like 'pr list*') { return $script:DependabotPr }
            if ($joined -like 'pr view*') {
                return [pscustomobject]@{
                    number           = 31
                    headRefOid       = 'autofixsha'
                    body             = $script:PrBody
                    commits          = @([pscustomobject]@{ oid = 'autofixsha' })
                    mergedAt         = $script:MergedAt
                    mergedBy         = [pscustomobject]@{ login = $script:MergedBy }
                    autoMergeRequest = $script:AutoMerge
                    mergeCommit      = $script:MergeCommit
                    state            = 'MERGED'
                    title            = 'Fix js/sql-injection'
                }
            }
            if ($joined -like '*check-runs*') {
                return [pscustomobject]@{ check_runs = @(
                        [pscustomobject]@{ name = 'CodeQL'; conclusion = $script:CheckConclusion }
                        [pscustomobject]@{ name = 'Trivy'; conclusion = 'success' }
                        [pscustomobject]@{ name = 'ZAP'; conclusion = 'success' }
                    )
                }
            }
            throw "unexpected gh call: $joined"
        }

        Mock Invoke-MlsAz {
            if (($Argument -join ' ') -like 'containerapp revision list*') { return $script:Revision }
            throw "unexpected az call: $($Argument -join ' ')"
        }
    }

    Context 'all criteria pass' {
        It 'records V10.1-V10.3 as PASS and exits 0' {
            $context = Invoke-AuditForTest
            @($context.Criterion).Id | Should -Be @('V10.1', 'V10.2', 'V10.3')
            @($context.Criterion | Where-Object { $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'walks all seven Autofix stages and records them in order' {
            $context = Invoke-AuditForTest
            $observed = (Get-Row -Context $context -Id 'V10.1').Observed
            foreach ($stage in 1..7) { $observed | Should -BeLike "*$stage *" }
            $observed | Should -BeLike '*autofix status=success*'
            $observed | Should -BeLike '*alert state=fixed*'
        }

        It 'binds the deploy stage to the merge commit the witness was stamped with' {
            $context = Invoke-AuditForTest
            $observed = (Get-Row -Context $context -Id 'V10.1').Observed
            $observed | Should -BeLike '*stamped with mergeco=1*'
            Should -Invoke Invoke-MlsAz -Exactly -Times 4 -ParameterFilter {
                ($Argument -join ' ') -like '*MLS_HEAL_COMMIT*'
            }
        }

        It 'accepts 2 of 3 dependency trails as the pass line' {
            $script:DependabotPr = @($script:DependabotPr | Select-Object -First 2)
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V10.2'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*2 of 3 trails complete*'
        }
    }

    Context 'a criterion fails on a realistic wrong value' {
        It 'fails V10.1 when a human merged the heal PR' {
            $script:MergedBy = 'paulcfuqua'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V10.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike "*expected the automation identity*"
            Get-MlsExitCode -Context $context | Should -Be 1
        }

        It "fails V10.1 when the PR body does not carry Autofix's own explanation" {
            $script:PrBody = 'Automated fix generated by our workflow.'
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V10.1').Observed | Should -BeLike '*does not carry*explanation*'
        }

        It 'fails V10.1 when autofix generation errored' {
            $script:AutofixStatus = 'error'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V10.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike "*autofix status 'error'*"
            $row.Detail | Should -BeLike '*not retried away*'
        }

        It 'fails V10.1 when the alert never closed' {
            $script:CodeQlState = 'open'
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V10.1').Observed | Should -BeLike "*alert state 'open', expected 'fixed'*"
        }

        It 'fails V10.1 when no new container app revision followed the merge' {
            $script:Revision = @([pscustomobject]@{ name = 'old'; created = '2026-08-20T10:00:00Z'; healCommit = 'unset' })
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V10.1').Observed | Should -BeLike '*no new container app revision*'
        }

        It 'fails V10.1 when a revision followed the merge but is not this heal''s' {
            # An unrelated redeploy of the witness must not satisfy the deploy stage: the
            # criterion is that THIS heal shipped, not that something shipped.
            $script:Revision = @([pscustomobject]@{
                    name       = 'mls-vuln-lab-demo-ca--rev8'
                    created    = '2026-08-24T11:00:00Z'
                    healCommit = 'someothercommit'
                })
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V10.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*none carries MLS_HEAL_COMMIT=mergecommitsha*'
            $row.Observed | Should -BeLike '*does not prove this heal shipped*'
        }

        It 'fails V10.1 when the witness was never stamped at all' {
            $script:Revision = @([pscustomobject]@{
                    name       = 'mls-vuln-lab-demo-ca--rev1'
                    created    = '2026-08-24T11:00:00Z'
                    healCommit = $null
                })
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V10.1').Observed | Should -BeLike '*stamps seen: (none stamped)*'
        }

        It 'fails V10.2 for a pin whose merge did not roll the witness' {
            $script:Revision = @([pscustomobject]@{ name = 'old'; created = '2026-08-20T10:00:00Z'; healCommit = 'unset' })
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V10.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*no new container app revision*'
        }

        It 'fails V10.2 when only one dependency trail completes' {
            $script:DependabotPr = @($script:DependabotPr | Select-Object -First 1)
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V10.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*1 of 3 trails complete*'
            $row.Detail | Should -BeLike '*Partial credit does not accumulate*'
        }
    }

    Context 'the 24 h chain window' {
        It 'records PENDING while the window from the re-seed merge is still open' {
            $script:CodeQlState = 'open'
            $script:DependabotState = 'open'
            $context = Invoke-AuditForTest -ReseedMergedUtc ([datetime]::UtcNow.AddHours(-1).ToString('o'))
            (Get-Row -Context $context -Id 'V10.1').Status | Should -Be 'PENDING'
            (Get-Row -Context $context -Id 'V10.1').RetryWindowMinutes | Should -Be 1440
            (Get-Row -Context $context -Id 'V10.2').Status | Should -Be 'PENDING'
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'records FAIL once the 24 h window has elapsed' {
            $script:CodeQlState = 'open'
            $context = Invoke-AuditForTest -ReseedMergedUtc ([datetime]::UtcNow.AddHours(-30).ToString('o'))
            (Get-Row -Context $context -Id 'V10.1').Status | Should -Be 'FAIL'
        }

        It 'never sleeps in-process for a 24 h window' {
            $context = Invoke-AuditForTest -ReseedMergedUtc ([datetime]::UtcNow.AddHours(-1).ToString('o'))
            @($context.Criterion | ForEach-Object { $_.SleptSeconds }) | Should -Be @(0, 0, 0)
            Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 0
        }
    }

    Context 'V10.3: the chain could not look, and called it "nothing to heal" (F123)' {
        It 'FAILS when the select job reports the alert surface was unreadable' {
            $context = Invoke-AuditForTest -NoRetry -AlertSurfaceReadable 'false'
            $row = Get-Row -Context $context -Id 'V10.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'could NOT read'
            # A denial and an empty alert list are different facts, and the whole
            # point of this criterion is that the report says which one happened.
            $row.Detail | Should -Match 'DENIAL, not an empty alert list'
            # The remedy is a credential SCOPE, not a permission grant, which is the
            # part that cost days - so the criterion carries it.
            $row.Detail | Should -Match 'REPOSITORY secret'
        }

        It 'FAILS as UNOBSERVABLE when the chain reported nothing at all' {
            # Never "healthy by default". An audit invoked without the input cannot
            # say the chain can see its own work, and must not imply that it can.
            $context = Invoke-AuditForTest -NoRetry -AlertSurfaceReadable ''
            $row = Get-Row -Context $context -Id 'V10.3'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -Match 'UNOBSERVABLE, not healthy'
        }

        It 'PASSES when the surface was readable, so the guard is not a blanket fail' {
            $context = Invoke-AuditForTest -NoRetry -AlertSurfaceReadable 'true'
            (Get-Row -Context $context -Id 'V10.3').Status | Should -Be 'PASS'
        }
    }

    Context 'the PR is armed but not merged yet - the state the chain is in most of the time' {
        # Run 33845069050 (2026-09-04): the Dependabot lane armed auto-merge on PR #174 and
        # the audit ran 35 seconds later. mergedAt was empty, so both trails passed $null to
        # Get-RevisionAfter -MergedUtc, whose [AllowNull()][datetime] waives the null CHECK
        # but not the type COERCION - the binder threw before the function's own
        # `if ($null -eq $MergedUtc)` guard could run. The exception text then replaced every
        # stage this trail had already diagnosed, so a run that knew "PR not merged" reported
        # a PowerShell type error instead.
        It 'reports V10.2 as not merged rather than throwing a type-conversion error' {
            $script:MergedAt = ''
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V10.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Not -BeLike '*Cannot convert null*'
            $row.Observed | Should -BeLike '*not merged*'
        }

        It 'reports V10.1 as not merged rather than throwing a type-conversion error' {
            $script:MergedAt = ''
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V10.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Not -BeLike '*Cannot convert null*'
            $row.Observed | Should -BeLike '*not merged*'
        }

        It 'still reports the deploy stage it could not bind, so the trail is diagnosed in full' {
            $script:MergedAt = ''
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V10.1').Observed | Should -BeLike '*no new container app revision*'
        }
    }

    Context 'a check that throws' {
        It 'records V10.1 as FAIL and still evaluates V10.2 and V10.3' {
            Mock Invoke-MlsAz { throw 'az containerapp revision list failed: ResourceGroupNotFound.' }
            $context = Invoke-AuditForTest -NoRetry
            @($context.Criterion).Count | Should -Be 3
            (Get-Row -Context $context -Id 'V10.1').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V10.1').Observed | Should -BeLike '*ResourceGroupNotFound*'
        }
    }

    Context 'missing input' {
        It 'refuses to run without the Verifier GitHub token' {
            foreach ($name in @('MLS_VERIFIER_GH_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) { [Environment]::SetEnvironmentVariable($name, $null) }
            { Invoke-AuditForTest } | Should -Throw '*GitHubToken*'
        }

        It 'fails V10.1 and V10.2 with actionable messages when no alert numbers were posted' {
            $context = Invoke-AuditForTest -CodeQlAlertNumber '' -AutofixPrNumber '' -DependabotAlertNumber @() -NoRetry
            (Get-Row -Context $context -Id 'V10.1').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V10.1').Detail | Should -BeLike '*MLS_L10_CODEQL_ALERT*'
            (Get-Row -Context $context -Id 'V10.2').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V10.2').Detail | Should -BeLike '*MLS_L10_DEPENDABOT_ALERTS*'
        }
    }
}
