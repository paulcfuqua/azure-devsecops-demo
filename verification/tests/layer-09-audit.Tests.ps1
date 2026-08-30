# Pester tests for verification/layer-09-audit.ps1 - gh, az and every artifact download
# are mocked; zero cloud calls and nothing is fetched from GitHub.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-09-audit.ps1')
    # No Set-StrictMode -Off: the audit scripts set -Version Latest and CI runs them
    # that way, so the harness must not relax the language mode it is testing (F49).

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l09-$([guid]::NewGuid().ToString('n'))"
    $script:DownloadRoot = Join-Path -Path $script:ReportRoot -ChildPath 'downloads'
    New-Item -ItemType Directory -Path $script:DownloadRoot -Force | Out-Null
    $script:Repository = 'paulcfuqua/azure-devsecops-demo'
    $script:EnvironmentVariable = @('MLS_VERIFIER_GH_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN', 'AZURE_SUBSCRIPTION_ID',
        'MLS_L9_RUN_ID', 'MLS_L9_RELEASE_TAG', 'MLS_L9_ZAP_RUN_ID')
    $script:SavedEnvironment = @{}
    foreach ($name in $script:EnvironmentVariable) { $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

    function Get-Row {
        param($Context, [string]$Id)
        return @($Context.Criterion | Where-Object { $_.Id -eq $Id })[0]
    }

    function Get-ArgumentValue {
        param([string[]]$Argument, [string]$Name)
        $index = [array]::IndexOf($Argument, $Name)
        if ($index -ge 0 -and ($index + 1) -lt $Argument.Count) { return $Argument[$index + 1] }
        return $null
    }

    function Invoke-AuditForTest {
        param([switch]$NoRetry, [string]$LayerRunId = '5150', [string]$ReleaseTag = 'v0.9.0', [string]$ZapRunId = '5151')
        Invoke-Main -Repository $script:Repository -SubscriptionId '22222222-2222-2222-2222-222222222222' `
            -LayerRunId $LayerRunId -ReleaseTag $ReleaseTag -ZapRunId $ZapRunId `
            -CodeQlLanguage @('javascript-typescript', 'python') -DownloadRoot $script:DownloadRoot `
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

Describe 'layer-09-audit' {
    BeforeEach {
        foreach ($name in $script:EnvironmentVariable) { [Environment]::SetEnvironmentVariable($name, $null) }
        $env:GH_TOKEN = 'ghp-verifier-read-only'
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'

        $script:SecretScanning = 'enabled'
        $script:PushProtection = 'enabled'
        $script:AlertsHeader = "HTTP/2.0 204 No Content`nx-github-request-id: abc"
        $script:Analyses = @(
            [pscustomobject]@{ tool = [pscustomobject]@{ name = 'CodeQL' }; category = '/language:javascript-typescript'; environment = '' }
            [pscustomobject]@{ tool = [pscustomobject]@{ name = 'CodeQL' }; category = '/language:python'; environment = '' }
        )
        $script:TrivyJobs = @(
            [pscustomobject]@{ name = 'trivy-negative-fail'; conclusion = 'success' }
            [pscustomobject]@{ name = 'trivy-negative-pass'; conclusion = 'success' }
        )
        $script:ReleaseAsset = @('launch-ops.spdx.json', 'control-tower.spdx.json')
        $script:SpdxPackages = @(@{ name = 'react'; versionInfo = '19.0.0' })
        $script:ZapAlert = @(@{ riskdesc = 'Medium (Medium)'; alert = 'Missing header' })
        $script:PricingTier = 'Free'
        $script:PricingEvents = @(
            [pscustomobject]@{ op = 'Microsoft.Security/pricings/write'; status = 'Succeeded'; time = '2026-08-24T09:00:00Z' }
            [pscustomobject]@{ op = 'Microsoft.Security/pricings/write'; status = 'Succeeded'; time = '2026-08-24T09:10:00Z' }
        )

        Mock Invoke-MlsGh {
            $joined = $Argument -join ' '
            if ($joined -like "*vulnerability-alerts*") { return $script:AlertsHeader }
            if ($joined -like '*code-scanning/analyses*') { return $script:Analyses }
            if ($joined -like '*actions/runs/*/jobs*') { return [pscustomobject]@{ jobs = $script:TrivyJobs } }
            if ($joined -like "api repos/$($script:Repository)") {
                return [pscustomobject]@{
                    security_and_analysis = [pscustomobject]@{
                        secret_scanning                 = [pscustomobject]@{ status = $script:SecretScanning }
                        secret_scanning_push_protection = [pscustomobject]@{ status = $script:PushProtection }
                    }
                }
            }
            if ($joined -like 'release view*') {
                return [pscustomobject]@{ assets = @($script:ReleaseAsset | ForEach-Object { [pscustomobject]@{ name = $_ } }) }
            }
            if ($joined -like 'release download*') {
                $target = Get-ArgumentValue -Argument $Argument -Name '-D'
                if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
                foreach ($asset in $script:ReleaseAsset) {
                    $document = @{
                        spdxVersion       = 'SPDX-2.3'
                        SPDXID            = 'SPDXRef-DOCUMENT'
                        name              = $asset
                        documentNamespace = "https://example/spdx/$asset"
                        creationInfo      = @{ created = '2026-08-24T00:00:00Z'; creators = @('Tool: syft') }
                        packages          = $script:SpdxPackages
                    }
                    Set-Content -LiteralPath (Join-Path -Path $target -ChildPath $asset) -Encoding utf8 `
                        -Value ($document | ConvertTo-Json -Depth 6)
                }
                return 'downloaded'
            }
            if ($joined -like 'run download*') {
                $target = Get-ArgumentValue -Argument $Argument -Name '-D'
                if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
                $report = @{ site = @(@{ '@name' = 'https://staging.example'; alerts = $script:ZapAlert }) }
                Set-Content -LiteralPath (Join-Path -Path $target -ChildPath 'report.json') -Encoding utf8 `
                    -Value ($report | ConvertTo-Json -Depth 6)
                return 'downloaded'
            }
            throw "unexpected gh call: $joined"
        }

        Mock Invoke-MlsAz {
            $joined = $Argument -join ' '
            if ($joined -like 'security pricing show*') { return [pscustomobject]@{ tier = $script:PricingTier } }
            if ($joined -like 'monitor activity-log list*') { return $script:PricingEvents }
            throw "unexpected az call: $joined"
        }
    }

    Context 'all criteria pass' {
        It 'records V9.1-V9.5 as PASS and exits 0' {
            $context = Invoke-AuditForTest
            @($context.Criterion).Id | Should -Be @('V9.1', 'V9.2', 'V9.3', 'V9.4', 'V9.5')
            @($context.Criterion | Where-Object { $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'validates SPDX structurally when the pinned validator is not installed, rather than skipping' {
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V9.3'
            $row.Status | Should -Be 'PASS'
            $row.Detail | Should -BeLike '*in-process*'
        }

        It 'requires the paired Standard-then-Free writes, not merely a Free tier' {
            $context = Invoke-AuditForTest
            (Get-Row -Context $context -Id 'V9.5').Observed | Should -BeLike '*toggle exercised*'
        }
    }

    Context 'a criterion fails on a realistic wrong value' {
        It 'fails V9.5 when Defender was left on Standard' {
            $script:PricingTier = 'Standard'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V9.5'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike "*'Standard', expected 'Free'*"
            $row.Detail | Should -BeLike '*disable immediately*'
            Get-MlsExitCode -Context $context | Should -Be 1
        }

        It 'fails V9.5 when the tier is Free but the toggle was never exercised' {
            $script:PricingEvents = @()
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V9.5').Observed | Should -BeLike '*only 0 Microsoft.Security/pricings write event*'
        }

        It 'fails V9.4 when ZAP reports a High alert' {
            $script:ZapAlert = @(@{ riskdesc = 'High (Medium)'; alert = 'SQL injection' })
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V9.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*SQL injection*'
        }

        It 'fails V9.2 when the negative test only has its passing half' {
            $script:TrivyJobs = @([pscustomobject]@{ name = 'trivy-negative-pass'; conclusion = 'success' })
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V9.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*trivy-negative-fail*absent*'
        }

        It 'fails V9.1 when Dependabot alerts are off' {
            $script:AlertsHeader = "HTTP/2.0 404 Not Found"
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V9.1').Observed | Should -BeLike '*Dependabot alerts are off*'
        }

        It 'fails V9.3 when an SBOM has an empty package list' {
            $script:SpdxPackages = @()
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V9.3').Observed | Should -BeLike '*package list is empty*'
        }
    }

    Context 'retry' {
        It 'retries V9.1 until the first CodeQL analysis lands, without sleeping the whole window' {
            $script:Calls = 0
            $script:Analyses = @()
            Mock Invoke-MlsGh {
                $joined = $Argument -join ' '
                if ($joined -like '*vulnerability-alerts*') { return "HTTP/2.0 204 No Content" }
                if ($joined -like '*code-scanning/analyses*') {
                    $script:Calls++
                    if ($script:Calls -lt 2) { return @() }
                    return @(
                        [pscustomobject]@{ tool = [pscustomobject]@{ name = 'CodeQL' }; category = '/language:javascript-typescript'; environment = '' }
                        [pscustomobject]@{ tool = [pscustomobject]@{ name = 'CodeQL' }; category = '/language:python'; environment = '' }
                    )
                }
                if ($joined -like '*actions/runs/*/jobs*') { return [pscustomobject]@{ jobs = $script:TrivyJobs } }
                if ($joined -like "api repos/$($script:Repository)") {
                    return [pscustomobject]@{ security_and_analysis = [pscustomobject]@{
                            secret_scanning                 = [pscustomobject]@{ status = 'enabled' }
                            secret_scanning_push_protection = [pscustomobject]@{ status = 'enabled' }
                        }
                    }
                }
                if ($joined -like 'release view*') { return [pscustomobject]@{ assets = @([pscustomobject]@{ name = 'launch-ops.spdx.json' }) } }
                if ($joined -like 'release download*') {
                    $target = Get-ArgumentValue -Argument $Argument -Name '-D'
                    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
                    Set-Content -LiteralPath (Join-Path -Path $target -ChildPath 'launch-ops.spdx.json') -Encoding utf8 -Value (@{
                            spdxVersion = 'SPDX-2.3'; SPDXID = 'SPDXRef-DOCUMENT'; name = 'launch-ops'
                            documentNamespace = 'https://example/spdx/launch-ops'; creationInfo = @{ created = '2026-08-24T00:00:00Z' }
                            packages = @(@{ name = 'react' })
                        } | ConvertTo-Json -Depth 6)
                    return 'downloaded'
                }
                if ($joined -like 'run download*') {
                    $target = Get-ArgumentValue -Argument $Argument -Name '-D'
                    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
                    Set-Content -LiteralPath (Join-Path -Path $target -ChildPath 'report.json') -Encoding utf8 `
                        -Value (@{ site = @(@{ alerts = @() }) } | ConvertTo-Json -Depth 6)
                    return 'downloaded'
                }
                throw "unexpected gh call: $joined"
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V9.1'
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
        It 'records V9.5 as FAIL when the Defender read errors, and still evaluates the rest' {
            Mock Invoke-MlsAz { throw "az security pricing show failed with exit code 1 (AuthorizationFailed)." }
            $context = Invoke-AuditForTest -NoRetry
            @($context.Criterion).Count | Should -Be 5
            (Get-Row -Context $context -Id 'V9.5').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V9.5').Observed | Should -BeLike '*AuthorizationFailed*'
            (Get-Row -Context $context -Id 'V9.1').Status | Should -Be 'PASS'
        }
    }

    Context 'missing input' {
        It 'refuses to run without the Verifier GitHub token' {
            foreach ($name in @('MLS_VERIFIER_GH_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')) { [Environment]::SetEnvironmentVariable($name, $null) }
            { Invoke-AuditForTest } | Should -Throw '*GitHubToken*'
        }

        It 'fails V9.2, V9.3 and V9.4 with actionable messages when their run ids and tag were never posted' {
            $context = Invoke-AuditForTest -LayerRunId '' -ReleaseTag '' -ZapRunId '' -NoRetry
            (Get-Row -Context $context -Id 'V9.2').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V9.2').Detail | Should -BeLike '*MLS_L9_RUN_ID*'
            (Get-Row -Context $context -Id 'V9.3').Detail | Should -BeLike '*MLS_L9_RELEASE_TAG*'
            (Get-Row -Context $context -Id 'V9.4').Detail | Should -BeLike '*MLS_L9_ZAP_RUN_ID*'
        }
    }
}
