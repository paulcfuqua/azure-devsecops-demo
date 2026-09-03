# Pester tests for verification/layer-04-audit.ps1 - the S&C session and Get-Label are
# mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-04-audit.ps1')
    # No Set-StrictMode -Off: the audit scripts set -Version Latest and CI runs them
    # that way, so the harness must not relax the language mode it is testing (F49).

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l04-$([guid]::NewGuid().ToString('n'))"
    New-Item -ItemType Directory -Path $script:ReportRoot -Force | Out-Null
    $script:BaselinePath = Join-Path -Path $script:ReportRoot -ChildPath 'label-guids.json'
    # Prefixed, and the prefix comes from the audit's own naming.bicep parse (F32):
    # the labels are <prefix>-public/... and an audit still looking for the bare
    # generic words would match an ADOPTER'S OWN taxonomy and report it green.
    $script:Prefix = Get-CompanyPrefix
    $script:ExpectedLabel = Get-ExpectedLabelName -Prefix $script:Prefix
    $script:Baseline = [ordered]@{
        "$($script:Prefix)-public"            = '11111111-1111-1111-1111-111111111111'
        "$($script:Prefix)-internal"          = '22222222-2222-2222-2222-222222222222'
        "$($script:Prefix)-confidential"      = '33333333-3333-3333-3333-333333333333'
        "$($script:Prefix)-export-controlled" = '44444444-4444-4444-4444-444444444444'
    }
    Set-Content -LiteralPath $script:BaselinePath -Value ($script:Baseline | ConvertTo-Json) -Encoding utf8

    # MLS_VERIFIER_CERT_PATH / _PASSWORD are here for the same reason as the rest: the
    # audit now resolves its S&C certificate from either of two forms, and a developer
    # who has one exported would otherwise change what these tests exercise (F172).
    $script:EnvironmentVariable = @('TENANT_DOMAIN', 'MLS_TENANT_DOMAIN', 'MLS_VERIFIER_APP_ID',
        'MLS_VERIFIER_CERT', 'MLS_VERIFIER_CERT_PATH', 'MLS_VERIFIER_CERT_PASSWORD')
    $script:SavedEnvironment = @{}
    foreach ($name in $script:EnvironmentVariable) { $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
    # Cleared, not merely saved: these two are new and a developer running the suite on a
    # box that has staged a real PFX would otherwise send the audit down the file branch
    # while the test believes it is exercising the thumbprint one.
    foreach ($name in @('MLS_VERIFIER_CERT_PATH', 'MLS_VERIFIER_CERT_PASSWORD')) {
        [Environment]::SetEnvironmentVariable($name, $null)
    }

    function Get-Row {
        param($Context, [string]$Id)
        return @($Context.Criterion | Where-Object { $_.Id -eq $Id })[0]
    }

    function Invoke-AuditForTest {
        param([switch]$NoRetry, [string]$LabelGuidPath = $script:BaselinePath, [string]$Checkpoint = 'layer')
        Invoke-Main -Organization 'meridianlaunch.onmicrosoft.com' -VerifierAppId 'ver-app' `
            -CertificateThumbprint 'ABCD1234' -ExpectedLabel $script:ExpectedLabel `
            -LabelGuidPath $LabelGuidPath -Checkpoint $Checkpoint -ReportRoot $script:ReportRoot -NoRetry:$NoRetry
    }
}

AfterAll {
    foreach ($name in $script:EnvironmentVariable) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnvironment[$name]) }
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:ReportRoot) {
        Remove-Item -LiteralPath $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'layer-04-audit' {
    BeforeEach {
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'
        Mock Connect-MlsCompliance {}

        $script:Labels = @($script:Baseline.Keys | ForEach-Object {
                [pscustomobject]@{ DisplayName = $_; Guid = $script:Baseline[$_] }
            })
        Mock Get-MlsLabel { return $script:Labels }

        # V4.3 default: a policy that matches Invoke-Main's own defaults exactly, so
        # every pre-existing V4.1/V4.2 test (which doesn't care about the policy at all)
        # keeps seeing an all-PASS run unless it overrides this mock itself.
        $script:Policy = [pscustomobject]@{
            Identity         = 'mls-demo-label-policy'
            Labels           = $script:ExpectedLabel
            # F121: the policy publishes to All - L3's security groups are not valid
            # Security & Compliance recipients and never were.
            ExchangeLocation = @('All')
        }
        Mock Get-MlsLabelPolicy { return $script:Policy }
    }

    Context 'all criteria pass' {
        It 'records V4.1, V4.2 and V4.3 as PASS against the recorded baseline' {
            $context = Invoke-AuditForTest
            @($context.Criterion).Id | Should -Be @('V4.1', 'V4.2', 'V4.3')
            @($context.Criterion | Where-Object { $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            Get-MlsExitCode -Context $context | Should -Be 0
            Should -Invoke Connect-MlsCompliance -Exactly -Times 1
        }

        It 'records the observed GUIDs as evidence in the report context' {
            $context = Invoke-AuditForTest
            $context.Evidence['labelGuids'][$script:ExpectedLabel[0]] | Should -Be $script:Baseline[$script:ExpectedLabel[0]]
        }

        It 'names the checkpoint L11 re-executes it at' {
            $context = Invoke-AuditForTest -Checkpoint 'post-down'
            (Get-Row -Context $context -Id 'V4.2').Observed | Should -BeLike "*post-down*"
        }
    }

    Context 'the expected taxonomy is prefixed, and resolved from naming.bicep (F32)' {
        # The audit used to default -ExpectedLabel to the bare 'Public', 'Internal',
        # 'Confidential', 'Export-Controlled'. Those are an adopter's own labels;
        # matching on them would have reported a healthy demo built out of somebody
        # else's Purview taxonomy.
        It 'resolves the four expected names from the company prefix, with no bare generic word' {
            $resolved = Get-ExpectedLabelName -Prefix $script:Prefix
            @($resolved).Count | Should -Be 4
            foreach ($name in $resolved) { $name | Should -BeLike "$($script:Prefix)-*" }
            foreach ($bare in @('Public', 'Internal', 'Confidential', 'Export-Controlled')) {
                $resolved | Should -Not -Contain $bare
            }
        }

        It 'reads the prefix out of infra/bicep/naming.bicep rather than hardcoding it' {
            $namingPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'infra', 'bicep', 'naming.bicep'
            Get-CompanyPrefix -Path $namingPath | Should -Be $script:Prefix
            { Get-CompanyPrefix -Path (Join-Path -Path $script:ReportRoot -ChildPath 'no-such-naming.bicep') } |
                Should -Throw '*naming.bicep*'
        }

        It 'defaults to the prefixed taxonomy and the prefixed policy name when neither is passed' {
            # -ExpectedLabel @() / -ExpectedLabelPolicy '' is exactly what the script
            # entry point hands Invoke-Main when the caller passes nothing.
            $context = Invoke-Main -Organization 'meridianlaunch.onmicrosoft.com' -VerifierAppId 'ver-app' `
                -CertificateThumbprint 'ABCD1234' -ExpectedLabel @() -ExpectedLabelPolicy '' `
                -LabelGuidPath $script:BaselinePath -ReportRoot $script:ReportRoot -NoRetry
            (Get-Row -Context $context -Id 'V4.1').Status | Should -Be 'PASS'
            (Get-Row -Context $context -Id 'V4.1').Expected | Should -BeLike "*$($script:Prefix)-confidential*"
            (Get-Row -Context $context -Id 'V4.3').Expected | Should -BeLike "*$($script:Prefix)-demo-label-policy*"
        }
    }

    Context 'a criterion fails on a realistic wrong value' {
        It 'fails V4.1 on GUID drift and refuses to re-baseline' {
            $script:Labels = @(
                [pscustomobject]@{ DisplayName = $script:ExpectedLabel[0]; Guid = '55555555-5555-5555-5555-555555555555' }
                [pscustomobject]@{ DisplayName = $script:ExpectedLabel[1]; Guid = $script:Baseline[$script:ExpectedLabel[1]] }
                [pscustomobject]@{ DisplayName = $script:ExpectedLabel[2]; Guid = $script:Baseline[$script:ExpectedLabel[2]] }
                [pscustomobject]@{ DisplayName = $script:ExpectedLabel[3]; Guid = $script:Baseline[$script:ExpectedLabel[3]] }
            )
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V4.1'
            $row.Status | Should -Be 'FAIL'
            $row.Attempt | Should -Be 1
            $row.Observed | Should -BeLike '*GUID drift*'
            $row.Detail | Should -BeLike '*do NOT re-baseline*'
            (Get-Row -Context $context -Id 'V4.2').Status | Should -Be 'FAIL'
            Get-MlsExitCode -Context $context | Should -Be 1
        }

        It 'fails V4.1 when a label is missing from the taxonomy' {
            $script:Labels = @($script:Labels | Where-Object { $_.DisplayName -ne $script:ExpectedLabel[3] })
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V4.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike "*missing*$($script:ExpectedLabel[3])*"
        }
    }

    Context 'retry' {
        It 'retries V4.1 through S&C replication lag without sleeping the whole window' {
            $script:Calls = 0
            Mock Get-MlsLabel {
                $script:Calls++
                if ($script:Calls -lt 2) {
                    return @($script:Labels | Where-Object { $_.DisplayName -ne $script:ExpectedLabel[3] })
                }
                return $script:Labels
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V4.1'
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
        It 'records V4.1 as FAIL when Get-Label errors, and still records V4.2 and V4.3' {
            Mock Get-MlsLabel { throw 'Connect-IPPSSession: The term Get-Label is not recognized (no S&C session).' }
            $context = Invoke-AuditForTest -NoRetry
            @($context.Criterion).Count | Should -Be 3
            (Get-Row -Context $context -Id 'V4.1').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V4.1').Observed | Should -BeLike '*no S&C session*'
        }
    }

    Context 'missing input' {
        It 'refuses to run without the tenant domain' {
            foreach ($name in @('TENANT_DOMAIN', 'MLS_TENANT_DOMAIN')) { [Environment]::SetEnvironmentVariable($name, $null) }
            { Invoke-Main -Organization '' -VerifierAppId 'a' -CertificateThumbprint 'b' -ReportRoot $script:ReportRoot } |
                Should -Throw '*Organization*'
        }

        It 'records V4.2 as SKIP - never a silent pass - when no baseline has been recorded' {
            $context = Invoke-AuditForTest -LabelGuidPath (Join-Path -Path $script:ReportRoot -ChildPath 'absent.json')
            $row = Get-Row -Context $context -Id 'V4.2'
            $row.Status | Should -Be 'SKIP'
            $row.Detail | Should -BeLike '*label-guids.json*'
            (Get-Row -Context $context -Id 'V4.1').Status | Should -Be 'PASS'
            (Get-Row -Context $context -Id 'V4.1').Detail | Should -BeLike '*first-run record*'
        }
    }

    Context 'V4.3 - label policy exists and is scoped (F18, F121)' {
        It 'fails when no policy has been published at all' {
            Mock Get-MlsLabelPolicy { return $null }
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V4.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*not found*'
            # A missing policy must not drag V4.1 (label existence) down with it - they
            # are independent criteria checking independent objects.
            (Get-Row -Context $context -Id 'V4.1').Status | Should -Be 'PASS'
            Get-MlsExitCode -Context $context | Should -Be 1
        }

        It 'fails when the published policy is scoped to nobody' {
            # Was "missing one of the demo groups", which the policy no longer names:
            # since F121 it publishes to All, because L3's security groups are not valid
            # Security & Compliance recipients. A policy scoped to nothing still has to
            # fail - a label taxonomy nobody can apply is not a delivered layer.
            $script:Policy.ExchangeLocation = @()
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V4.3'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*scoping error*All*'
        }

        It 'fails when the published policy is scoped to a group nobody asked for' {
            $script:Policy.ExchangeLocation = @('All', 'mls-contractors')
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V4.3'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*extra*mls-contractors*'
        }

        It 'fails when the published policy does not name one of the four labels' {
            $script:Policy.Labels = @($script:ExpectedLabel | Select-Object -First 3)
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V4.3'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike "*labels missing*$($script:ExpectedLabel[3])*"
        }

        It 'is not in the master-plan traceability convention - documented as supplementary' {
            $context = Invoke-AuditForTest
            (Get-Row -Context $context -Id 'V4.3').Description | Should -BeLike '*supplementary*'
        }
    }
}
