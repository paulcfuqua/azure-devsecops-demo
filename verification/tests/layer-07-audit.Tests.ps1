# Pester tests for verification/layer-07-audit.ps1 - az, HTTP, gh and npm are all mocked;
# zero cloud calls and no live endpoints.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-07-audit.ps1')
    # No Set-StrictMode -Off: the audit scripts set -Version Latest and CI runs them
    # that way, so the harness must not relax the language mode it is testing (F49).

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l07-$([guid]::NewGuid().ToString('n'))"
    New-Item -ItemType Directory -Path $script:ReportRoot -Force | Out-Null
    $script:App = @('mls-launch-ops-demo-ca', 'mls-control-tower-demo-ca')
    $script:Digest = @{
        'mls-launch-ops-demo-ca'    = 'sha256:aaaa1111'
        'mls-control-tower-demo-ca' = 'sha256:bbbb2222'
    }
    $script:ManifestPath = Join-Path -Path $script:ReportRoot -ChildPath 'l7-manifest.json'
    Set-Content -LiteralPath $script:ManifestPath -Encoding utf8 -Value (@{
            apps = @($script:App | ForEach-Object { @{ name = $_; imageDigest = $script:Digest[$_] } })
        } | ConvertTo-Json -Depth 5)
    $script:EnvironmentVariable = @('MLS_L7_MANIFEST', 'MLS_LAW_CUSTOMER_ID', 'MLS_L7_CANARY_PR', 'MLS_REPOSITORY')
    $script:SavedEnvironment = @{}
    foreach ($name in $script:EnvironmentVariable) { $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

    function Get-Row {
        param($Context, [string]$Id)
        return @($Context.Criterion | Where-Object { $_.Id -eq $Id })[0]
    }

    function Invoke-AuditForTest {
        param([switch]$NoRetry, [string]$ManifestPath = $script:ManifestPath, [string]$CanaryPrNumber = '77')
        Invoke-Main -AppName $script:App -DeployManifestPath $ManifestPath -LogAnalyticsWorkspaceId 'law-customer-guid' `
            -Repository 'paulcfuqua/azure-devsecops-demo' -CanaryPrNumber $CanaryPrNumber -LoadRequestCount 2 `
            -ScaleInWaitMinutes 15 -ScaleInDeadlineMinutes 30 -ReportRoot $script:ReportRoot -NoRetry:$NoRetry
    }
}

AfterAll {
    foreach ($name in $script:EnvironmentVariable) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnvironment[$name]) }
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:ReportRoot) {
        Remove-Item -LiteralPath $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'layer-07-audit' {
    BeforeEach {
        foreach ($name in $script:EnvironmentVariable) { [Environment]::SetEnvironmentVariable($name, $null) }
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'
        # V7.5's phase-3 settle calls the wait from the script's own scope.
        Mock Wait-MlsRetryInterval {}

        $script:HealthStatus = 200
        $script:ReplicaSequence = @{ 'mls-launch-ops-demo-ca' = @(0, 3, 0); 'mls-control-tower-demo-ca' = @(0, 2, 0) }
        $script:ReplicaCall = @{ 'mls-launch-ops-demo-ca' = 0; 'mls-control-tower-demo-ca' = 0 }
        # V7.3 matches on the PROBE MARKER in the row's Url, not on AppRoleName: the span
        # is emitted by whichever app in the chain runs instrumented code (data-api), while
        # the marker says which front door the request came through (F89). The probe id is
        # a timestamp minted at run time, so the mock reads it back out of the KQL it was
        # handed rather than pinning a literal the test would have to keep in step.
        $script:SpanEmittingRole = 'data-api'
        function Get-SpanRowsForQuery {
            param([string]$Query)
            if ($Query -notmatch "probe=([^']+)'") { return @() }
            $probeId = $Matches[1]
            return @('launch-ops', 'control-tower' | ForEach-Object {
                    [pscustomobject]@{
                        AppRoleName = $script:SpanEmittingRole
                        Url         = "https://$_.mls.eastus.azurecontainerapps.io/api/launches?probe=$probeId-$_"
                        OperationId = "op-$_"
                    }
                })
        }
        $script:CheckRun = @(
            [pscustomobject]@{ name = 'app-launch-ops-ci / build'; conclusion = 'success' }
            [pscustomobject]@{ name = 'app-control-tower-ci / build'; conclusion = 'success' }
        )
        $script:CanaryFile = @([pscustomobject]@{ path = 'apps/shared/spec-renderer/src/index.ts' })
        $script:NpmExit = 0

        Mock Invoke-MlsAz {
            $joined = $Argument -join ' '
            if ($joined -like 'containerapp show*') {
                $index = [array]::IndexOf($Argument, '--name')
                return "$($Argument[$index + 1]).mls.eastus.azurecontainerapps.io"
            }
            if ($joined -like 'containerapp replica list*') {
                $index = [array]::IndexOf($Argument, '--name')
                $name = $Argument[$index + 1]
                $phase = $script:ReplicaCall[$name]
                $script:ReplicaCall[$name] = $phase + 1
                return "$($script:ReplicaSequence[$name][[math]::Min($phase, 2)])"
            }
            if ($joined -like 'containerapp auth show*') {
                $index = [array]::IndexOf($Argument, '--name')
                return "clientid-$($Argument[$index + 1])"
            }
            if ($joined -like 'account get-access-token*') { return 'fake-token' }
            if ($joined -like 'monitor log-analytics query*') {
                $index = [array]::IndexOf($Argument, '--analytics-query')
                return Get-SpanRowsForQuery -Query "$($Argument[$index + 1])"
            }
            throw "unexpected az call: $joined"
        }

        Mock Invoke-MlsHttp {
            $name = ($Uri -split '//')[1].Split('.')[0]
            return [pscustomobject]@{
                StatusCode = $script:HealthStatus
                Content    = "{`"status`":`"ok`",`"contentHash`":`"$($script:Digest[$name])`"}"
                Headers    = @{}
                Error      = $null
            }
        }

        Mock Invoke-MlsGh {
            $joined = $Argument -join ' '
            if ($joined -like 'pr view*') {
                return [pscustomobject]@{ number = 77; headRefOid = 'canarysha'; files = $script:CanaryFile; state = 'OPEN' }
            }
            if ($joined -like '*check-runs*') { return [pscustomobject]@{ check_runs = $script:CheckRun } }
            throw "unexpected gh call: $joined"
        }

        Mock Invoke-MlsLocalCommand {
            return [pscustomobject]@{ ExitCode = $script:NpmExit; Line = @('golden specs validated') }
        }
    }

    Context 'all criteria pass' {
        It 'records V7.1-V7.5 as PASS and exits 0' {
            $context = Invoke-AuditForTest
            @($context.Criterion).Id | Should -Be @('V7.1', 'V7.2', 'V7.3', 'V7.4', 'V7.5')
            @($context.Criterion | Where-Object { $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'binds the endpoint to the audited build via the recorded image digest' {
            $context = Invoke-AuditForTest
            (Get-Row -Context $context -Id 'V7.1').Observed | Should -BeLike '*matching content-hash markers*'
        }

        It 'observes the 0 -> N -> 0 replica sequence' {
            $context = Invoke-AuditForTest
            (Get-Row -Context $context -Id 'V7.5').Observed | Should -BeLike '*0->3->0*'
        }

        It 'notes that the Ask tab ships dark and is deliberately outside every L7 criterion' {
            $context = Invoke-AuditForTest
            ($context.Note -join ' ') | Should -BeLike '*Ask tab*'
        }
    }

    Context 'a criterion fails on a realistic wrong value' {
        It 'fails V7.1 when the endpoint serves a build other than the audited one' {
            Mock Invoke-MlsHttp {
                return [pscustomobject]@{ StatusCode = 200; Content = '{"status":"ok","contentHash":"sha256:stale999"}'; Headers = @{}; Error = $null }
            }
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V7.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*does not carry the deployed image digest*'
            Get-MlsExitCode -Context $context | Should -Be 1
        }

        It 'fails V7.5 when replicas never return to zero' {
            $script:ReplicaSequence['mls-launch-ops-demo-ca'] = @(0, 3, 2)
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V7.5'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*still has 2 replica*'
            $row.Detail | Should -BeLike '*never return to 0*'
        }

        It 'fails V7.4 when a required check is failing on the canary PR' {
            $script:CheckRun = @([pscustomobject]@{ name = 'app-launch-ops-ci / test'; conclusion = 'failure' })
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V7.4').Observed | Should -BeLike '*checks not green*'
        }

        It 'passes V7.4 when deploy jobs are skipped, because skipped is not failed' {
            # A canary touching only apps/shared/** is documentation-shaped: the per-app
            # pipelines build and scan, and their deploy jobs SKIP because the F83 guard
            # declines to roll an image onto an app nothing changed about. Counting that as
            # "not green" failed V7.4 against a canary whose CI was entirely correct - five
            # skips out of 28 (F96).
            $script:CheckRun = @(
                [pscustomobject]@{ name = 'app-launch-ops-ci / build'; conclusion = 'success' }
                [pscustomobject]@{ name = 'app-control-tower-ci / build'; conclusion = 'success' }
                [pscustomobject]@{ name = 'app-launch-ops-ci / deploy to Container Apps'; conclusion = 'skipped' }
                [pscustomobject]@{ name = 'app-control-tower-ci / deploy to Container Apps'; conclusion = 'skipped' }
            )
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V7.4'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -Match '2 skipped'
        }

        It 'still fails V7.4 on a real failure sitting beside the skips' {
            # Accepting `skipped` must not accept anything else. Without this, the fix above
            # is a loosened gate rather than a corrected one.
            $script:CheckRun = @(
                [pscustomobject]@{ name = 'app-launch-ops-ci / build'; conclusion = 'success' }
                [pscustomobject]@{ name = 'app-control-tower-ci / build'; conclusion = 'success' }
                [pscustomobject]@{ name = 'app-launch-ops-ci / deploy to Container Apps'; conclusion = 'skipped' }
                [pscustomobject]@{ name = 'app-control-tower-ci / test'; conclusion = 'failure' }
            )
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V7.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'test=failure'
        }

        It 'fails V7.4 when the path filter fires the wrong pipeline' {
            $script:CanaryFile = @([pscustomobject]@{ path = 'apps/launch-ops/src/app.tsx' })
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V7.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*control-tower pipeline also ran*'
        }

        It 'fails V7.2 when a golden spec no longer validates' {
            $script:NpmExit = 1
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V7.2').Status | Should -Be 'FAIL'
        }
    }

    Context 'retry' {
        It 'retries V7.3 through App Insights ingestion lag without sleeping the whole window' {
            $script:Calls = 0
            Mock Invoke-MlsAz {
                $joined = $Argument -join ' '
                if ($joined -like 'containerapp show*') {
                    $index = [array]::IndexOf($Argument, '--name')
                    return "$($Argument[$index + 1]).mls.eastus.azurecontainerapps.io"
                }
                if ($joined -like 'containerapp replica list*') {
                    $index = [array]::IndexOf($Argument, '--name')
                    $name = $Argument[$index + 1]
                    $phase = $script:ReplicaCall[$name]
                    $script:ReplicaCall[$name] = $phase + 1
                    return "$($script:ReplicaSequence[$name][[math]::Min($phase, 2)])"
                }
                if ($joined -like 'containerapp auth show*') {
                    $index = [array]::IndexOf($Argument, '--name')
                    return "clientid-$($Argument[$index + 1])"
                }
                if ($joined -like 'account get-access-token*') { return 'fake-token' }
                if ($joined -like 'monitor log-analytics query*') {
                    $script:Calls++
                    if ($script:Calls -lt 2) { return @() }
                    $index = [array]::IndexOf($Argument, '--analytics-query')
                    return Get-SpanRowsForQuery -Query "$($Argument[$index + 1])"
                }
                throw "unexpected az call: $joined"
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V7.3'
            $row.Status | Should -Be 'PASS'
            $row.Attempt | Should -Be 2
            # One poll interval, not the whole window - asserted against the row's own
            # cadence rather than a literal, so right-sizing the defaults (F59) cannot
            # silently turn this into a test of a constant nobody re-checked.
            $row.SleptSeconds | Should -Be $row.PollIntervalSecond
            $row.SleptSeconds | Should -BeLessThan ($row.RetryWindowMinutes * 60)
        }
    }

    Context 'a check that throws' {
        It 'records V7.2 as FAIL when npm is unavailable, and still evaluates the rest' {
            Mock Invoke-MlsLocalCommand { throw "'npm' is not available on this machine." }
            $context = Invoke-AuditForTest -NoRetry
            @($context.Criterion).Count | Should -Be 5
            (Get-Row -Context $context -Id 'V7.2').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V7.2').Observed | Should -BeLike '*not available*'
            (Get-Row -Context $context -Id 'V7.1').Status | Should -Be 'PASS'
        }
    }

    Context 'missing input' {
        It 'fails V7.1 rather than passing on liveness when no deploy manifest was supplied' {
            $context = Invoke-AuditForTest -ManifestPath (Join-Path -Path $script:ReportRoot -ChildPath 'absent.json') -NoRetry
            $row = Get-Row -Context $context -Id 'V7.1'
            $row.Status | Should -Be 'FAIL'
            $row.Attempt | Should -Be 1
            $row.Detail | Should -BeLike '*MLS_L7_MANIFEST*'
            $row.Detail | Should -BeLike '*Refusing to pass on liveness alone*'
        }

        It 'fails V7.3 distinguishably when no token can be obtained' {
            # "Could not get in" and "got in and saw nothing" have completely different
            # fixes - a missing service principal or probe role versus a broken connection
            # string - and the old message conflated them into "no AppRequests row" (F89).
            Mock Invoke-MlsAz {
                $joined = $Argument -join ' '
                if ($joined -like 'containerapp show*') {
                    $index = [array]::IndexOf($Argument, '--name')
                    return "$($Argument[$index + 1]).mls.eastus.azurecontainerapps.io"
                }
                if ($joined -like 'containerapp replica list*') {
                    $index = [array]::IndexOf($Argument, '--name')
                    $name = $Argument[$index + 1]
                    $phase = $script:ReplicaCall[$name]
                    $script:ReplicaCall[$name] = $phase + 1
                    return "$($script:ReplicaSequence[$name][[math]::Min($phase, 2)])"
                }
                if ($joined -like 'containerapp auth show*') {
                    $index = [array]::IndexOf($Argument, '--name')
                    return "clientid-$($Argument[$index + 1])"
                }
                if ($joined -like 'account get-access-token*') { return '' }   # the mutation under test
                if ($joined -like 'monitor log-analytics query*') { return @() }
                throw "unexpected az call: $joined"
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V7.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'could not obtain a token'
            $row.Observed | Should -Match 'service principal'
        }

        It 'fails V7.3 saying Easy Auth rejected the token when the probe still 401s' {
            Mock Invoke-MlsHttp {
                return [pscustomobject]@{ StatusCode = 401; Content = ''; Headers = @{}; Error = $null }
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V7.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -Match 'Easy Auth rejected it'
        }

        It 'passes V7.3 on a non-401 application status, because the span is the claim' {
            # A 403 or 404 from the app is a PASS: the request traversed Easy Auth and
            # reached application code, which is the entire assertion. The probe role
            # deliberately grants no data access, so demanding a 200 would be demanding a
            # privilege the Verifier is not supposed to have.
            Mock Invoke-MlsHttp {
                return [pscustomobject]@{ StatusCode = 403; Content = ''; Headers = @{}; Error = $null }
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V7.3'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -Match 'http=403'
        }

        It 'waits for a warm app to settle to zero instead of failing V7.5 on the spot' {
            # V7.1 curls every endpoint before this criterion runs and leaves the apps
            # warm, so "starts at 0" was falsified by an earlier criterion in the same
            # audit. The sequence below starts at 1 and settles; the 0 -> N -> 0 cycle is
            # then observable and must pass (F89).
            $script:ReplicaSequence['mls-launch-ops-demo-ca'] = @(1, 0, 4, 0)
            $script:ReplicaSequence['mls-control-tower-demo-ca'] = @(1, 0, 2, 0)
            $script:ReplicaCall['mls-launch-ops-demo-ca'] = 0
            $script:ReplicaCall['mls-control-tower-demo-ca'] = 0
            Mock Invoke-MlsAz {
                $joined = $Argument -join ' '
                if ($joined -like 'containerapp show*') {
                    $index = [array]::IndexOf($Argument, '--name')
                    return "$($Argument[$index + 1]).mls.eastus.azurecontainerapps.io"
                }
                if ($joined -like 'containerapp replica list*') {
                    $index = [array]::IndexOf($Argument, '--name')
                    $name = $Argument[$index + 1]
                    $phase = $script:ReplicaCall[$name]
                    $script:ReplicaCall[$name] = $phase + 1
                    $sequence = $script:ReplicaSequence[$name]
                    return "$($sequence[[math]::Min($phase, $sequence.Count - 1)])"
                }
                if ($joined -like 'containerapp auth show*') {
                    $index = [array]::IndexOf($Argument, '--name')
                    return "clientid-$($Argument[$index + 1])"
                }
                if ($joined -like 'account get-access-token*') { return 'fake-token' }
                if ($joined -like 'monitor log-analytics query*') {
                    $index = [array]::IndexOf($Argument, '--analytics-query')
                    return Get-SpanRowsForQuery -Query "$($Argument[$index + 1])"
                }
                throw "unexpected az call: $joined"
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V7.5'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -Match 'settled after'
        }

        It 'fails V7.4 with an actionable message when no canary PR number was posted' {
            $context = Invoke-AuditForTest -CanaryPrNumber '' -NoRetry
            $row = Get-Row -Context $context -Id 'V7.4'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*MLS_L7_CANARY_PR*'
        }
    }
}
