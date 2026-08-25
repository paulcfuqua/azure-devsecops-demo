# Pester tests for infra/fabric/provision-workspace.ps1 - module functions mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    Import-Module (Join-Path $PSScriptRoot '..' 'fabric-api.psm1') -Force
    . (Join-Path $PSScriptRoot '..' 'provision-workspace.ps1') -Token 'tok-dummy' -CapacityId 'cap-dummy'
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
