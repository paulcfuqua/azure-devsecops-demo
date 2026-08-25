# Pester tests for verification/layer-04-audit.ps1 - the S&C session and Get-Label are
# mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-04-audit.ps1')
    Set-StrictMode -Off

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l04-$([guid]::NewGuid().ToString('n'))"
    New-Item -ItemType Directory -Path $script:ReportRoot -Force | Out-Null
    $script:BaselinePath = Join-Path -Path $script:ReportRoot -ChildPath 'label-guids.json'
    $script:Baseline = [ordered]@{
        'Public'            = '11111111-1111-1111-1111-111111111111'
        'Internal'          = '22222222-2222-2222-2222-222222222222'
        'Confidential'      = '33333333-3333-3333-3333-333333333333'
        'Export-Controlled' = '44444444-4444-4444-4444-444444444444'
    }
    Set-Content -LiteralPath $script:BaselinePath -Value ($script:Baseline | ConvertTo-Json) -Encoding utf8

    $script:EnvironmentVariable = @('TENANT_DOMAIN', 'MLS_TENANT_DOMAIN', 'MLS_VERIFIER_APP_ID', 'MLS_VERIFIER_CERT')
    $script:SavedEnvironment = @{}
    foreach ($name in $script:EnvironmentVariable) { $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

    function Get-Row {
        param($Context, [string]$Id)
        return @($Context.Criterion | Where-Object { $_.Id -eq $Id })[0]
    }

    function Invoke-AuditForTest {
        param([switch]$NoRetry, [string]$LabelGuidPath = $script:BaselinePath, [string]$Checkpoint = 'layer')
        Invoke-Main -Organization 'meridianlaunch.onmicrosoft.com' -VerifierAppId 'ver-app' `
            -CertificateThumbprint 'ABCD1234' -ExpectedLabel @('Public', 'Internal', 'Confidential', 'Export-Controlled') `
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
    }

    Context 'all criteria pass' {
        It 'records V4.1 and V4.2 as PASS against the recorded baseline' {
            $context = Invoke-AuditForTest
            @($context.Criterion).Id | Should -Be @('V4.1', 'V4.2')
            @($context.Criterion | Where-Object { $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            Get-MlsExitCode -Context $context | Should -Be 0
            Should -Invoke Connect-MlsCompliance -Exactly -Times 1
        }

        It 'records the observed GUIDs as evidence in the report context' {
            $context = Invoke-AuditForTest
            $context.Evidence['labelGuids']['Public'] | Should -Be $script:Baseline['Public']
        }

        It 'names the checkpoint L11 re-executes it at' {
            $context = Invoke-AuditForTest -Checkpoint 'post-down'
            (Get-Row -Context $context -Id 'V4.2').Observed | Should -BeLike "*post-down*"
        }
    }

    Context 'a criterion fails on a realistic wrong value' {
        It 'fails V4.1 on GUID drift and refuses to re-baseline' {
            $script:Labels = @(
                [pscustomobject]@{ DisplayName = 'Public'; Guid = '55555555-5555-5555-5555-555555555555' }
                [pscustomobject]@{ DisplayName = 'Internal'; Guid = $script:Baseline['Internal'] }
                [pscustomobject]@{ DisplayName = 'Confidential'; Guid = $script:Baseline['Confidential'] }
                [pscustomobject]@{ DisplayName = 'Export-Controlled'; Guid = $script:Baseline['Export-Controlled'] }
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
            $script:Labels = @($script:Labels | Where-Object { $_.DisplayName -ne 'Export-Controlled' })
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V4.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*missing*Export-Controlled*'
        }
    }

    Context 'retry' {
        It 'retries V4.1 through S&C replication lag without sleeping the whole window' {
            $script:Calls = 0
            Mock Get-MlsLabel {
                $script:Calls++
                if ($script:Calls -lt 2) {
                    return @($script:Labels | Where-Object { $_.DisplayName -ne 'Export-Controlled' })
                }
                return $script:Labels
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V4.1'
            $row.Status | Should -Be 'PASS'
            $row.Attempt | Should -Be 2
            $row.SleptSeconds | Should -Be 300
            $row.SleptSeconds | Should -BeLessThan (30 * 60)
            Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 1
        }
    }

    Context 'a check that throws' {
        It 'records V4.1 as FAIL when Get-Label errors, and still records V4.2' {
            Mock Get-MlsLabel { throw 'Connect-IPPSSession: The term Get-Label is not recognized (no S&C session).' }
            $context = Invoke-AuditForTest -NoRetry
            @($context.Criterion).Count | Should -Be 2
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
}
