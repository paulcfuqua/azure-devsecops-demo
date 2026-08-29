# Pester tests for infra/fabric/create-data-agent.ps1 - module functions mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'fabric-api.psm1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'create-data-agent.ps1') -Token 'tok-dummy'
    # No Set-StrictMode -Off: the script under test sets -Version Latest and CI runs it
    # that way, so the harness must not relax the language mode it is testing (F49).

    function Invoke-CreateForTest {
        # -AsWhatIf, not -WhatIf: a parameter literally named WhatIf on a function that
        # never calls ShouldProcess trips PSUseSupportsShouldProcess, and lint-ci fails
        # on any warning.
        param(
            [switch]$AsWhatIf, [switch]$SkipPublish, [string[]]$TableName = @(),
            [string]$CapacityId = '/subscriptions/s1/resourceGroups/rg/providers/Microsoft.Fabric/capacities/cap',
            [switch]$SkipCapacityCheck
        )
        Invoke-Main -Token 'tok-1' -WorkspaceName 'mls-operations' -LakehouseName 'mls_operations' `
            -DataAgentName 'mls-operations-data-agent' -TableName $TableName `
            -CapacityId $CapacityId -SkipCapacityCheck:$SkipCapacityCheck `
            -SkipPublish:$SkipPublish -WhatIf:$AsWhatIf
    }

    function Get-PartPayload {
        # Decode one InlineBase64 definition part back to an object.
        param($Definition, [string]$Path)
        $part = @($Definition.parts | Where-Object { $_.path -eq $Path })[0]
        if (-not $part) { return $null }
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part.payload)) | ConvertFrom-Json
    }
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    Remove-Module 'fabric-api' -Force -ErrorAction SilentlyContinue
}

Describe 'New-FabricDataAgentDefinition' {
    BeforeAll {
        $script:Definition = New-FabricDataAgentDefinition -WorkspaceId 'w1' -LakehouseId 'l1' `
            -LakehouseName 'mls_operations' -TableName @('launches', 'scrubs') `
            -AiInstructions 'be exact' -DataSourceInstructions 'read only' `
            -UserDescription 'MLS ops'
    }

    It 'emits exactly the three required definition parts, all InlineBase64' {
        @($script:Definition.parts).Count | Should -Be 3
        @($script:Definition.parts).path | Should -Contain 'Files/Config/data_agent.json'
        @($script:Definition.parts).path | Should -Contain 'Files/Config/draft/stage_config.json'
        @($script:Definition.parts).path | Should -Contain 'Files/Config/draft/lakehouse-mls_operations/datasource.json'
        @($script:Definition.parts).payloadType | Should -Not -Contain 'InlineText'
        @($script:Definition.parts | Where-Object { $_.payloadType -eq 'InlineBase64' }).Count | Should -Be 3
    }

    It 'pins the documented schema versions' {
        (Get-PartPayload -Definition $script:Definition -Path 'Files/Config/data_agent.json').'$schema' | Should -Be '2.1.0'
        (Get-PartPayload -Definition $script:Definition -Path 'Files/Config/draft/stage_config.json').'$schema' | Should -Be '1.0.0'
    }

    It 'carries the AI instructions into stage_config.json' {
        (Get-PartPayload -Definition $script:Definition -Path 'Files/Config/draft/stage_config.json').aiInstructions |
            Should -Be 'be exact'
    }

    It 'binds the lakehouse by artifactId + workspaceId with type lakehouse_tables' {
        $ds = Get-PartPayload -Definition $script:Definition -Path 'Files/Config/draft/lakehouse-mls_operations/datasource.json'
        $ds.artifactId | Should -Be 'l1'
        $ds.workspaceId | Should -Be 'w1'
        $ds.type | Should -Be 'lakehouse_tables'
        $ds.dataSourceInstructions | Should -Be 'read only'
    }

    It 'nests the selected tables under a lakehouse_tables.schema element by default' {
        $ds = Get-PartPayload -Definition $script:Definition -Path 'Files/Config/draft/lakehouse-mls_operations/datasource.json'
        @($ds.elements).Count | Should -Be 1
        $ds.elements[0].type | Should -Be 'lakehouse_tables.schema'
        $ds.elements[0].display_name | Should -Be 'dbo'
        @($ds.elements[0].children).Count | Should -Be 2
        @($ds.elements[0].children).display_name | Should -Contain 'launches'
        @($ds.elements[0].children | Where-Object { $_.type -ne 'lakehouse_tables.table' }).Count | Should -Be 0
        @($ds.elements[0].children | Where-Object { -not $_.is_selected }).Count | Should -Be 0
    }

    It 'emits a flat table list when SchemaName is empty (documented escape hatch)' {
        $flat = New-FabricDataAgentDefinition -WorkspaceId 'w1' -LakehouseId 'l1' `
            -LakehouseName 'mls_operations' -TableName @('launches', 'scrubs') -SchemaName ''
        $ds = Get-PartPayload -Definition $flat -Path 'Files/Config/draft/lakehouse-mls_operations/datasource.json'
        @($ds.elements).Count | Should -Be 2
        @($ds.elements | Where-Object { $_.type -ne 'lakehouse_tables.table' }).Count | Should -Be 0
    }

    It 'is a pure function - builds a definition with no REST call at all' {
        Mock Invoke-FabricApi { throw 'must not be called' } -ModuleName 'fabric-api'
        New-FabricDataAgentDefinition -WorkspaceId 'w1' -LakehouseId 'l1' -LakehouseName 'lh' | Out-Null
        Should -Invoke Invoke-FabricApi -ModuleName 'fabric-api' -Exactly -Times 0
    }
}

Describe 'New-FabricDataAgent' {
    It 'POSTs to the dedicated /dataAgents route and returns the created item on 201' {
        Mock Invoke-FabricApi {
            [pscustomobject]@{
                Content    = [pscustomobject]@{ id = 'da-new'; displayName = 'agent'; type = 'DataAgent' }
                Headers    = @{}
                StatusCode = 201
            }
        } -ModuleName 'fabric-api'
        $created = New-FabricDataAgent -Token 't' -WorkspaceId 'w1' -Name 'agent' -Confirm:$false
        $created.id | Should -Be 'da-new'
        Should -Invoke Invoke-FabricApi -ModuleName 'fabric-api' -Exactly -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $Path -eq 'workspaces/w1/dataAgents' -and $Body.displayName -eq 'agent'
        }
    }

    It 'awaits the long-running operation when Fabric answers 202 with no item id' {
        Mock Start-Sleep {} -ModuleName 'fabric-api'
        Mock Invoke-FabricApi {
            if ($Method -eq 'POST') {
                return [pscustomobject]@{
                    Content    = $null
                    Headers    = @{ 'x-ms-operation-id' = @('op-42'); 'Retry-After' = @('1') }
                    StatusCode = 202
                }
            }
            if ($Path -eq 'operations/op-42') { return [pscustomobject]@{ status = 'Succeeded' } }
            if ($Path -eq 'operations/op-42/result') { return [pscustomobject]@{ id = 'da-lro' } }
            throw "unexpected path $Path"
        } -ModuleName 'fabric-api'

        $created = New-FabricDataAgent -Token 't' -WorkspaceId 'w1' -Name 'agent' -Confirm:$false
        $created.id | Should -Be 'da-lro'
        Should -Invoke Invoke-FabricApi -ModuleName 'fabric-api' -Exactly -Times 1 -ParameterFilter {
            $Path -eq 'operations/op-42/result'
        }
    }

    It 'throws a clear error when a 202 carries no operation id' {
        Mock Invoke-FabricApi {
            [pscustomobject]@{ Content = $null; Headers = @{}; StatusCode = 202 }
        } -ModuleName 'fabric-api'
        { New-FabricDataAgent -Token 't' -WorkspaceId 'w1' -Name 'agent' -Confirm:$false } |
            Should -Throw '*neither an item id nor an x-ms-operation-id*'
    }

    It 'under -WhatIf issues no REST call and returns $null' {
        Mock Invoke-FabricApi { throw 'must not be called' } -ModuleName 'fabric-api'
        New-FabricDataAgent -Token 't' -WorkspaceId 'w1' -Name 'agent' -WhatIf | Should -BeNullOrEmpty
        Should -Invoke Invoke-FabricApi -ModuleName 'fabric-api' -Exactly -Times 0
    }
}

Describe 'Wait-FabricOperation' {
    It 'surfaces the Fabric error payload when the operation fails' {
        Mock Start-Sleep {} -ModuleName 'fabric-api'
        Mock Invoke-FabricApi {
            [pscustomobject]@{ status = 'Failed'; error = [pscustomobject]@{ errorCode = 'CapacityNotSupported' } }
        } -ModuleName 'fabric-api'
        { Wait-FabricOperation -Token 't' -OperationId 'op-9' } | Should -Throw '*CapacityNotSupported*'
    }

    It 'times out rather than polling forever' {
        Mock Start-Sleep {} -ModuleName 'fabric-api'
        Mock Invoke-FabricApi { [pscustomobject]@{ status = 'Running' } } -ModuleName 'fabric-api'
        { Wait-FabricOperation -Token 't' -OperationId 'op-9' -TimeoutSeconds -1 } |
            Should -Throw '*did not complete within*'
    }
}

Describe 'Publish-FabricDataAgent' {
    It 'POSTs to the staging/publish route (preview API)' {
        Mock Invoke-FabricApi { [pscustomobject]@{ publishedDescription = 'desc' } } -ModuleName 'fabric-api'
        Publish-FabricDataAgent -Token 't' -WorkspaceId 'w1' -DataAgentId 'da1' -Description 'desc' -Confirm:$false | Out-Null
        Should -Invoke Invoke-FabricApi -ModuleName 'fabric-api' -Exactly -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $Path -eq 'workspaces/w1/dataAgents/da1/staging/publish'
        }
    }

    It 'under -WhatIf issues no REST call' {
        Mock Invoke-FabricApi { throw 'must not be called' } -ModuleName 'fabric-api'
        Publish-FabricDataAgent -Token 't' -WorkspaceId 'w1' -DataAgentId 'da1' -WhatIf | Should -BeNullOrEmpty
        Should -Invoke Invoke-FabricApi -ModuleName 'fabric-api' -Exactly -Times 0
    }
}

Describe 'Get-FabricDataAgent' {
    It 'matches by display name and returns $null when absent' {
        Mock Invoke-FabricApi {
            @{ value = @(@{ id = 'da1'; displayName = 'mls-operations-data-agent' }, @{ id = 'da2'; displayName = 'other' }) }
        } -ModuleName 'fabric-api'
        (Get-FabricDataAgent -Token 't' -WorkspaceId 'w1' -Name 'mls-operations-data-agent').id | Should -Be 'da1'
        Get-FabricDataAgent -Token 't' -WorkspaceId 'w1' -Name 'nope' | Should -BeNullOrEmpty
        Should -Invoke Invoke-FabricApi -ModuleName 'fabric-api' -ParameterFilter { $Path -eq 'workspaces/w1/dataAgents' }
    }
}

Describe 'Test-TrialCapacitySku' {
    It 'recognises trial SKUs' {
        Test-TrialCapacitySku -Sku 'Trial' | Should -BeTrue
        Test-TrialCapacitySku -Sku 'trial' | Should -BeTrue
        Test-TrialCapacitySku -Sku 'FT1' | Should -BeTrue
    }

    It 'treats paid Fabric and Premium SKUs as usable' {
        foreach ($sku in @('F2', 'F4', 'F64', 'P1', 'P3')) {
            Test-TrialCapacitySku -Sku $sku | Should -BeFalse -Because "$sku is a paid SKU"
        }
    }

    It 'does not block on an unknown or empty SKU (warn-and-proceed, never false-block)' {
        Test-TrialCapacitySku -Sku '' | Should -BeFalse
        Test-TrialCapacitySku -Sku 'SomethingNew9' | Should -BeFalse
    }
}

Describe 'Assert-PaidCapacity' {
    BeforeEach { Mock Write-Status {} }

    It 'fails fast from the capacity id shape alone, with no REST call at all' {
        Mock Get-FabricCapacity { throw 'must not be called' }
        { Assert-PaidCapacity -Token 't' -Workspace $null -CapacityId 'trial-capacity-guid' } |
            Should -Throw '*not supported on it*'
        Should -Invoke Get-FabricCapacity -Exactly -Times 0
    }

    It 'names the tools-only default and the G2-gated upgrade in the failure message' {
        { Assert-PaidCapacity -Token 't' -Workspace $null -CapacityId 'trial-capacity-guid' } |
            Should -Throw '*tools-only*'
        { Assert-PaidCapacity -Token 't' -Workspace $null -CapacityId 'trial-capacity-guid' } |
            Should -Throw '*G2-gated*'
    }

    It 'fails on a trial SKU read back from the capacity' {
        Mock Get-FabricCapacity { [pscustomobject]@{ id = 'c1'; sku = 'Trial' } }
        { Assert-PaidCapacity -Token 't' -Workspace ([pscustomobject]@{ id = 'w1'; capacityId = 'c1' }) } |
            Should -Throw '*not supported on it*'
    }

    It 'passes on a paid F2 capacity' {
        Mock Get-FabricCapacity { [pscustomobject]@{ id = 'c1'; sku = 'F2' } }
        { Assert-PaidCapacity -Token 't' -Workspace ([pscustomobject]@{ id = 'w1'; capacityId = 'c1' }) } |
            Should -Not -Throw
    }

    It 'warns and proceeds when the capacity cannot be read, rather than blocking' {
        Mock Get-FabricCapacity { throw 'HTTP 403' }
        { Assert-PaidCapacity -Token 't' -Workspace ([pscustomobject]@{ id = 'w1'; capacityId = 'c1' }) } |
            Should -Not -Throw
    }

    It 'warns and proceeds when the workspace reports no capacity at all' {
        Mock Get-FabricCapacity { throw 'must not be called' }
        { Assert-PaidCapacity -Token 't' -Workspace ([pscustomobject]@{ id = 'w1' }) } | Should -Not -Throw
        Should -Invoke Get-FabricCapacity -Exactly -Times 0
    }

    It '-SkipCapacityCheck bypasses even an obvious trial id' {
        Mock Get-FabricCapacity { throw 'must not be called' }
        { Assert-PaidCapacity -Token 't' -Workspace $null -CapacityId 'trial-guid' -SkipCapacityCheck } |
            Should -Not -Throw
    }
}

Describe 'create-data-agent' {
    BeforeEach {
        Mock Write-Status {}
        Mock Get-FabricWorkspace { [pscustomobject]@{ id = 'w1'; displayName = 'mls-operations'; capacityId = 'c1' } }
        Mock Get-FabricLakehouse { [pscustomobject]@{ id = 'l1'; displayName = 'mls_operations' } }
        Mock Get-FabricTable { @([pscustomobject]@{ name = 'launches' }, [pscustomobject]@{ name = 'scrubs' }) }
        Mock Get-FabricCapacity { [pscustomobject]@{ id = 'c1'; sku = 'F2' } }
    }

    Context 'trial capacity - the default demo posture' {
        BeforeEach {
            Mock Get-FabricDataAgent { $null }
            Mock New-FabricDataAgent { throw 'must not be called' }
            Mock Publish-FabricDataAgent { throw 'must not be called' }
        }

        It 'stops before touching the lakehouse or creating anything' {
            { Invoke-CreateForTest -CapacityId 'trial-capacity-guid' } | Should -Throw '*not supported on it*'
            Should -Invoke New-FabricDataAgent -Exactly -Times 0
            Should -Invoke Get-FabricLakehouse -Exactly -Times 0
        }

        It 'stops under -WhatIf too, instead of printing a plan that could never run' {
            { Invoke-CreateForTest -CapacityId 'trial-capacity-guid' -AsWhatIf } |
                Should -Throw '*not supported on it*'
        }
    }

    Context 'the data agent already exists (idempotent replay)' {
        BeforeEach {
            Mock Get-FabricDataAgent { [pscustomobject]@{ id = 'da1'; displayName = 'mls-operations-data-agent' } }
            Mock New-FabricDataAgent { throw 'must not be called' }
            Mock Publish-FabricDataAgent { [pscustomobject]@{ publishedDescription = 'desc' } }
        }

        It 'creates nothing and reuses the existing agent' {
            $result = Invoke-CreateForTest
            Should -Invoke New-FabricDataAgent -Exactly -Times 0
            $result.DataAgent.id | Should -Be 'da1'
            $result.Published | Should -BeTrue
        }

        It 'still republishes so the draft configuration is the live one' {
            Invoke-CreateForTest | Out-Null
            Should -Invoke Publish-FabricDataAgent -Exactly -Times 1 -ParameterFilter { $DataAgentId -eq 'da1' }
        }

        It 'honours -SkipPublish' {
            $result = Invoke-CreateForTest -SkipPublish
            Should -Invoke Publish-FabricDataAgent -Exactly -Times 0
            $result.Published | Should -BeFalse
        }
    }

    Context 'the data agent does not exist yet' {
        BeforeEach {
            Mock Get-FabricDataAgent { $null }
            Mock New-FabricDataAgent { [pscustomobject]@{ id = 'da-new'; displayName = $Name } }
            Mock Publish-FabricDataAgent { [pscustomobject]@{ publishedDescription = 'desc' } }
        }

        It 'creates it with a definition bound to every lakehouse table' {
            Invoke-CreateForTest | Out-Null
            Should -Invoke New-FabricDataAgent -Exactly -Times 1 -ParameterFilter {
                $WorkspaceId -eq 'w1' -and
                $Name -eq 'mls-operations-data-agent' -and
                $null -ne $Definition -and
                @($Definition.parts).Count -eq 3
            }
        }

        It 'binds only the requested tables when -TableName is supplied' {
            Invoke-CreateForTest -TableName @('launches') | Out-Null
            Should -Invoke New-FabricDataAgent -Exactly -Times 1 -ParameterFilter {
                $payload = @($Definition.parts | Where-Object { $_.path -like '*datasource.json' })[0].payload
                $ds = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
                @($ds.elements[0].children).Count -eq 1 -and $ds.elements[0].children[0].display_name -eq 'launches'
            }
        }

        It 'publishes the newly created agent' {
            $result = Invoke-CreateForTest
            Should -Invoke Publish-FabricDataAgent -Exactly -Times 1 -ParameterFilter { $DataAgentId -eq 'da-new' }
            $result.Published | Should -BeTrue
        }
    }

    Context 'prerequisites missing - fail fast, never half-run' {
        BeforeEach {
            Mock Get-FabricDataAgent { $null }
            Mock New-FabricDataAgent { throw 'must not be called' }
            Mock Publish-FabricDataAgent { throw 'must not be called' }
        }

        It 'refuses to create the workspace L5 owns' {
            Mock Get-FabricWorkspace { $null }
            { Invoke-CreateForTest } | Should -Throw "*L5 provisions it*"
            Should -Invoke New-FabricDataAgent -Exactly -Times 0
        }

        It 'refuses to run without the lakehouse' {
            Mock Get-FabricLakehouse { $null }
            { Invoke-CreateForTest } | Should -Throw '*does not exist in workspace*'
            Should -Invoke New-FabricDataAgent -Exactly -Times 0
        }

        It 'refuses to bind a data agent to an unseeded lakehouse' {
            Mock Get-FabricTable { @() }
            { Invoke-CreateForTest } | Should -Throw '*reports no tables*'
            Should -Invoke New-FabricDataAgent -Exactly -Times 0
        }
    }

    Context '-WhatIf makes no mutating REST calls (real module functions, mocked transport)' {
        BeforeEach {
            Mock Invoke-FabricApi {
                switch -Wildcard ($Path) {
                    'workspaces' { return @{ value = @(@{ id = 'w1'; displayName = 'mls-operations' }) } }
                    'workspaces/w1/lakehouses' { return @{ value = @(@{ id = 'l1'; displayName = 'mls_operations' }) } }
                    'workspaces/w1/lakehouses/l1/tables' { return @{ data = @(@{ name = 'launches' }) } }
                    'workspaces/w1/dataAgents' { return @{ value = @() } }
                    default { return @{ value = @() } }
                }
            } -ModuleName 'fabric-api'
        }

        It 'performs GETs only and stops cleanly after the gated create' {
            $result = Invoke-CreateForTest -AsWhatIf
            Should -Invoke Invoke-FabricApi -ModuleName 'fabric-api' -Exactly -Times 0 -ParameterFilter {
                $Method -in @('POST', 'PATCH', 'DELETE')
            }
            $result.Workspace.id | Should -Be 'w1'
            $result.Lakehouse.id | Should -Be 'l1'
            $result.DataAgent | Should -BeNullOrEmpty
            $result.Published | Should -BeFalse
        }
    }
}
