# Pester tests for infra/fabric/fabric-api.psm1 - Invoke-RestMethod mocked in-module; zero cloud calls.

BeforeAll {
    $script:ModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'fabric-api.psm1'
    Import-Module $script:ModulePath -Force
    $script:ModuleName = 'fabric-api'
}

AfterAll {
    Remove-Module 'fabric-api' -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-FabricApi' {
    BeforeEach {
        Mock Invoke-RestMethod { [pscustomobject]@{ ok = $true } } -ModuleName $script:ModuleName
    }

    It 'targets the v1 API with a bearer token header' {
        Invoke-FabricApi -Token 'tok-123' -Path 'workspaces' | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
            $Uri -eq 'https://api.fabric.microsoft.com/v1/workspaces' -and
            $Headers.Authorization -eq 'Bearer tok-123' -and
            "$Method" -eq 'GET'
        }
    }

    It 'serializes the body as JSON for writes' {
        Invoke-FabricApi -Token 'tok-123' -Method POST -Path 'workspaces' -Body @{ displayName = 'x'; capacityId = 'cap' } | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
            "$Method" -eq 'POST' -and
            $ContentType -eq 'application/json' -and
            $Body -like '*"displayName"*' -and $Body -like '*"capacityId"*'
        }
    }

    It 'sends no body parameter for GETs' {
        Invoke-FabricApi -Token 'tok-123' -Path 'workspaces/w1/lakehouses' | Out-Null
        Should -Invoke Invoke-RestMethod -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
            $Uri -eq 'https://api.fabric.microsoft.com/v1/workspaces/w1/lakehouses' -and -not $Body
        }
    }
}

Describe 'Get-FabricWorkspace' {
    BeforeEach {
        Mock Invoke-FabricApi {
            @{ value = @(
                    @{ id = 'w1'; displayName = 'mls-operations' }
                    @{ id = 'w2'; displayName = 'unrelated' }
                )
            }
        } -ModuleName $script:ModuleName
    }

    It 'returns the workspace matching the display name' {
        $workspace = Get-FabricWorkspace -Token 't' -Name 'mls-operations'
        $workspace.id | Should -Be 'w1'
        Should -Invoke Invoke-FabricApi -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
            $Method -eq 'GET' -and $Path -eq 'workspaces' -and $Token -eq 't'
        }
    }

    It 'returns $null when absent' {
        Get-FabricWorkspace -Token 't' -Name 'missing' | Should -BeNullOrEmpty
    }
}

Describe 'New-FabricWorkspace' {
    It 'POSTs displayName + capacityId (capacity id always from the caller, never hardcoded)' {
        Mock Invoke-FabricApi { @{ id = 'w-new' } } -ModuleName $script:ModuleName
        $created = New-FabricWorkspace -Token 't' -Name 'mls-operations' -CapacityId 'cap-777' -Confirm:$false
        $created.id | Should -Be 'w-new'
        Should -Invoke Invoke-FabricApi -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $Path -eq 'workspaces' -and
            $Body.displayName -eq 'mls-operations' -and $Body.capacityId -eq 'cap-777'
        }
    }

    It 'under -WhatIf issues no REST call and returns $null' {
        Mock Invoke-FabricApi { @{ id = 'w-new' } } -ModuleName $script:ModuleName
        New-FabricWorkspace -Token 't' -Name 'mls-operations' -CapacityId 'cap-777' -WhatIf | Should -BeNullOrEmpty
        Should -Invoke Invoke-FabricApi -ModuleName $script:ModuleName -Exactly -Times 0
    }
}

Describe 'Get-FabricLakehouse / New-FabricLakehouse' {
    It 'finds an existing lakehouse by name within the workspace' {
        Mock Invoke-FabricApi { @{ value = @(@{ id = 'l1'; displayName = 'mls_operations' }) } } -ModuleName $script:ModuleName
        $lakehouse = Get-FabricLakehouse -Token 't' -WorkspaceId 'w1' -Name 'mls_operations'
        $lakehouse.id | Should -Be 'l1'
        Should -Invoke Invoke-FabricApi -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
            $Path -eq 'workspaces/w1/lakehouses'
        }
    }

    It 'creates the lakehouse under the workspace path' {
        Mock Invoke-FabricApi { @{ id = 'l-new' } } -ModuleName $script:ModuleName
        New-FabricLakehouse -Token 't' -WorkspaceId 'w1' -Name 'mls_operations' -Confirm:$false | Out-Null
        Should -Invoke Invoke-FabricApi -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $Path -eq 'workspaces/w1/lakehouses' -and $Body.displayName -eq 'mls_operations'
        }
    }

    It 'under -WhatIf issues no REST call' {
        Mock Invoke-FabricApi { @{ id = 'l-new' } } -ModuleName $script:ModuleName
        New-FabricLakehouse -Token 't' -WorkspaceId 'w1' -Name 'mls_operations' -WhatIf | Should -BeNullOrEmpty
        Should -Invoke Invoke-FabricApi -ModuleName $script:ModuleName -Exactly -Times 0
    }
}

Describe 'Get-FabricTable' {
    It 'returns the table list from a data-keyed response' {
        Mock Invoke-FabricApi { @{ data = @(@{ name = 'launches' }, @{ name = 'scrubs' }) } } -ModuleName $script:ModuleName
        $tables = Get-FabricTable -Token 't' -WorkspaceId 'w1' -LakehouseId 'l1'
        @($tables).Count | Should -Be 2
        @($tables).name | Should -Contain 'launches'
        Should -Invoke Invoke-FabricApi -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
            $Path -eq 'workspaces/w1/lakehouses/l1/tables'
        }
    }

    It 'returns the table list from a value-keyed response too' {
        Mock Invoke-FabricApi { @{ value = @(@{ name = 'vehicles' }) } } -ModuleName $script:ModuleName
        $tables = Get-FabricTable -Token 't' -WorkspaceId 'w1' -LakehouseId 'l1'
        @($tables).name | Should -Be @('vehicles')
    }

    It 'returns an empty array for an empty lakehouse' {
        Mock Invoke-FabricApi { @{ data = @() } } -ModuleName $script:ModuleName
        $tables = Get-FabricTable -Token 't' -WorkspaceId 'w1' -LakehouseId 'l1'
        @($tables).Count | Should -Be 0
    }
}
