# Pester tests for infra/fabric/teardown-items.ps1 - Fabric REST mocked; zero cloud calls.
#
# The interesting assertions here are NEGATIVE. kill-rebuild.md section 1 puts the
# workspace shell and its role assignments in the "persists every cycle, G3 to touch"
# column, so the tests that matter most are the ones proving this script cannot reach
# them - not the ones proving it deletes a lakehouse.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'fabric-api.psm1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'teardown-items.ps1') -Token 'tok-dummy'
    # No Set-StrictMode -Off: the script under test sets -Version Latest and CI runs it
    # that way, so the harness must not relax the language mode it is testing (F49).

    $script:Workspace = [pscustomobject]@{ id = 'w1'; displayName = 'mls-operations' }

    function New-Item2 {
        <# One workspace item as the Fabric listing returns it. #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture builder: returns an in-memory object and changes no state anywhere.')]
        param(
            [Parameter(Mandatory)][string]$Id,
            [Parameter(Mandatory)][string]$Type,
            [string]$DisplayName = ''
        )
        return [pscustomobject]@{
            id          = $Id
            type        = $Type
            displayName = if ($DisplayName) { $DisplayName } else { $Id }
        }
    }

    $script:FullWorkspace = @(
        (New-Item2 -Id 'lh-1' -Type 'Lakehouse' -DisplayName 'mls_operations'),
        (New-Item2 -Id 'ep-1' -Type 'SQLEndpoint' -DisplayName 'mls_operations'),
        (New-Item2 -Id 'da-1' -Type 'DataAgent' -DisplayName 'mls-operations-data-agent')
    )

    # -AsWhatIf, not -WhatIf: a parameter literally named WhatIf on a function that never
    # calls ShouldProcess trips PSUseSupportsShouldProcess, and lint-ci fails on warnings.
    function Invoke-TeardownForTest {
        param([switch]$AsWhatIf, [switch]$AsHardDelete)
        Invoke-Main -Token 'tok-1' -WorkspaceName 'mls-operations' `
            -SkipItemType @('SQLEndpoint') -DeleteLastItemType @('Lakehouse') `
            -TypedDeletePath @{ Lakehouse = 'lakehouses' } `
            -HardDelete:$AsHardDelete -WhatIf:$AsWhatIf
    }
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    Remove-Module 'fabric-api' -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ItemDeletionOrder' {
    It 'defers lakehouses to the final pass so referencing items go first' {
        # "You can't delete a lakehouse that's referenced by other items" - and at L8 the
        # data agent is exactly such a reference.
        $plan = Get-ItemDeletionOrder -Item $script:FullWorkspace `
            -SkipItemType @('SQLEndpoint') -DeleteLastItemType @('Lakehouse')
        @($plan.First).type | Should -Be @('DataAgent')
        @($plan.Last).type | Should -Be @('Lakehouse')
    }

    It 'skips the SQL analytics endpoint, which the lakehouse cascade removes' {
        $plan = Get-ItemDeletionOrder -Item $script:FullWorkspace `
            -SkipItemType @('SQLEndpoint') -DeleteLastItemType @('Lakehouse')
        @($plan.Skipped).type | Should -Be @('SQLEndpoint')
    }

    It 'does NOT skip a semantic model - since 2025-09-05 those are independent items' {
        $items = @((New-Item2 -Id 'sm-1' -Type 'SemanticModel'))
        $plan = Get-ItemDeletionOrder -Item $items -SkipItemType @('SQLEndpoint') -DeleteLastItemType @('Lakehouse')
        @($plan.Skipped).Count | Should -Be 0
        @($plan.First).type | Should -Be @('SemanticModel')
    }

    It 'copes with an empty workspace' {
        $plan = Get-ItemDeletionOrder -Item @() -SkipItemType @('SQLEndpoint') -DeleteLastItemType @('Lakehouse')
        @($plan.First).Count | Should -Be 0
        @($plan.Last).Count | Should -Be 0
    }
}

Describe 'Get-ItemDeletePath' {
    It 'uses the typed lakehouse operation, whose SP support is unconditional' {
        Get-ItemDeletePath -WorkspaceId 'w1' -ItemId 'lh-1' -ItemType 'Lakehouse' `
            -TypedDeletePath @{ Lakehouse = 'lakehouses' } |
            Should -Be 'workspaces/w1/lakehouses/lh-1'
    }

    It 'falls back to the generic item operation for every other type' {
        Get-ItemDeletePath -WorkspaceId 'w1' -ItemId 'da-1' -ItemType 'DataAgent' `
            -TypedDeletePath @{ Lakehouse = 'lakehouses' } |
            Should -Be 'workspaces/w1/items/da-1'
    }

    It 'adds hardDelete only when asked, and never to a typed path' {
        Get-ItemDeletePath -WorkspaceId 'w1' -ItemId 'da-1' -ItemType 'DataAgent' -HardDelete |
            Should -Be 'workspaces/w1/items/da-1?hardDelete=true'
        Get-ItemDeletePath -WorkspaceId 'w1' -ItemId 'lh-1' -ItemType 'Lakehouse' `
            -TypedDeletePath @{ Lakehouse = 'lakehouses' } -HardDelete |
            Should -Not -Match 'hardDelete'
    }
}

Describe 'teardown-items' {
    BeforeEach {
        Mock Write-Status {}
        Mock Get-FabricWorkspace { $script:Workspace }
        $script:ListCall = 0
        Mock Invoke-FabricApi {
            if ($Method -eq 'GET') {
                $script:ListCall++
                # First listing: a fully built workspace. Second: what survives.
                if ($script:ListCall -eq 1) { return @{ value = $script:FullWorkspace } }
                return @{ value = @((New-Item2 -Id 'ep-1' -Type 'SQLEndpoint')) }
            }
            return $null
        }
    }

    Context 'the line it never crosses' {
        It 'never issues DELETE on the workspace itself' {
            Invoke-TeardownForTest | Out-Null
            Should -Invoke Invoke-FabricApi -Exactly -Times 0 -ParameterFilter {
                $Method -eq 'DELETE' -and $Path -match '^workspaces/[^/]+$'
            }
        }

        It 'never touches role assignments, with any verb' {
            Invoke-TeardownForTest | Out-Null
            Should -Invoke Invoke-FabricApi -Exactly -Times 0 -ParameterFilter {
                $Path -match '(?i)roleAssignments'
            }
        }

        It 'never touches a capacity' {
            Invoke-TeardownForTest | Out-Null
            Should -Invoke Invoke-FabricApi -Exactly -Times 0 -ParameterFilter {
                $Path -match '(?i)capacit'
            }
        }

        It 'confines every call to the one workspace it was given' {
            Invoke-TeardownForTest | Out-Null
            Should -Invoke Invoke-FabricApi -Exactly -Times 0 -ParameterFilter {
                $Path -notlike 'workspaces/w1*'
            }
        }
    }

    Context 'deleting items' {
        It 'deletes the data agent and the lakehouse, and nothing else' {
            $result = Invoke-TeardownForTest
            @($result.Deleted).id | Should -Be @('da-1', 'lh-1')
            Should -Invoke Invoke-FabricApi -Exactly -Times 2 -ParameterFilter { $Method -eq 'DELETE' }
        }

        It 'deletes the data agent before the lakehouse it references' {
            $script:Order = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-FabricApi {
                if ($Method -eq 'DELETE') { $script:Order.Add($Path); return $null }
                $script:ListCall++
                if ($script:ListCall -eq 1) { return @{ value = $script:FullWorkspace } }
                return @{ value = @((New-Item2 -Id 'ep-1' -Type 'SQLEndpoint')) }
            }
            Invoke-TeardownForTest | Out-Null
            @($script:Order)[0] | Should -Be 'workspaces/w1/items/da-1'
            @($script:Order)[1] | Should -Be 'workspaces/w1/lakehouses/lh-1'
        }

        It 'leaves the SQL analytics endpoint alone and reports it as skipped' {
            $result = Invoke-TeardownForTest
            @($result.Skipped).id | Should -Be @('ep-1')
            Should -Invoke Invoke-FabricApi -Exactly -Times 0 -ParameterFilter {
                $Method -eq 'DELETE' -and $Path -like '*ep-1*'
            }
        }

        It 'treats an item that vanished between list and delete as already gone' {
            Mock Invoke-FabricApi {
                if ($Method -eq 'DELETE') { throw 'Response status code does not indicate success: 404 (Not Found).' }
                $script:ListCall++
                if ($script:ListCall -eq 1) { return @{ value = @((New-Item2 -Id 'da-1' -Type 'DataAgent')) } }
                return @{ value = @() }
            }
            $result = Invoke-TeardownForTest
            @($result.NotFound).id | Should -Be @('da-1')
            @($result.Deleted).Count | Should -Be 0
        }

        It 're-throws a failure that is not a 404' {
            Mock Invoke-FabricApi {
                if ($Method -eq 'DELETE') { throw 'Response status code does not indicate success: 403 (Forbidden).' }
                return @{ value = @((New-Item2 -Id 'da-1' -Type 'DataAgent')) }
            }
            { Invoke-TeardownForTest } | Should -Throw '*403*'
        }

        It 'fails loudly when a deletable item survives the teardown' {
            Mock Invoke-FabricApi {
                if ($Method -eq 'DELETE') { return $null }
                return @{ value = @((New-Item2 -Id 'lh-1' -Type 'Lakehouse' -DisplayName 'mls_operations')) }
            }
            { Invoke-TeardownForTest } | Should -Throw '*INCOMPLETE*'
        }
    }

    Context 'idempotency' {
        It 'no-ops when the workspace was never created' {
            Mock Get-FabricWorkspace { $null }
            $result = Invoke-TeardownForTest
            @($result.Deleted).Count | Should -Be 0
            Should -Invoke Invoke-FabricApi -Exactly -Times 0
        }

        It 'no-ops on an already-empty workspace' {
            Mock Invoke-FabricApi { @{ value = @() } }
            $result = Invoke-TeardownForTest
            @($result.Deleted).Count | Should -Be 0
            Should -Invoke Invoke-FabricApi -Exactly -Times 0 -ParameterFilter { $Method -eq 'DELETE' }
        }

        It 'no-ops on a second run, where only the skipped endpoint remains' {
            Mock Invoke-FabricApi {
                if ($Method -eq 'GET') { return @{ value = @((New-Item2 -Id 'ep-1' -Type 'SQLEndpoint')) } }
                return $null
            }
            $result = Invoke-TeardownForTest
            @($result.Deleted).Count | Should -Be 0
            Should -Invoke Invoke-FabricApi -Exactly -Times 0 -ParameterFilter { $Method -eq 'DELETE' }
        }
    }

    Context 'paging' {
        It 'follows the continuation token so no item is left behind' {
            Mock Invoke-FabricApi {
                if ($Method -eq 'DELETE') { return $null }
                $script:ListCall++
                switch ($script:ListCall) {
                    1 { return @{ value = @((New-Item2 -Id 'da-1' -Type 'DataAgent')); continuationToken = 'page-2' } }
                    2 { return @{ value = @((New-Item2 -Id 'da-2' -Type 'DataAgent')) } }
                    default { return @{ value = @() } }
                }
            }
            $result = Invoke-TeardownForTest
            @($result.Deleted).id | Should -Be @('da-1', 'da-2')
            Should -Invoke Invoke-FabricApi -Exactly -Times 1 -ParameterFilter {
                $Method -eq 'GET' -and $Path -like '*continuationToken=page-2'
            }
        }
    }

    Context '-WhatIf' {
        It 'issues GETs only - no DELETE reaches Fabric' {
            Invoke-TeardownForTest -AsWhatIf | Out-Null
            Should -Invoke Invoke-FabricApi -Exactly -Times 0 -ParameterFilter {
                $Method -in @('DELETE', 'POST', 'PATCH')
            }
        }

        It 'reports nothing deleted and does not re-list to verify' {
            $result = Invoke-TeardownForTest -AsWhatIf
            @($result.Deleted).Count | Should -Be 0
            Should -Invoke Invoke-FabricApi -Exactly -Times 1 -ParameterFilter { $Method -eq 'GET' }
        }
    }
}
