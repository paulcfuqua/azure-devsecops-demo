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
        $script:AnalysisVisible = $true
        $script:DependabotListHeader = "HTTP/2.0 200 OK`n`n[]"
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
        # The estate deliberately runs this plan (F165): Standard is the healthy state.
        $script:PricingTier = 'Standard'
        $script:PricingEvents = @(
            [pscustomobject]@{ op = 'Microsoft.Security/pricings/write'; status = 'Succeeded'; time = '2026-08-24T09:00:00Z' }
            [pscustomobject]@{ op = 'Microsoft.Security/pricings/write'; status = 'Succeeded'; time = '2026-08-24T09:10:00Z' }
        )

        Mock Invoke-MlsGh {
            $joined = $Argument -join ' '
            if ($joined -like "*vulnerability-alerts*") { return $script:AlertsHeader }
            if ($joined -like '*dependabot/alerts*') { return $script:DependabotListHeader }
            if ($joined -like '*code-scanning/analyses*') { return $script:Analyses }
            if ($joined -like '*actions/runs/*/jobs*') { return [pscustomobject]@{ jobs = $script:TrivyJobs } }
            if ($joined -like "api repos/$($script:Repository)") {
                # GitHub OMITS security_and_analysis entirely for a non-admin caller; it
                # does not return the block with empty statuses. $script:AnalysisVisible
                # models that, because "absent" and "disabled" are the two states V9.1 has
                # to tell apart (F103).
                if (-not $script:AnalysisVisible) { return [pscustomobject]@{ name = 'repo' } }
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

        # Default: Defender IS producing posture. Individual tests override.
        $script:SecureScores = [pscustomobject]@{ value = @([pscustomobject]@{ name = 'ascScore' }) }
        $script:Assessments = [pscustomobject]@{ value = @([pscustomobject]@{ name = 'a1' }) }
        $script:PolicySummary = [pscustomobject]@{ results = [pscustomobject]@{ nonCompliantResources = 6 } }

        Mock Invoke-MlsAz {
            $joined = $Argument -join ' '
            if ($joined -like 'security pricing show*') { return [pscustomobject]@{ tier = $script:PricingTier } }
            if ($joined -like 'monitor activity-log list*') { return $script:PricingEvents }
            # V9.6 reads the two Defender posture surfaces over `az rest`. The
            # fixture answers with whatever the test set, so "Defender produces
            # posture", "Defender produces nothing" and "the endpoint did not
            # answer" are three distinct, settable states rather than one throw.
            if ($joined -like '*secureScores*') { return $script:SecureScores }
            if ($joined -like '*assessments*') { return $script:Assessments }
            if ($joined -like 'policy state summarize*') { return $script:PolicySummary }
            throw "unexpected az call: $joined"
        }
    }

    Context 'all criteria pass' {
        It 'records V9.1-V9.5 as PASS and exits 0' {
            $context = Invoke-AuditForTest
            @($context.Criterion).Id | Should -Be @('V9.1', 'V9.2', 'V9.3', 'V9.4', 'V9.5', 'V9.6')
            @($context.Criterion | Where-Object { $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'validates SPDX structurally when the pinned validator is not installed, rather than skipping' {
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V9.3'
            $row.Status | Should -Be 'PASS'
            $row.Detail | Should -BeLike '*in-process*'
        }

        It 'reports the pricings write count beside the tier, without requiring it' {
            # Was: "requires the paired Standard-then-Free writes, not merely a Free
            # tier". F165 inverted the premise - the plan is meant to be ON - so the
            # write count is evidence offered to a reader, not a condition. Requiring
            # it would fail the criterion on every day nobody touched the plan.
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V9.5'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*pricings write event(s)*'
        }
    }

    Context 'a criterion fails on a realistic wrong value' {
        It 'fails V9.5 when the Defender plan is OFF, and says enabling it is a G2 call' {
            # INVERTED BY F165. This test used to assert the opposite - that an
            # ENABLED plan is a failure and should be "disabled immediately" - which
            # encoded the false premise that this estate's normal state is Defender
            # switched off. For a security demo that is backwards.
            $script:PricingTier = 'Free'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V9.5'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike "*'Free', expected 'Standard'*"
            # The remedy is a SPEND INCREASE, so the message must send the reader to
            # the gate rather than telling them to just turn it on.
            $row.Detail | Should -BeLike '*G2*'
            $row.Detail | Should -BeLike '*freeTrialRemainingTime*'
            Get-MlsExitCode -Context $context | Should -Be 1
        }

        It 'PASSES V9.5 on a quiet day with no pricings writes at all' {
            # The Activity Log window is reported, not required (F165). Requiring a
            # write would make the criterion red every day nobody touched the plan -
            # which is most days, and exactly the "red check people learn to ignore"
            # this repository spends its budget avoiding.
            $script:PricingEvents = @()
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V9.5'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*Standard (enabled)*'
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

        It 'never reports an unreadable control as a disabled one' {
            # V9.1 read an absent security_and_analysis block as "secret_scanning=''" and
            # announced that secret scanning and push protection were off - on a repository
            # where both were verifiably enabled. A security audit reporting a control as
            # missing when it merely lacked permission to look is the worst answer this
            # repo can produce (F103).
            $script:AnalysisVisible = $false
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V9.1'
            $row.Observed | Should -Not -BeLike "*secret_scanning.status=''*" `
                -Because 'an absent field must never be reported as a disabled control'
            $row.Observed | Should -BeLike '*admin-only*'
        }

        It 'passes on capability evidence when the admin-only endpoint cannot be read' {
            # The point of the reshape: /vulnerability-alerts is admin-only, but LISTING
            # Dependabot alerts is not, and a 200 there proves the feature is on - a
            # repository with alerts disabled cannot serve them. Capability, not artefact.
            $script:AnalysisVisible = $false
            $script:AlertsHeader = "HTTP/2.0 403 Forbidden"
            $script:DependabotListHeader = "HTTP/2.0 200 OK`n`n[]"
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V9.1'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*alerting is live*'
            # The scope boundary is stated in the report, never left implicit.
            $row.Observed | Should -BeLike '*NOT CLAIMED*'
            $row.Observed | Should -BeLike '*G0*'
        }

        It 'fails when neither Dependabot endpoint can be read' {
            # Both blind is genuinely unobservable, and unobservable is not a sign-off.
            $script:AlertsHeader = "HTTP/2.0 403 Forbidden"
            $script:DependabotListHeader = "HTTP/2.0 403 Forbidden"
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V9.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*UNOBSERVABLE*'
            $row.Observed | Should -Not -BeLike '*Dependabot alerts are off*' `
                -Because 'a refused request is not evidence that the control is off'
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


    Context 'V9.6 - Defender posture (F153)' {
        It 'PASSES when Defender produces a secure score' {
            (Get-Row -Context (Invoke-AuditForTest) -Id 'V9.6').Status | Should -Be 'PASS'
        }

        It 'PASSES on assessments alone, when no secure score has been computed yet' {
            # The two surfaces populate independently. Requiring both would fail an
            # estate that is genuinely being assessed.
            $script:SecureScores = [pscustomobject]@{ value = @() }
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V9.6'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*assessments=1*'
        }

        It 'FAILS when Defender produces nothing, and names what IS working' {
            # The trap this criterion exists for: ASC Default is assigned and Azure
            # Policy evaluates happily, so an operator checking "is the initiative
            # assigned?" concludes Defender works. Assessments are a different
            # pipeline. The failure must say so or it sends the reader in a circle.
            $script:SecureScores = [pscustomobject]@{ value = @() }
            $script:Assessments = [pscustomobject]@{ value = @() }
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V9.6'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*secure scores=0 assessments=0*'
            $row.Observed | Should -BeLike '*Azure Policy IS evaluating: 6*'
            $row.Detail | Should -BeLike '*DIFFERENT pipeline*'
        }

        It 'reports UNOBSERVABLE, never "absent", when neither endpoint answers' {
            # An audit that cannot see a thing says so. Reporting "Defender produces
            # no posture" because the Verifier lacked a role would be a confident,
            # specific, wrong answer - the class this repository pays most for.
            $script:SecureScores = $null
            $script:Assessments = $null
            $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V9.6'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike 'UNOBSERVABLE*'
            $row.Detail | Should -BeLike '*not evidence that Defender produces nothing*'
        }

        It 'does not spend a retry window on a pipeline measured in hours' {
            # Both failure paths are -Final. Defender's assessment surface fills over
            # hours; a five-minute poll cannot change the verdict, so it must not
            # spend the wall clock reaching the same one.
            $script:SecureScores = [pscustomobject]@{ value = @() }
            $script:Assessments = [pscustomobject]@{ value = @() }
            (Get-Row -Context (Invoke-AuditForTest) -Id 'V9.6').Attempt | Should -Be 1
        }
    }

    Context 'a check that throws' {
        It 'records V9.5 as FAIL when the Defender read errors, and still evaluates the rest' {
            Mock Invoke-MlsAz { throw "az security pricing show failed with exit code 1 (AuthorizationFailed)." }
            $context = Invoke-AuditForTest -NoRetry
            @($context.Criterion).Count | Should -Be 6
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
