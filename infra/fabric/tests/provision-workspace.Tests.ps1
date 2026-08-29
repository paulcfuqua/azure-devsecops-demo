# Pester tests for infra/fabric/provision-workspace.ps1 - module functions mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'fabric-api.psm1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'provision-workspace.ps1') -Token 'tok-dummy' -CapacityId 'cap-dummy'
    Set-StrictMode -Off

    function Invoke-ProvisionForTest {
        # -AsWhatIf, not -WhatIf: a parameter literally named WhatIf on a function that
        # never calls ShouldProcess trips PSUseSupportsShouldProcess, and lint-ci fails
        # on any warning.
        param([switch]$AsWhatIf)
        Invoke-Main -Token 'tok-1' -CapacityId 'cap-1' -WorkspaceName 'mls-operations' `
            -LakehouseName 'mls_operations' -WhatIf:$AsWhatIf
    }
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    Remove-Module 'fabric-api' -Force -ErrorAction SilentlyContinue
}

Describe 'provision-workspace' {
    BeforeEach {
        Mock Write-Status {}
    }

    Context 'workspace and lakehouse already exist (idempotent replay)' {
        BeforeEach {
            Mock Get-FabricWorkspace { [pscustomobject]@{ id = 'w1'; displayName = 'mls-operations' } }
            Mock Get-FabricLakehouse { [pscustomobject]@{ id = 'l1'; displayName = 'mls_operations' } }
            Mock Get-FabricTable { @([pscustomobject]@{ name = 'launches' }) }
            Mock New-FabricWorkspace { throw 'must not be called' }
            Mock New-FabricLakehouse { throw 'must not be called' }
        }

        It 'creates nothing and returns the existing objects plus tables' {
            $result = Invoke-ProvisionForTest
            Should -Invoke New-FabricWorkspace -Exactly -Times 0
            Should -Invoke New-FabricLakehouse -Exactly -Times 0
            $result.Workspace.id | Should -Be 'w1'
            $result.Lakehouse.id | Should -Be 'l1'
            @($result.Tables).Count | Should -Be 1
        }
    }

    Context 'nothing exists yet' {
        BeforeEach {
            Mock Get-FabricWorkspace { $null }
            Mock Get-FabricLakehouse { $null }
            Mock Get-FabricTable { @() }
            Mock New-FabricWorkspace { [pscustomobject]@{ id = 'w-new'; displayName = $Name } }
            Mock New-FabricLakehouse { [pscustomobject]@{ id = 'l-new'; displayName = $Name } }
        }

        It 'creates the workspace on the configured capacity (id from parameter, never hardcoded)' {
            Invoke-ProvisionForTest | Out-Null
            Should -Invoke New-FabricWorkspace -Exactly -Times 1 -ParameterFilter {
                $Name -eq 'mls-operations' -and $CapacityId -eq 'cap-1' -and $Token -eq 'tok-1'
            }
        }

        It 'creates the lakehouse inside the new workspace' {
            Invoke-ProvisionForTest | Out-Null
            Should -Invoke New-FabricLakehouse -Exactly -Times 1 -ParameterFilter {
                $WorkspaceId -eq 'w-new' -and $Name -eq 'mls_operations'
            }
        }

        It 'reports an empty table list without failing (seed happens later)' {
            $result = Invoke-ProvisionForTest
            @($result.Tables).Count | Should -Be 0
        }
    }

    Context 'workspace exists but lakehouse does not' {
        It 'only creates the lakehouse' {
            Mock Get-FabricWorkspace { [pscustomobject]@{ id = 'w1'; displayName = 'mls-operations' } }
            Mock Get-FabricLakehouse { $null }
            Mock Get-FabricTable { @() }
            Mock New-FabricWorkspace { throw 'must not be called' }
            Mock New-FabricLakehouse { [pscustomobject]@{ id = 'l-new' } }
            Invoke-ProvisionForTest | Out-Null
            Should -Invoke New-FabricWorkspace -Exactly -Times 0
            Should -Invoke New-FabricLakehouse -Exactly -Times 1 -ParameterFilter { $WorkspaceId -eq 'w1' }
        }
    }

    Context 'mls-verifier workspace Viewer grant (F21)' {
        BeforeEach {
            Mock Get-FabricWorkspace { [pscustomobject]@{ id = 'w1'; displayName = 'mls-operations' } }
            Mock Get-FabricLakehouse { [pscustomobject]@{ id = 'l1'; displayName = 'mls_operations' } }
            Mock Get-FabricTable { @() }
        }

        It 'grants mls-verifier workspace Viewer when VerifierPrincipalId is supplied and holds no assignment yet' {
            Mock Get-FabricWorkspaceRoleAssignment { $null }
            Mock Add-FabricWorkspaceRoleAssignment { [pscustomobject]@{} }
            Invoke-Main -Token 'tok-1' -CapacityId 'cap-1' -WorkspaceName 'mls-operations' `
                -LakehouseName 'mls_operations' -VerifierPrincipalId 'verifier-obj-1' | Out-Null
            Should -Invoke Add-FabricWorkspaceRoleAssignment -Exactly -Times 1 -ParameterFilter {
                $WorkspaceId -eq 'w1' -and $PrincipalId -eq 'verifier-obj-1' -and
                $PrincipalType -eq 'ServicePrincipal' -and $Role -eq 'Viewer'
            }
        }

        It 'does not grant a role broader than Viewer' {
            Mock Get-FabricWorkspaceRoleAssignment { $null }
            Mock Add-FabricWorkspaceRoleAssignment { [pscustomobject]@{} }
            Invoke-Main -Token 'tok-1' -CapacityId 'cap-1' -WorkspaceName 'mls-operations' `
                -LakehouseName 'mls_operations' -VerifierPrincipalId 'verifier-obj-1' | Out-Null
            Should -Invoke Add-FabricWorkspaceRoleAssignment -Exactly -Times 0 -ParameterFilter {
                $Role -ne 'Viewer'
            }
        }

        It 'does not re-grant when mls-verifier already holds Viewer (idempotent replay)' {
            Mock Get-FabricWorkspaceRoleAssignment {
                [pscustomobject]@{ principal = [pscustomobject]@{ id = 'verifier-obj-1' }; role = 'Viewer' }
            }
            Mock Add-FabricWorkspaceRoleAssignment { throw 'must not be called' }
            Invoke-Main -Token 'tok-1' -CapacityId 'cap-1' -WorkspaceName 'mls-operations' `
                -LakehouseName 'mls_operations' -VerifierPrincipalId 'verifier-obj-1' | Out-Null
            Should -Invoke Add-FabricWorkspaceRoleAssignment -Exactly -Times 0
        }

        It 'is a no-op against the role-assignment API when VerifierPrincipalId is not supplied (current default)' {
            Mock Get-FabricWorkspaceRoleAssignment { throw 'must not be called' }
            Mock Add-FabricWorkspaceRoleAssignment { throw 'must not be called' }
            Invoke-ProvisionForTest | Out-Null
            Should -Invoke Get-FabricWorkspaceRoleAssignment -Exactly -Times 0
            Should -Invoke Add-FabricWorkspaceRoleAssignment -Exactly -Times 0
        }

        It 'grants data-api and mls-verifier independently when both principals are supplied' {
            Mock Get-FabricWorkspaceRoleAssignment { $null }
            Mock Add-FabricWorkspaceRoleAssignment { [pscustomobject]@{} }
            Invoke-Main -Token 'tok-1' -CapacityId 'cap-1' -WorkspaceName 'mls-operations' `
                -LakehouseName 'mls_operations' -DataApiPrincipalId 'data-api-obj-1' `
                -VerifierPrincipalId 'verifier-obj-1' | Out-Null
            Should -Invoke Add-FabricWorkspaceRoleAssignment -Exactly -Times 1 -ParameterFilter {
                $PrincipalId -eq 'data-api-obj-1' -and $Role -eq 'Viewer'
            }
            Should -Invoke Add-FabricWorkspaceRoleAssignment -Exactly -Times 1 -ParameterFilter {
                $PrincipalId -eq 'verifier-obj-1' -and $Role -eq 'Viewer'
            }
            Should -Invoke Add-FabricWorkspaceRoleAssignment -Exactly -Times 2
        }
    }

    Context 'cost-ingest workspace Contributor grant (F19)' {
        # The ONLY grant this script makes that is not Viewer, and the only one that
        # can write to OneLake. Every assertion below is on the ROLE STRING actually
        # passed to Add-FabricWorkspaceRoleAssignment, never on the comment that
        # explains it (F27): the argument for Contributor lives in
        # provision-workspace.ps1's grant table, but a test that matched that prose
        # would stay green if the call were changed to Admin.
        BeforeEach {
            Mock Get-FabricWorkspace { [pscustomobject]@{ id = 'w1'; displayName = 'mls-operations' } }
            Mock Get-FabricLakehouse { [pscustomobject]@{ id = 'l1'; displayName = 'mls_operations' } }
            Mock Get-FabricTable { @() }
        }

        It 'grants cost-ingest Contributor - the least Fabric role that can write to Files/' {
            Mock Get-FabricWorkspaceRoleAssignment { $null }
            Mock Add-FabricWorkspaceRoleAssignment { [pscustomobject]@{} }
            Invoke-Main -Token 'tok-1' -CapacityId 'cap-1' -WorkspaceName 'mls-operations' `
                -LakehouseName 'mls_operations' -CostIngestPrincipalId 'cost-ingest-obj-1' | Out-Null
            Should -Invoke Add-FabricWorkspaceRoleAssignment -Exactly -Times 1 -ParameterFilter {
                $WorkspaceId -eq 'w1' -and $PrincipalId -eq 'cost-ingest-obj-1' -and
                $PrincipalType -eq 'ServicePrincipal' -and $Role -eq 'Contributor'
            }
        }

        It 'never grants cost-ingest a role broader than Contributor' {
            # Admin and Member are the two roles above Contributor. Neither is needed
            # to write workspace data, and both can re-grant access to other
            # principals - which is what makes widening this grant a finding rather
            # than a tuning change.
            Mock Get-FabricWorkspaceRoleAssignment { $null }
            Mock Add-FabricWorkspaceRoleAssignment { [pscustomobject]@{} }
            Invoke-Main -Token 'tok-1' -CapacityId 'cap-1' -WorkspaceName 'mls-operations' `
                -LakehouseName 'mls_operations' -CostIngestPrincipalId 'cost-ingest-obj-1' | Out-Null
            Should -Invoke Add-FabricWorkspaceRoleAssignment -Exactly -Times 0 -ParameterFilter {
                $Role -in @('Admin', 'Member')
            }
        }

        It 'does not re-grant when cost-ingest already holds Contributor (idempotent replay)' {
            Mock Get-FabricWorkspaceRoleAssignment {
                [pscustomobject]@{ principal = [pscustomobject]@{ id = 'cost-ingest-obj-1' }; role = 'Contributor' }
            }
            Mock Add-FabricWorkspaceRoleAssignment { throw 'must not be called' }
            Invoke-Main -Token 'tok-1' -CapacityId 'cap-1' -WorkspaceName 'mls-operations' `
                -LakehouseName 'mls_operations' -CostIngestPrincipalId 'cost-ingest-obj-1' | Out-Null
            Should -Invoke Add-FabricWorkspaceRoleAssignment -Exactly -Times 0
        }

        It 'RE-grants when cost-ingest holds only Viewer, rather than treating it as satisfied' {
            # The idempotency check compares against the role this entry asks for, not
            # against 'Viewer'. A principal left on Viewer by an earlier revision of
            # this script would otherwise be skipped forever and 403 on every write.
            Mock Get-FabricWorkspaceRoleAssignment {
                [pscustomobject]@{ principal = [pscustomobject]@{ id = 'cost-ingest-obj-1' }; role = 'Viewer' }
            }
            Mock Add-FabricWorkspaceRoleAssignment { [pscustomobject]@{} }
            Invoke-Main -Token 'tok-1' -CapacityId 'cap-1' -WorkspaceName 'mls-operations' `
                -LakehouseName 'mls_operations' -CostIngestPrincipalId 'cost-ingest-obj-1' | Out-Null
            Should -Invoke Add-FabricWorkspaceRoleAssignment -Exactly -Times 1 -ParameterFilter {
                $Role -eq 'Contributor'
            }
        }

        It 'is a no-op when CostIngestPrincipalId is not supplied' {
            Mock Get-FabricWorkspaceRoleAssignment { throw 'must not be called' }
            Mock Add-FabricWorkspaceRoleAssignment { throw 'must not be called' }
            Invoke-ProvisionForTest | Out-Null
            Should -Invoke Add-FabricWorkspaceRoleAssignment -Exactly -Times 0
        }

        It 'gives the READ principals Viewer in the same run it gives cost-ingest Contributor' {
            # The per-entry role table must not leak the write role sideways: this is
            # the assertion that would go red if Role became a single constant again.
            Mock Get-FabricWorkspaceRoleAssignment { $null }
            Mock Add-FabricWorkspaceRoleAssignment { [pscustomobject]@{} }
            Invoke-Main -Token 'tok-1' -CapacityId 'cap-1' -WorkspaceName 'mls-operations' `
                -LakehouseName 'mls_operations' -DataApiPrincipalId 'data-api-obj-1' `
                -VerifierPrincipalId 'verifier-obj-1' -CostIngestPrincipalId 'cost-ingest-obj-1' | Out-Null
            Should -Invoke Add-FabricWorkspaceRoleAssignment -Exactly -Times 1 -ParameterFilter {
                $PrincipalId -eq 'data-api-obj-1' -and $Role -eq 'Viewer'
            }
            Should -Invoke Add-FabricWorkspaceRoleAssignment -Exactly -Times 1 -ParameterFilter {
                $PrincipalId -eq 'verifier-obj-1' -and $Role -eq 'Viewer'
            }
            Should -Invoke Add-FabricWorkspaceRoleAssignment -Exactly -Times 1 -ParameterFilter {
                $PrincipalId -eq 'cost-ingest-obj-1' -and $Role -eq 'Contributor'
            }
            Should -Invoke Add-FabricWorkspaceRoleAssignment -Exactly -Times 3
        }
    }

    Context '-WhatIf makes no mutating REST calls (real module functions, mocked transport)' {
        BeforeEach {
            Mock Invoke-FabricApi { @{ value = @() } } -ModuleName 'fabric-api'
        }

        It 'performs GETs only and stops cleanly after the gated workspace create' {
            $result = Invoke-ProvisionForTest -AsWhatIf
            Should -Invoke Invoke-FabricApi -ModuleName 'fabric-api' -Exactly -Times 0 -ParameterFilter {
                $Method -in @('POST', 'PATCH', 'DELETE')
            }
            $result.Workspace | Should -BeNullOrEmpty
            $result.Lakehouse | Should -BeNullOrEmpty
        }

        It 'with an existing workspace still issues no writes under -WhatIf' {
            Mock Invoke-FabricApi {
                if ($Path -eq 'workspaces') {
                    return @{ value = @(@{ id = 'w1'; displayName = 'mls-operations' }) }
                }
                return @{ value = @() }
            } -ModuleName 'fabric-api'
            $result = Invoke-ProvisionForTest -AsWhatIf
            Should -Invoke Invoke-FabricApi -ModuleName 'fabric-api' -Exactly -Times 0 -ParameterFilter {
                $Method -in @('POST', 'PATCH', 'DELETE')
            }
            $result.Workspace.id | Should -Be 'w1'
            $result.Lakehouse | Should -BeNullOrEmpty
        }
    }
}
