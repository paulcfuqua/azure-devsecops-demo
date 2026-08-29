# Pester tests for scripts/bootstrap/verify-g0.ps1 - all az calls mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    $script:Sub = '00000000-0000-0000-0000-000000000000'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'verify-g0.ps1') -SubscriptionId $script:Sub
    # No Set-StrictMode -Off: the script under test sets -Version Latest and CI runs it
    # that way, so the harness must not relax the language mode it is testing (F49).

    # Derived from the script's own map, not a second hardcoded copy of it: a fixture
    # that lists the ids separately drifts the moment the map gains one, which is exactly
    # how six of these tests broke when Policy.Read.All was added (F50). WHICH roles are
    # correct is pinned by the explicit assertions in 01-root-oidc.Tests.ps1; this fixture
    # only says "the tenant consented whatever the script asks for".
    $script:RoleIds = @($script:GraphConsentedRoles.Values)

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
        # sku matters, not just state (finding F46). FTL4 is what the Power BI
        # admin API actually returned for a trial capacity started 2026-08-29 --
        # not FT1 (guessed) and not F4 (what Microsoft's doc says in prose).
        $script:FabricCapacities = [pscustomobject]@{
            value = @([pscustomobject]@{ id = 'cap1'; displayName = 'mlstrial'; sku = 'FTL4'; state = 'Active' })
        }
        # Shaped like a REAL Microsoft 365 E5 tenant (finding F46): one SKU whose
        # service plans carry the Entra ID P2 / AIP / MFA capabilities. There is no
        # separate EMSPREMIUM row, because a tenant on M365 E5 does not have one --
        # which is exactly what the old two-SKU assertion got wrong.
        $script:Skus = [pscustomobject]@{
            value = @(
                [pscustomobject]@{
                    skuPartNumber = 'SPE_E5'
                    consumedUnits = 6
                    servicePlans  = @(
                        [pscustomobject]@{ servicePlanName = 'AAD_PREMIUM_P2'; provisioningStatus = 'Success' }
                        [pscustomobject]@{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }
                        [pscustomobject]@{ servicePlanName = 'RMS_S_PREMIUM'; provisioningStatus = 'Success' }
                        [pscustomobject]@{ servicePlanName = 'RMS_S_PREMIUM2'; provisioningStatus = 'Success' }
                        [pscustomobject]@{ servicePlanName = 'MFA_PREMIUM'; provisioningStatus = 'Success' }
                        [pscustomobject]@{ servicePlanName = 'INTUNE_O365'; provisioningStatus = 'PendingActivation' }
                    )
                }
            )
        }
        $script:Budget = [pscustomobject]@{
            name       = 'mls-monthly-budget'
            properties = [pscustomobject]@{ amount = 75 }
        }
        # C4, the Fabric service-principal settings (finding F46). Shaped like the
        # real tenant: the two the estate uses are on, the three admin-API ones off.
        $script:FabricTenantSettings = [pscustomobject]@{
            tenantSettings = @(
                [pscustomobject]@{ settingName = 'ServicePrincipalAccessGlobalAPIs'; enabled = $true }
                [pscustomobject]@{ settingName = 'ServicePrincipalAccessPermissionAPIs'; enabled = $true }
                [pscustomobject]@{ settingName = 'AllowServicePrincipalsUseReadAdminAPIs'; enabled = $false }
                [pscustomobject]@{ settingName = 'AllowServicePrincipalsUseWriteAdminAPIs'; enabled = $false }
                [pscustomobject]@{ settingName = 'AllowServicePrincipalsCreateAndUseProfiles'; enabled = $false }
            )
        }
        $script:EntraDiagnosticSettings = [pscustomobject]@{
            value = @(
                [pscustomobject]@{
                    name = 'mls-entra-law'
                    logs = @(
                        [pscustomobject]@{ category = 'SignInLogs'; enabled = $true }
                        [pscustomobject]@{ category = 'AuditLogs'; enabled = $true }
                    )
                }
            )
        }
        # Offline by default, exactly like 01-root-oidc.Tests.ps1: the real helper shells
        # out to gh, and a test that reaches the network is not a test.
        $script:SubClaimPrefix = $null
        Mock Get-GitHubSubClaimPrefix { $script:SubClaimPrefix }

        # graphId -> is the deployer SP a member? Drives `az ad group member check`.
        $script:GroupMembership = @{}

        Mock Invoke-AzCli {
            $joined = $Arguments -join ' '
            if ($joined -like 'ad group member check*') {
                $group = Get-AzArgValue $Arguments '--group'
                return [pscustomobject]@{ value = [bool]$script:GroupMembership[$group] }
            }
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
            if ($joined -like '*tenantsettings*') { return $script:FabricTenantSettings }
            if ($joined -like '*microsoft.aadiam*') { return $script:EntraDiagnosticSettings }
            return $null
        }
    }

    Context 'aggregation - all green' {
        It 'returns 11 rows, 10 PASS + 1 informational, and a fail count of 0' {
            $results = Invoke-VerifyForTest
            @($results).Count | Should -Be 11
            @($results | Where-Object { $_.Check -ne 'EntraDiagnostics' -and $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            (Get-Row $results 'EntraDiagnostics').Status | Should -Be 'INFO'
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

        It 'fails when GitHub presents an immutable subject and only the classic one is registered (F48)' {
            # The defect this closes: the check asserted only the hand-built classic
            # subject, so it passed on a deployer whose first real OIDC login was refused
            # with AADSTS700213. A gate that cannot see the failure it is meant to prevent
            # is the F49 shape again, one check down.
            $script:SubClaimPrefix = 'repo:paulcfuqua@51541817/azure-devsecops-demo@1347346268'
            $row = Get-Row (Invoke-VerifyForTest) 'Federation'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*51541817*'
        }

        It 'passes when both subject forms are registered' {
            $script:SubClaimPrefix = 'repo:paulcfuqua@51541817/azure-devsecops-demo@1347346268'
            $script:FedCredsByAppObjectId['dep-obj'] = @(
                [pscustomobject]@{ subject = 'repo:paulcfuqua/azure-devsecops-demo:environment:demo' }
                [pscustomobject]@{ subject = 'repo:paulcfuqua@51541817/azure-devsecops-demo@1347346268:environment:demo' }
            )
            $row = Get-Row (Invoke-VerifyForTest) 'Federation'
            $row.Status | Should -Be 'PASS'
        }

        It 'still passes on the classic subject alone when GitHub reports no immutable prefix' {
            # Backward compatible: a tenant whose GitHub does not present the immutable
            # form must not be failed for lacking a credential it will never need.
            $script:SubClaimPrefix = $null
            $row = Get-Row (Invoke-VerifyForTest) 'Federation'
            $row.Status | Should -Be 'PASS'
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

        It 'flags a MISSING CAPABILITY, not a missing SKU name (F46)' {
            # A tenant on a lesser SKU: Entra ID P1 but no P2, so risk-based CA and
            # the Identity Protection feed are unavailable. The old check asked
            # "is EMSPREMIUM present"; this one asks "can the estate do the thing".
            $script:Skus = [pscustomobject]@{
                value = @(
                    [pscustomobject]@{
                        skuPartNumber = 'SPE_E3'
                        consumedUnits = 6
                        servicePlans  = @(
                            [pscustomobject]@{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }
                            [pscustomobject]@{ servicePlanName = 'RMS_S_PREMIUM'; provisioningStatus = 'Success' }
                            [pscustomobject]@{ servicePlanName = 'MFA_PREMIUM'; provisioningStatus = 'Success' }
                        )
                    }
                )
            }
            $results = Invoke-VerifyForTest
            $row = Get-Row $results 'Licenses'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*AAD_PREMIUM_P2*'
        }

        It 'passes on Microsoft 365 E5 alone, with no EMSPREMIUM SKU present (F46)' {
            # The regression that mattered: this tenant shape FAILED the old check
            # while holding every capability the estate uses, and the failure told
            # the operator to buy an $18/user licence that would have added nothing.
            $results = Invoke-VerifyForTest
            $row = Get-Row $results 'Licenses'
            $row.Status | Should -Be 'PASS'
            $row.Detail | Should -BeLike '*SPE_E5*'
        }

        It 'refuses a SKU that is provisioned but assigned to nobody' {
            # consumedUnits, not prepaidUnits: an unassigned trial grants nothing.
            $script:Skus = [pscustomobject]@{
                value = @(
                    [pscustomobject]@{
                        skuPartNumber = 'SPE_E5'
                        consumedUnits = 0
                        servicePlans  = @(
                            [pscustomobject]@{ servicePlanName = 'AAD_PREMIUM_P2'; provisioningStatus = 'Success' }
                            [pscustomobject]@{ servicePlanName = 'RMS_S_PREMIUM'; provisioningStatus = 'Success' }
                            [pscustomobject]@{ servicePlanName = 'MFA_PREMIUM'; provisioningStatus = 'Success' }
                        )
                    }
                )
            }
            $results = Invoke-VerifyForTest
            $row = Get-Row $results 'Licenses'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*assigned seat*'
        }

        It 'REFUSES a Power BI capacity masquerading as Fabric (F46)' {
            # The false pass this check shipped with. Signing into Fabric for the
            # first time on a Microsoft 365 E5 tenant provisions "Premium Per User -
            # Reserved" (sku PP3) from the bundled Power BI Pro licence. It is
            # Active, it is a capacity, and it cannot host a lakehouse -- so the old
            # state-only assertion reported the tenant ready and L5 was where you
            # found out.
            $script:FabricCapacities = [pscustomobject]@{
                value = @([pscustomobject]@{ id = 'ppu'; displayName = 'Premium Per User - Reserved'; sku = 'PP3'; state = 'Active' })
            }
            $results = Invoke-VerifyForTest
            $row = Get-Row $results 'FabricCapacity'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*PP3*'
            $row.Detail | Should -BeLike '*Power BI only*'
        }

        It 'accepts every F-series SKU shape, including the real trial string FTL4' {
            # Regression pin. A tighter '^F(T)?\d+$' passed every mock in this file
            # and rejected the live trial capacity, because FTL4 has a letter
            # between the T and the digits. Only a real tenant surfaced it.
            foreach ($sku in @('FTL4', 'FT1', 'F2', 'F4', 'F64', 'F2048')) {
                $script:FabricCapacities = [pscustomobject]@{
                    value = @([pscustomobject]@{ id = 'c'; displayName = "cap-$sku"; sku = $sku; state = 'Active' })
                }
                $row = Get-Row (Invoke-VerifyForTest) 'FabricCapacity'
                $row.Status | Should -Be 'PASS' -Because "$sku is a Fabric capacity"
            }
        }

        It 'still rejects every Power BI SKU shape' {
            foreach ($sku in @('PP3', 'P1', 'P5', 'EM2', 'A4')) {
                $script:FabricCapacities = [pscustomobject]@{
                    value = @([pscustomobject]@{ id = 'c'; displayName = "cap-$sku"; sku = $sku; state = 'Active' })
                }
                $row = Get-Row (Invoke-VerifyForTest) 'FabricCapacity'
                $row.Status | Should -Be 'FAIL' -Because "$sku cannot run Fabric workloads"
            }
        }

        It 'accepts a paused F2, which is the expected state between deploys' {
            $script:FabricCapacities = [pscustomobject]@{
                value = @([pscustomobject]@{ id = 'f2'; displayName = 'mls-f2'; sku = 'F2'; state = 'Paused' })
            }
            $results = Invoke-VerifyForTest
            (Get-Row $results 'FabricCapacity').Status | Should -Be 'PASS'
        }

        It 'ignores a Power BI capacity sitting alongside a real Fabric one' {
            $script:FabricCapacities = [pscustomobject]@{
                value = @(
                    [pscustomobject]@{ id = 'ppu'; displayName = 'Premium Per User - Reserved'; sku = 'PP3'; state = 'Active' }
                    [pscustomobject]@{ id = 'cap1'; displayName = 'mlstrial'; sku = 'FT1'; state = 'Active' }
                )
            }
            $results = Invoke-VerifyForTest
            $row = Get-Row $results 'FabricCapacity'
            $row.Status | Should -Be 'PASS'
            $row.Detail | Should -BeLike '*FT1*'
            $row.Detail | Should -Not -BeLike '*PP3*'
        }

        It 'FAILS C4 when service principals cannot create workspaces (F46)' {
            # The live-tenant defect: ServicePrincipalAccessPermissionAPIs was on and
            # ServicePrincipalAccessGlobalAPIs was off. L5 calls New-FabricWorkspace,
            # which the OFF one governs -- the estate would have failed at L5 on a
            # tenant the old runbook called ready.
            $script:FabricTenantSettings = [pscustomobject]@{
                tenantSettings = @(
                    [pscustomobject]@{ settingName = 'ServicePrincipalAccessGlobalAPIs'; enabled = $false }
                    [pscustomobject]@{ settingName = 'ServicePrincipalAccessPermissionAPIs'; enabled = $true }
                )
            }
            $row = Get-Row (Invoke-VerifyForTest) 'FabricSpAccess'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*ServicePrincipalAccessGlobalAPIs*'
        }

        It 'fails when a required setting is scoped to a security group the deployer is not in (F50)' {
            # The false PASS this closes: the Fabric API reports enabled=true for a
            # group-scoped setting regardless of who is in the group. Reading the flag
            # alone would green-light G0 and leave L5 failing at New-FabricWorkspace.
            $script:FabricTenantSettings = [pscustomobject]@{
                tenantSettings = @(
                    [pscustomobject]@{ settingName = 'ServicePrincipalAccessGlobalAPIs'; enabled = $true
                        enabledSecurityGroups = @([pscustomobject]@{ graphId = 'grp-1'; name = 'fabric-sps' }) }
                    [pscustomobject]@{ settingName = 'ServicePrincipalAccessPermissionAPIs'; enabled = $true }
                )
            }
            $script:GroupMembership['grp-1'] = $false
            $row = Get-Row (Invoke-VerifyForTest) 'FabricSpAccess'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*fabric-sps*'
        }

        It 'passes when the deployer is a member of the scoped security group' {
            $script:FabricTenantSettings = [pscustomobject]@{
                tenantSettings = @(
                    [pscustomobject]@{ settingName = 'ServicePrincipalAccessGlobalAPIs'; enabled = $true
                        enabledSecurityGroups = @([pscustomobject]@{ graphId = 'grp-1'; name = 'fabric-sps' }) }
                    [pscustomobject]@{ settingName = 'ServicePrincipalAccessPermissionAPIs'; enabled = $true }
                )
            }
            $script:GroupMembership['grp-1'] = $true
            $row = Get-Row (Invoke-VerifyForTest) 'FabricSpAccess'
            $row.Status | Should -Be 'PASS'
        }

        It 'passes C4 but names admin access nobody asked for' {
            $script:FabricTenantSettings = [pscustomobject]@{
                tenantSettings = @(
                    [pscustomobject]@{ settingName = 'ServicePrincipalAccessGlobalAPIs'; enabled = $true }
                    [pscustomobject]@{ settingName = 'ServicePrincipalAccessPermissionAPIs'; enabled = $true }
                    [pscustomobject]@{ settingName = 'AllowServicePrincipalsUseWriteAdminAPIs'; enabled = $true }
                )
            }
            $row = Get-Row (Invoke-VerifyForTest) 'FabricSpAccess'
            $row.Status | Should -Be 'PASS'
            $row.Detail | Should -BeLike '*admin access*'
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
        It 'survives az being completely broken (the informational check errors to INFO, not FAIL)' {
            Mock Invoke-AzCli { throw 'az exploded' }
            $results = Invoke-VerifyForTest
            @($results).Count | Should -Be 11
            # Ten gate-affecting checks fail; EntraDiagnostics degrades to INFO and is
            # excluded from the count by design (F9). Was 9 before FabricSpAccess (C4)
            # became a real check rather than a portal step nobody verified (F46).
            @($results | Where-Object { $_.Status -eq 'FAIL' }).Count | Should -Be 10
            (Get-Row $results 'EntraDiagnostics').Status | Should -Be 'INFO'
            Get-FailCount -Results $results | Should -Be 10
        }
    }

    Context 'EntraDiagnostics - informational, never gate-failing (2026-08-26 finding F9, G0 item 12)' {
        It 'reports INFO (not FAIL) when both SignInLogs and AuditLogs route to the LAW' {
            $results = Invoke-VerifyForTest
            $row = Get-Row $results 'EntraDiagnostics'
            $row.Status | Should -Be 'INFO'
            $row.Detail | Should -BeLike '*SignInLogs*AuditLogs*'
        }

        It 'stays INFO (not FAIL), and says so, when no diagnostic setting routes both categories' {
            $script:EntraDiagnosticSettings = [pscustomobject]@{ value = @() }
            $results = Invoke-VerifyForTest
            $row = Get-Row $results 'EntraDiagnostics'
            $row.Status | Should -Be 'INFO'
            $row.Detail | Should -BeLike '*no tenant diagnostic setting*'
            Get-FailCount -Results $results | Should -Be 0
        }

        It 'stays INFO when only one of the two categories is enabled' {
            $script:EntraDiagnosticSettings = [pscustomobject]@{
                value = @(
                    [pscustomobject]@{
                        name = 'mls-entra-law'
                        logs = @([pscustomobject]@{ category = 'SignInLogs'; enabled = $true })
                    }
                )
            }
            $results = Invoke-VerifyForTest
            $row = Get-Row $results 'EntraDiagnostics'
            $row.Status | Should -Be 'INFO'
            $row.Detail | Should -BeLike '*no tenant diagnostic setting*'
            Get-FailCount -Results $results | Should -Be 0
        }

        It 'never contributes to the gate fail count under any outcome' {
            foreach ($dataset in @(
                    [pscustomobject]@{ value = @() },
                    $null
                )) {
                $script:EntraDiagnosticSettings = $dataset
                $results = Invoke-VerifyForTest
                Get-FailCount -Results $results | Should -Be 0
            }
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

        It 'never counts an INFO row, even one recording a missing setting' {
            $rows = @(
                [pscustomobject]@{ Check = 'a'; Status = 'PASS'; Detail = '' }
                [pscustomobject]@{ Check = 'EntraDiagnostics'; Status = 'INFO'; Detail = 'missing' }
                [pscustomobject]@{ Check = 'b'; Status = 'FAIL'; Detail = '' }
            )
            Get-FailCount -Results $rows | Should -Be 1
        }

        It 'returns 0 for an empty set' {
            Get-FailCount -Results @() | Should -Be 0
        }
    }
}
