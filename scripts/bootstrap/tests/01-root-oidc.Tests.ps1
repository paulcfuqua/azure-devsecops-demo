# Pester tests for scripts/bootstrap/01-root-oidc.ps1 - all az calls mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    $script:Sub = '00000000-0000-0000-0000-000000000000'
    $script:Tenant = '11111111-1111-1111-1111-111111111111'
    . (Join-Path $PSScriptRoot '..' '01-root-oidc.ps1') -SubscriptionId $script:Sub
    Set-StrictMode -Off

    $script:GraphRoleIds = @(
        '741f803b-c850-494e-b5df-cde7c675a1ca', # User.ReadWrite.All
        '62a82d76-70ea-41e2-9197-370581804d09', # Group.ReadWrite.All
        '1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9', # Application.ReadWrite.All
        '01c0a623-fc9b-48e9-b794-0756f8e8f067', # Policy.ReadWrite.ConditionalAccess
        '7ab1d382-f21e-4acd-a863-ba3e13f7da61'  # Directory.Read.All
    )

    function Get-AzArgValue {
        param([string[]]$Arguments, [string]$Name)
        $index = [array]::IndexOf($Arguments, $Name)
        if ($index -ge 0 -and ($index + 1) -lt $Arguments.Count) { return $Arguments[$index + 1] }
        return $null
    }

    function Invoke-MainForTest {
        param([switch]$WhatIf)
        Invoke-Main -SubscriptionId $script:Sub -Repository 'paulcfuqua/azure-devsecops' `
            -EnvironmentName 'demo' -DeployerAppName 'mls-github-deployer' -VerifierAppName 'mls-verifier' `
            -WhatIf:$WhatIf
    }
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
}

Describe '01-root-oidc' {
    BeforeEach {
        Mock Write-Status {}
        $script:CapturedFedSubjects = @()
        $script:CapturedGraphPayloads = @()
        Mock Invoke-AzCli {
            $joined = $Arguments -join ' '
            if ($joined -like 'account show*') { return $script:MockAccount }
            if ($joined -like 'account set*') { return $null }
            if ($joined -like 'ad app list*') {
                $name = Get-AzArgValue $Arguments '--display-name'
                return $script:ExistingApps[$name]
            }
            if ($joined -like 'ad app federated-credential list*') {
                $id = Get-AzArgValue $Arguments '--id'
                return $script:ExistingFedCreds[$id]
            }
            if ($joined -like 'ad app federated-credential create*') {
                $file = (Get-AzArgValue $Arguments '--parameters').TrimStart('@')
                $script:CapturedFedSubjects += (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).subject
                return [pscustomobject]@{ id = 'fc-new' }
            }
            if ($joined -like 'ad app create*') {
                $name = Get-AzArgValue $Arguments '--display-name'
                return $script:CreatedApps[$name]
            }
            if ($joined -like 'ad app show*') {
                $id = Get-AzArgValue $Arguments '--id'
                return $script:AppDetails[$id]
            }
            if ($joined -like 'ad app update*') {
                $file = (Get-AzArgValue $Arguments '--required-resource-accesses').TrimStart('@')
                $script:CapturedGraphPayloads += , (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json)
                return $null
            }
            if ($joined -like 'ad sp list*') {
                $filter = Get-AzArgValue $Arguments '--filter'
                if ($filter -match "appId eq '([^']+)'") { return $script:ExistingSps[$Matches[1]] }
                return $null
            }
            if ($joined -like 'ad sp create*') {
                $appId = Get-AzArgValue $Arguments '--id'
                return [pscustomobject]@{ id = "sp-$appId"; appId = $appId }
            }
            if ($joined -like 'role assignment list*') { return $script:ExistingRoleAssignments }
            if ($joined -like 'role assignment create*') { return [pscustomobject]@{ id = 'ra-new' } }
            return $null
        }
        $script:MockAccount = [pscustomobject]@{
            id       = $script:Sub
            tenantId = $script:Tenant
            user     = [pscustomobject]@{ name = 'human@contoso.example' }
        }
        # default: empty tenant
        $script:ExistingApps = @{}
        $script:ExistingFedCreds = @{}
        $script:ExistingSps = @{}
        $script:ExistingRoleAssignments = $null
        $script:CreatedApps = @{
            'mls-github-deployer' = [pscustomobject]@{ id = 'dep-obj'; appId = 'dep-app'; displayName = 'mls-github-deployer' }
            'mls-verifier'        = [pscustomobject]@{ id = 'ver-obj'; appId = 'ver-app'; displayName = 'mls-verifier' }
        }
        $script:AppDetails = @{
            'dep-obj' = [pscustomobject]@{ id = 'dep-obj'; appId = 'dep-app' }
            'ver-obj' = [pscustomobject]@{ id = 'ver-obj'; appId = 'ver-app' }
        }
    }

    Context 'fresh tenant (nothing exists yet)' {
        It 'creates both app registrations' {
            Invoke-MainForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 2 -ParameterFilter {
                ($Arguments -join ' ') -like 'ad app create*'
            }
        }

        It 'creates federated credentials for the main branch and the demo environment' {
            Invoke-MainForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 2 -ParameterFilter {
                ($Arguments -join ' ') -like 'ad app federated-credential create*'
            }
            $script:CapturedFedSubjects | Should -Contain 'repo:paulcfuqua/azure-devsecops:ref:refs/heads/main'
            $script:CapturedFedSubjects | Should -Contain 'repo:paulcfuqua/azure-devsecops:environment:demo'
        }

        It 'creates a service principal per app' {
            Invoke-MainForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 2 -ParameterFilter {
                ($Arguments -join ' ') -like 'ad sp create*'
            }
        }

        It 'assigns Owner to the deployer and Reader to the verifier at subscription scope' {
            Invoke-MainForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like 'role assignment create*' -and
                $Arguments -contains 'Owner' -and $Arguments -contains "/subscriptions/$($script:Sub)"
            }
            Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like 'role assignment create*' -and
                $Arguments -contains 'Reader' -and $Arguments -contains "/subscriptions/$($script:Sub)"
            }
        }

        It 'declares all 5 Graph application roles on the deployer and Directory.Read.All on the verifier' {
            Invoke-MainForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 2 -ParameterFilter {
                ($Arguments -join ' ') -like 'ad app update*'
            }
            $deployerPayload = $script:CapturedGraphPayloads[0]
            $granted = @($deployerPayload | Where-Object { $_.resourceAppId -eq '00000003-0000-0000-c000-000000000000' }).resourceAccess.id
            foreach ($roleId in $script:GraphRoleIds) { $granted | Should -Contain $roleId }
            $verifierPayload = $script:CapturedGraphPayloads[1]
            $verifierGranted = @($verifierPayload | Where-Object { $_.resourceAppId -eq '00000003-0000-0000-c000-000000000000' }).resourceAccess.id
            $verifierGranted | Should -Contain '7ab1d382-f21e-4acd-a863-ba3e13f7da61' # Directory.Read.All
            $verifierGranted | Should -Contain '246dd0d5-5bd0-4def-940b-0421030a5b68' # Policy.Read.All
            $verifierGranted.Count | Should -Be 2
        }

        It 'prints admin-consent URLs but NEVER calls az ad app permission admin-consent' {
            $result = Invoke-MainForTest
            $result.ConsentUrls['mls-github-deployer'] |
                Should -Be "https://login.microsoftonline.com/$($script:Tenant)/adminconsent?client_id=dep-app"
            $result.ConsentUrls['mls-verifier'] |
                Should -Be "https://login.microsoftonline.com/$($script:Tenant)/adminconsent?client_id=ver-app"
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -like '*admin-consent*'
            }
        }

        It 'fails clearly when az is not logged in' {
            $script:MockAccount = $null
            { Invoke-MainForTest } | Should -Throw '*not logged in*'
        }
    }

    Context 'everything already exists (idempotent re-run)' {
        BeforeEach {
            $script:ExistingApps = @{
                'mls-github-deployer' = @([pscustomobject]@{ id = 'dep-obj'; appId = 'dep-app'; displayName = 'mls-github-deployer' })
                'mls-verifier'        = @([pscustomobject]@{ id = 'ver-obj'; appId = 'ver-app'; displayName = 'mls-verifier' })
            }
            $script:ExistingFedCreds = @{
                'dep-obj' = @(
                    [pscustomobject]@{ id = 'fc1'; subject = 'repo:paulcfuqua/azure-devsecops:ref:refs/heads/main'; issuer = 'https://token.actions.githubusercontent.com'; audiences = @('api://AzureADTokenExchange') }
                    [pscustomobject]@{ id = 'fc2'; subject = 'repo:paulcfuqua/azure-devsecops:environment:demo'; issuer = 'https://token.actions.githubusercontent.com'; audiences = @('api://AzureADTokenExchange') }
                )
            }
            $script:ExistingSps = @{
                'dep-app' = @([pscustomobject]@{ id = 'sp-dep'; appId = 'dep-app' })
                'ver-app' = @([pscustomobject]@{ id = 'sp-ver'; appId = 'ver-app' })
            }
            $script:ExistingRoleAssignments = @([pscustomobject]@{ id = 'ra-existing' })
            $graphAccess = @([pscustomobject]@{
                    resourceAppId  = '00000003-0000-0000-c000-000000000000'
                    resourceAccess = @($script:GraphRoleIds | ForEach-Object { [pscustomobject]@{ id = $_; type = 'Role' } })
                })
            $script:AppDetails = @{
                'dep-obj' = [pscustomobject]@{ id = 'dep-obj'; appId = 'dep-app'; requiredResourceAccess = $graphAccess }
                'ver-obj' = [pscustomobject]@{ id = 'ver-obj'; appId = 'ver-app'; requiredResourceAccess = @([pscustomobject]@{
                            resourceAppId  = '00000003-0000-0000-c000-000000000000'
                            resourceAccess = @(
                                [pscustomobject]@{ id = '7ab1d382-f21e-4acd-a863-ba3e13f7da61'; type = 'Role' }
                                [pscustomobject]@{ id = '246dd0d5-5bd0-4def-940b-0421030a5b68'; type = 'Role' }
                            )
                        })
                }
            }
        }

        It 'issues no create or update calls at all' {
            Invoke-MainForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -match '\b(create|update)\b'
            }
        }

        It 'still prints both admin-consent URLs' {
            $result = Invoke-MainForTest
            $result.ConsentUrls.Keys | Should -Contain 'mls-github-deployer'
            $result.ConsentUrls.Keys | Should -Contain 'mls-verifier'
        }

        It 'updates a federated credential whose issuer drifted instead of duplicating it' {
            $script:ExistingFedCreds['dep-obj'][0].issuer = 'https://wrong.example'
            Invoke-MainForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like 'ad app federated-credential update*'
            }
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -like 'ad app federated-credential create*'
            }
        }
    }

    Context '-WhatIf makes no mutating calls' {
        It 'on a fresh tenant performs reads only' {
            $result = Invoke-MainForTest -WhatIf
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -match '\b(create|update|delete)\b'
            }
            $result.DeployerApp | Should -BeNullOrEmpty
            $result.VerifierApp | Should -BeNullOrEmpty
        }

        It 'with existing apps still performs reads only' {
            $script:ExistingApps = @{
                'mls-github-deployer' = @([pscustomobject]@{ id = 'dep-obj'; appId = 'dep-app'; displayName = 'mls-github-deployer' })
                'mls-verifier'        = @([pscustomobject]@{ id = 'ver-obj'; appId = 'ver-app'; displayName = 'mls-verifier' })
            }
            Invoke-MainForTest -WhatIf | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -match '\b(create|update|delete)\b'
            }
        }
    }
}
