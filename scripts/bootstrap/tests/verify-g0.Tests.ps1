# Pester tests for scripts/bootstrap/verify-g0.ps1 - all az calls mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    $script:Sub = '00000000-0000-0000-0000-000000000000'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'verify-g0.ps1') -SubscriptionId $script:Sub
    Set-StrictMode -Off

    $script:RoleIds = @(
        '741f803b-c850-494e-b5df-cde7c675a1ca',
        '62a82d76-70ea-41e2-9197-370581804d09',
        '18a4783c-866b-4cc7-a460-3d5e5662c884', # Application.ReadWrite.OwnedBy
        '01c0a623-fc9b-48e9-b794-0756f8e8f067',
        '7ab1d382-f21e-4acd-a863-ba3e13f7da61'
    )

    function Get-AzArgValue {
        param([string[]]$Arguments, [string]$Name)
        $index = [array]::IndexOf($Arguments, $Name)
        if ($index -ge 0 -and ($index + 1) -lt $Arguments.Count) { return $Arguments[$index + 1] }
        return $null
    }

    function Invoke-VerifyForTest {
        Invoke-Main -SubscriptionId $script:Sub -DeployerAppName 'mls-github-deployer' `
            -VerifierAppName 'mls-verifier' -Repository 'paulcfuqua/azure-devsecops-demo' `
            -EnvironmentName 'demo' -VerifierEnvironmentName 'verify' `
            -BudgetName 'mls-monthly-budget' -BudgetAmount 75
    }

    function Get-Row {
        param($Results, [string]$Check)
        return @($Results | Where-Object { $_.Check -eq $Check })[0]
    }
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
}

Describe 'verify-g0' {
    BeforeEach {
        # Happy-path dataset; individual tests break specific pieces.
        $script:MockAccount = [pscustomobject]@{
            id       = $script:Sub
            tenantId = '11111111-1111-1111-1111-111111111111'
            user     = [pscustomobject]@{ name = 'human@contoso.example' }
        }
        $script:Apps = @{
            'mls-github-deployer' = @([pscustomobject]@{ id = 'dep-obj'; appId = 'dep-app'; displayName = 'mls-github-deployer' })
            'mls-verifier'        = @([pscustomobject]@{ id = 'ver-obj'; appId = 'ver-app'; displayName = 'mls-verifier' })
        }
        # Fed creds are keyed by app OBJECT id (dep-obj / ver-obj), mirroring the real
        # `az ad app federated-credential list --id <objectId>` call - Test-VerifierApp
        # reads BOTH apps' credentials to check the verifier's subject is distinct from
        # the deployer's (2026-08-26 findings F6/F7), so a mock that ignored --id would
        # mask that distinctness check entirely.
        $script:FedCredsByAppObjectId = @{
            'dep-obj' = @([pscustomobject]@{ subject = 'repo:paulcfuqua/azure-devsecops-demo:environment:demo' })
            'ver-obj' = @([pscustomobject]@{ subject = 'repo:paulcfuqua/azure-devsecops-demo:environment:verify' })
        }
        $script:Sps = @{ 'dep-app' = @([pscustomobject]@{ id = 'sp-dep' }) }
        $script:RoleAssignments = @([pscustomobject]@{ id = 'ra1' })
        $script:AppRoleAssignments = [pscustomobject]@{
            value = @($script:RoleIds | ForEach-Object { [pscustomobject]@{ appRoleId = $_ } })
        }
        $script:FabricCapacities = [pscustomobject]@{
            value = @([pscustomobject]@{ id = 'cap1'; displayName = 'mlstrial'; state = 'Active' })
        }
        $script:Skus = [pscustomobject]@{
            value = @(
                [pscustomobject]@{ skuPartNumber = 'SPE_E5'; consumedUnits = 6 }
                [pscustomobject]@{ skuPartNumber = 'EMSPREMIUM'; consumedUnits = 6 }
            )
        }
        $script:Budget = [pscustomobject]@{
            name       = 'mls-monthly-budget'
            properties = [pscustomobject]@{ amount = 75 }
        }
        Mock Invoke-AzCli {
            $joined = $Arguments -join ' '
            if ($joined -like 'account show*') { return $script:MockAccount }
            if ($joined -like 'ad app list*') {
                return $script:Apps[(Get-AzArgValue $Arguments '--display-name')]
            }
            if ($joined -like 'ad app federated-credential list*') {
                return $script:FedCredsByAppObjectId[(Get-AzArgValue $Arguments '--id')]
            }
            if ($joined -like 'ad sp list*') {
                $filter = Get-AzArgValue $Arguments '--filter'
                if ($filter -match "appId eq '([^']+)'") { return $script:Sps[$Matches[1]] }
                return $null
            }
            if ($joined -like 'role assignment list*') { return $script:RoleAssignments }
            if ($joined -like '*appRoleAssignments*') { return $script:AppRoleAssignments }
            if ($joined -like '*api.fabric.microsoft.com/v1/capacities*') { return $script:FabricCapacities }
            if ($joined -like '*subscribedSkus*') { return $script:Skus }
            if ($joined -like '*Microsoft.Consumption/budgets*') { return $script:Budget }
            return $null
        }
    }

    Context 'aggregation - all green' {
        It 'returns 9 rows, all PASS, and a fail count of 0' {
            $results = Invoke-VerifyForTest
            @($results).Count | Should -Be 9
            @($results | Where-Object { $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            Get-FailCount -Results $results | Should -Be 0
        }

        It 'is strictly read-only (no create/update/delete or write REST verbs)' {
            Invoke-VerifyForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -match '\b(create|update|delete)\b|--method (put|post|patch|delete)'
            }
        }
    }

    Context 'aggregation - single failures surface as single FAIL rows' {
        It 'flags a missing budget' {
            $script:Budget = $null
            $results = Invoke-VerifyForTest
            (Get-Row $results 'Budget').Status | Should -Be 'FAIL'
            Get-FailCount -Results $results | Should -Be 1
        }

        It 'flags a wrong budget amount' {
            $script:Budget.properties.amount = 100
            $results = Invoke-VerifyForTest
            (Get-Row $results 'Budget').Status | Should -Be 'FAIL'
            (Get-Row $results 'Budget').Detail | Should -BeLike '*expected 75*'
        }

        It 'flags partially-consented Graph permissions and names the missing ones' {
            $script:AppRoleAssignments = [pscustomobject]@{
                value = @($script:RoleIds[0..2] | ForEach-Object { [pscustomobject]@{ appRoleId = $_ } })
            }
            $results = Invoke-VerifyForTest
            $row = Get-Row $results 'GraphConsent'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*Policy.ReadWrite.ConditionalAccess*'
            $row.Detail | Should -BeLike '*Directory.Read.All*'
        }

        It 'flags a missing federation subject' {
            $script:FedCredsByAppObjectId['dep-obj'] = @()
            $results = Invoke-VerifyForTest
            $row = Get-Row $results 'Federation'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*environment:demo*'
        }

        It 'flags a verifier with no federated credential at all (2026-08-26 finding F6)' {
            $script:FedCredsByAppObjectId['ver-obj'] = @()
            $results = Invoke-VerifyForTest
            $row = Get-Row $results 'VerifierApp'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*environment:verify*'
        }

        It 'flags a verifier federated to the SAME subject as the deployer (2026-08-26 finding F7)' {
            # The exact misconfiguration the fix exists to prevent: reusing the deployer's
            # environment subject instead of giving the verifier a distinct one of its own.
            # Modelled by pointing -VerifierEnvironmentName at 'demo' (the deployer's own
            # -EnvironmentName) and federating the verifier to that same subject.
            $script:FedCredsByAppObjectId['ver-obj'] = @([pscustomobject]@{ subject = 'repo:paulcfuqua/azure-devsecops-demo:environment:demo' })
            $results = Invoke-Main -SubscriptionId $script:Sub -DeployerAppName 'mls-github-deployer' `
                -VerifierAppName 'mls-verifier' -Repository 'paulcfuqua/azure-devsecops-demo' `
                -EnvironmentName 'demo' -VerifierEnvironmentName 'demo' `
                -BudgetName 'mls-monthly-budget' -BudgetAmount 75
            $row = Get-Row $results 'VerifierApp'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*distinct*'
        }

        It 'flags missing licenses by trial name' {
            $script:Skus = [pscustomobject]@{
                value = @([pscustomobject]@{ skuPartNumber = 'SPE_E5'; consumedUnits = 6 })
            }
            $results = Invoke-VerifyForTest
            $row = Get-Row $results 'Licenses'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*EMS E5*'
        }

        It 'flags a wrong active subscription' {
            $script:MockAccount.id = '99999999-9999-9999-9999-999999999999'
            $results = Invoke-VerifyForTest
            (Get-Row $results 'CliLogin').Status | Should -Be 'FAIL'
        }

        It 'passes FabricCapacity for a paused (non-Active) capacity' {
            $script:FabricCapacities.value[0].state = 'Paused'
            $results = Invoke-VerifyForTest
            (Get-Row $results 'FabricCapacity').Status | Should -Be 'PASS'
        }

        It 'fails FabricCapacity when no capacity is visible' {
            $script:FabricCapacities = [pscustomobject]@{ value = @() }
            $results = Invoke-VerifyForTest
            (Get-Row $results 'FabricCapacity').Status | Should -Be 'FAIL'
        }
    }

    Context 'aggregation - checks that throw become FAIL rows, not crashes' {
        It 'survives az being completely broken' {
            Mock Invoke-AzCli { throw 'az exploded' }
            $results = Invoke-VerifyForTest
            @($results).Count | Should -Be 9
            @($results | Where-Object { $_.Status -eq 'FAIL' }).Count | Should -Be 9
            Get-FailCount -Results $results | Should -Be 9
        }
    }

    Context 'Get-FailCount' {
        It 'counts only FAIL rows' {
            $rows = @(
                [pscustomobject]@{ Check = 'a'; Status = 'PASS'; Detail = '' }
                [pscustomobject]@{ Check = 'b'; Status = 'FAIL'; Detail = '' }
                [pscustomobject]@{ Check = 'c'; Status = 'FAIL'; Detail = '' }
            )
            Get-FailCount -Results $rows | Should -Be 2
        }

        It 'returns 0 for an empty set' {
            Get-FailCount -Results @() | Should -Be 0
        }
    }
}
