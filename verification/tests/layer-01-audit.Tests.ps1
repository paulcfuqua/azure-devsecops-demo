# Pester tests for verification/layer-01-audit.ps1 - every gh, git and Graph call mocked;
# zero cloud calls, no tenant required.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-01-audit.ps1')
    Set-StrictMode -Off

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l01-$([guid]::NewGuid().ToString('n'))"
    $script:Repository = 'paulcfuqua/azure-devsecops'
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
        $env:AZURE_TENANT_ID = '11111111-1111-1111-1111-111111111111'
        $env:AZURE_SUBSCRIPTION_ID = '22222222-2222-2222-2222-222222222222'
        $env:FABRIC_CAPACITY_ID = '33333333-3333-3333-3333-333333333333'

        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'

        $script:RunConclusion = 'success'
        $script:JobConclusion = 'success'
        $script:SecretScanning = 'enabled'
        $script:PushProtection = 'enabled'
        $script:Subject = 'repo:paulcfuqua/azure-devsecops:environment:demo'
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
            (Get-Row -Context $context -Id 'V1.2').Command | Should -BeLike '*gh api repos/paulcfuqua/azure-devsecops*'
            (Get-Row -Context $context -Id 'V1.2').Expected | Should -Be '{"ss":"enabled","pp":"enabled"}'
            (Get-Row -Context $context -Id 'V1.4').Expected | Should -BeLike '*repo:paulcfuqua/azure-devsecops:environment:demo*'
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
            $script:Subject = 'repo:paulcfuqua/azure-devsecops:ref:refs/heads/*'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V1.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*refs/heads/**'
            $row.Detail | Should -BeLike '*Do not widen the subject*'
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
            $row.SleptSeconds | Should -Be 300
            $row.SleptSeconds | Should -BeLessThan (30 * 60)
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
