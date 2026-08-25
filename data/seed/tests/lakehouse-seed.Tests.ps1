# Pester tests for data/seed/lakehouse/lakehouse-seed.psm1.
#
# ZERO CLOUD CALLS. The module reaches the network through exactly two functions -
# Invoke-FabricApi (control plane, from infra/fabric/fabric-api.psm1) and
# Invoke-SeedWebRequest (OneLake + LRO polling) - and both are mocked in every scenario.
# Nothing here reads data/generated/ or writes a file outside TestDrive.

BeforeAll {
    $script:SeedRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
    $script:ModuleName = 'lakehouse-seed'
    Import-Module (Join-Path -Path $script:SeedRoot -ChildPath 'seed-common.psm1') -Force
    Import-Module (Join-Path -Path $script:SeedRoot -ChildPath 'lakehouse' -AdditionalChildPath 'lakehouse-seed.psm1') -Force

    $script:TestManifest = @{
        generator_seed = 20260822
        load_order     = @('vehicles', 'launches')
        tables         = @{
            vehicles = @{ expected_rows = 12; columns = @(@{ name = 'vehicle_id'; sql_type = 'NVARCHAR(16)'; nullable = $false }) }
            launches = @{ expected_rows = 1200; columns = @(@{ name = 'launch_id'; sql_type = 'NVARCHAR(16)'; nullable = $false }) }
        }
    }

    function New-LakehouseFixture {
        <# CSV files on TestDrive so Send-OneLakeFile has something to stat. #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture builder writing to Pester TestDrive only; gating it behind ShouldProcess would make every caller pass -Confirm:$false for no benefit.')]
        param([Parameter(Mandatory)][string]$Path)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        foreach ($table in @('vehicles', 'launches')) {
            Set-Content -LiteralPath (Join-Path -Path $Path -ChildPath "$table.csv") `
                -Value "id,name`n1,x`n" -Encoding utf8 -NoNewline
        }
        return $Path
    }

    # -AsWhatIf, never -WhatIf: see the note in sql-seed.Tests.ps1.
    function Invoke-LakehouseSeedForTest {
        param([switch]$AsWhatIf, [switch]$AsForce)
        Invoke-LakehouseSeed -Token 'tok-fabric' -OneLakeToken 'tok-onelake' `
            -Manifest $script:TestManifest -DataPath $script:DataPath `
            -Force:$AsForce -WhatIf:$AsWhatIf -Confirm:$false
    }

    $script:DataPath = New-LakehouseFixture -Path (Join-Path -Path $TestDrive -ChildPath 'generated')
}

AfterAll {
    Remove-Module 'lakehouse-seed' -Force -ErrorAction SilentlyContinue
    Remove-Module 'seed-common' -Force -ErrorAction SilentlyContinue
}

Describe 'Get-OneLakeFileUri' {
    It 'builds the documented GUID-form OneLake DFS URI' {
        # https://learn.microsoft.com/en-us/fabric/onelake/onelake-access-api
        Get-OneLakeFileUri -WorkspaceId 'ws-guid' -LakehouseId 'lh-guid' -RelativePath 'Files/seed/launches/launches.csv' |
            Should -Be 'https://onelake.dfs.fabric.microsoft.com/ws-guid/lh-guid/Files/seed/launches/launches.csv'
    }

    It 'refuses a path outside Files/, which Load Table would reject anyway' {
        { Get-OneLakeFileUri -WorkspaceId 'w' -LakehouseId 'l' -RelativePath 'Tables/launches' } |
            Should -Throw "*must live under 'Files/'*"
    }
}

Describe 'Get-SeedStagingPath' {
    It 'gives each table its own folder holding exactly one file' {
        # A folder load with more than one file in it would concatenate them.
        Get-SeedStagingPath -TableName 'cost_daily' | Should -Be 'Files/seed/cost_daily/cost_daily.csv'
    }
}

Describe 'Assert-LakehouseTableName' {
    It 'accepts every table the seed creates' {
        foreach ($table in @('launches', 'telemetry_summary', 'findings_history', 'cost_daily')) {
            Assert-LakehouseTableName -Name $table | Should -Be $table
        }
    }

    It 'refuses a name the Load Table API would reject' {
        # pattern ^(?=[0-9]*[a-zA-Z_])[a-zA-Z0-9_]{1,256}$
        foreach ($bad in @('123', 'has space', 'has-dash', '')) {
            { Assert-LakehouseTableName -Name $bad } | Should -Throw '*not a valid Fabric lakehouse table name*'
        }
    }
}

Describe 'ConvertTo-OperationStatus' {
    It 'passes a string status through' {
        ConvertTo-OperationStatus -Operation @{ status = 'Succeeded' } | Should -Be 'Succeeded'
    }

    It 'maps the numeric status codes the lakehouse endpoint uses' {
        ConvertTo-OperationStatus -Operation @{ Status = 1 } | Should -Be 'NotStarted'
        ConvertTo-OperationStatus -Operation @{ Status = 2 } | Should -Be 'Running'
        ConvertTo-OperationStatus -Operation @{ Status = 3 } | Should -Be 'Succeeded'
        ConvertTo-OperationStatus -Operation @{ Status = 4 } | Should -Be 'Failed'
    }

    It 'never reports success for a shape it does not recognise' {
        ConvertTo-OperationStatus -Operation $null | Should -Be 'Unknown'
        ConvertTo-OperationStatus -Operation @{ nothing = 'useful' } | Should -Be 'Unknown'
    }
}

Describe 'Send-OneLakeFile' {
    BeforeEach {
        Mock Invoke-SeedWebRequest { [pscustomobject]@{ StatusCode = 201; Headers = @{}; Content = $null } } -ModuleName $script:ModuleName
    }

    It 'creates the file, then appends and flushes in one call' {
        Send-OneLakeFile -OneLakeToken 'tok' -WorkspaceId 'w' -LakehouseId 'l' `
            -RelativePath 'Files/seed/vehicles/vehicles.csv' `
            -LocalPath (Join-Path -Path $script:DataPath -ChildPath 'vehicles.csv') -Confirm:$false | Out-Null

        Should -Invoke Invoke-SeedWebRequest -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
            $Method -eq 'PUT' -and $Uri -like '*?resource=file'
        }
        Should -Invoke Invoke-SeedWebRequest -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
            $Method -eq 'PATCH' -and $Uri -like '*action=append&position=0&flush=true'
        }
    }

    It 'sends the OneLake token, not the Fabric one' {
        Send-OneLakeFile -OneLakeToken 'tok-onelake' -WorkspaceId 'w' -LakehouseId 'l' `
            -RelativePath 'Files/seed/vehicles/vehicles.csv' `
            -LocalPath (Join-Path -Path $script:DataPath -ChildPath 'vehicles.csv') -Confirm:$false | Out-Null
        Should -Invoke Invoke-SeedWebRequest -ModuleName $script:ModuleName -Exactly -Times 2 -ParameterFilter {
            $Token -eq 'tok-onelake'
        }
    }

    It 'fails with an actionable message when the local file is missing' {
        { Send-OneLakeFile -OneLakeToken 'tok' -WorkspaceId 'w' -LakehouseId 'l' `
                -RelativePath 'Files/seed/x/x.csv' -LocalPath (Join-Path -Path $TestDrive -ChildPath 'generated' -AdditionalChildPath 'nope.csv') -Confirm:$false } |
            Should -Throw '*python -m generators build*'
    }

    It 'under -WhatIf uploads nothing' {
        Send-OneLakeFile -OneLakeToken 'tok' -WorkspaceId 'w' -LakehouseId 'l' `
            -RelativePath 'Files/seed/vehicles/vehicles.csv' `
            -LocalPath (Join-Path -Path $script:DataPath -ChildPath 'vehicles.csv') -WhatIf | Out-Null
        Should -Invoke Invoke-SeedWebRequest -ModuleName $script:ModuleName -Exactly -Times 0
    }
}

Describe 'Import-LakehouseTable' {
    BeforeEach {
        Mock Invoke-FabricApi {
            [pscustomobject]@{
                StatusCode = 202
                Headers    = @{ Location = @('https://api.fabric.microsoft.com/v1/operations/op-1'); 'Retry-After' = @('1') }
                Content    = $null
            }
        } -ModuleName $script:ModuleName
        Mock Invoke-SeedWebRequest {
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = @{ status = 'Succeeded' } }
        } -ModuleName $script:ModuleName
        Mock Start-Sleep {} -ModuleName $script:ModuleName
    }

    It 'POSTs to the documented Load Table path' {
        Import-LakehouseTable -Token 't' -WorkspaceId 'w1' -LakehouseId 'l1' `
            -TableName 'launches' -RelativePath 'Files/seed/launches/launches.csv' -Confirm:$false | Out-Null
        Should -Invoke Invoke-FabricApi -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $Path -eq 'workspaces/w1/lakehouses/l1/tables/launches/load'
        }
    }

    It 'sets the four options that keep the row count exact' {
        Import-LakehouseTable -Token 't' -WorkspaceId 'w1' -LakehouseId 'l1' `
            -TableName 'launches' -RelativePath 'Files/seed/launches/launches.csv' -Confirm:$false | Out-Null
        Should -Invoke Invoke-FabricApi -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
            $Body.mode -eq 'Overwrite' -and          # Append would double the table on replay
            $Body.pathType -eq 'File' -and           # Folder would sweep up anything beside it
            $Body.recursive -eq $false -and
            $Body.formatOptions.header -eq $true -and # header:false makes the header a data row
            $Body.formatOptions.format -eq 'Csv' -and
            $Body.formatOptions.delimiter -eq ','
        }
    }

    It 'never loads in Append mode' {
        Import-LakehouseTable -Token 't' -WorkspaceId 'w1' -LakehouseId 'l1' `
            -TableName 'launches' -RelativePath 'Files/seed/launches/launches.csv' -Confirm:$false | Out-Null
        Should -Invoke Invoke-FabricApi -ModuleName $script:ModuleName -Exactly -Times 0 -ParameterFilter {
            $Body.mode -eq 'Append'
        }
    }

    It 'polls the Location header verbatim rather than rebuilding the URL' {
        $result = Import-LakehouseTable -Token 't' -WorkspaceId 'w1' -LakehouseId 'l1' `
            -TableName 'launches' -RelativePath 'Files/seed/launches/launches.csv' -Confirm:$false
        $result.Awaited | Should -BeTrue
        Should -Invoke Invoke-SeedWebRequest -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
            $Uri -eq 'https://api.fabric.microsoft.com/v1/operations/op-1'
        }
    }

    It 'throws when the load operation reports Failed' {
        Mock Invoke-SeedWebRequest {
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = @{ status = 'Failed'; error = @{ code = 'BadCsv' } } }
        } -ModuleName $script:ModuleName
        { Import-LakehouseTable -Token 't' -WorkspaceId 'w1' -LakehouseId 'l1' `
                -TableName 'launches' -RelativePath 'Files/seed/launches/launches.csv' -Confirm:$false } |
            Should -Throw '*BadCsv*'
    }

    It 'accepts a synchronous response that carries no Location header' {
        Mock Invoke-FabricApi {
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = @{ ok = $true } }
        } -ModuleName $script:ModuleName
        $result = Import-LakehouseTable -Token 't' -WorkspaceId 'w1' -LakehouseId 'l1' `
            -TableName 'launches' -RelativePath 'Files/seed/launches/launches.csv' -Confirm:$false
        $result.Awaited | Should -BeFalse
        Should -Invoke Invoke-SeedWebRequest -ModuleName $script:ModuleName -Exactly -Times 0
    }

    It 'under -WhatIf issues no load' {
        Import-LakehouseTable -Token 't' -WorkspaceId 'w1' -LakehouseId 'l1' `
            -TableName 'launches' -RelativePath 'Files/seed/launches/launches.csv' -WhatIf | Out-Null
        Should -Invoke Invoke-FabricApi -ModuleName $script:ModuleName -Exactly -Times 0
    }
}

Describe 'Wait-LakehouseLoadOperation' {
    BeforeEach { Mock Start-Sleep {} -ModuleName $script:ModuleName }

    It 'keeps polling while the operation is Running' {
        $script:Calls = 0
        Mock Invoke-SeedWebRequest {
            $script:Calls++
            $status = if ($script:Calls -lt 3) { 'Running' } else { 'Succeeded' }
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = @{ status = $status } }
        } -ModuleName $script:ModuleName
        Wait-LakehouseLoadOperation -Token 't' -OperationUri 'https://op' -PollIntervalSeconds 0 | Out-Null
        Should -Invoke Invoke-SeedWebRequest -ModuleName $script:ModuleName -Exactly -Times 3
    }

    It 'gives up with a timeout rather than polling forever' {
        Mock Invoke-SeedWebRequest {
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = @{ status = 'Running' } }
        } -ModuleName $script:ModuleName
        { Wait-LakehouseLoadOperation -Token 't' -OperationUri 'https://op' -PollIntervalSeconds 0 -TimeoutSeconds -1 } |
            Should -Throw '*did not complete*'
    }
}

Describe 'Assert-LakehouseSeedPrerequisite' {
    BeforeEach {
        Mock Test-GeneratedDataComplete { $true } -ModuleName $script:ModuleName
    }

    It 'names the missing Fabric token' {
        { Assert-LakehouseSeedPrerequisite -Token '' -OneLakeToken 'o' -DataPath 'x' -Manifest $script:TestManifest } |
            Should -Throw '*api.fabric.microsoft.com*'
    }

    It 'explains that OneLake needs a different audience, not the Fabric token' {
        { Assert-LakehouseSeedPrerequisite -Token 'f' -OneLakeToken '' -DataPath 'x' -Manifest $script:TestManifest } |
            Should -Throw '*storage.azure.com*'
    }

    It 'tells the operator to run the generators when the dataset is incomplete' {
        Mock Test-GeneratedDataComplete { $false } -ModuleName $script:ModuleName
        { Assert-LakehouseSeedPrerequisite -Token 'f' -OneLakeToken 'o' -DataPath 'x' -Manifest $script:TestManifest } |
            Should -Throw '*python -m generators build*'
    }
}

Describe 'Invoke-LakehouseSeed' {
    BeforeEach {
        Mock Write-SeedStatus {} -ModuleName $script:ModuleName
        # The dataset check is exercised directly in the Assert-LakehouseSeedPrerequisite
        # block; here it stands in for a complete data/generated/ so the orchestration is
        # what is under test.
        Mock Test-GeneratedDataComplete { $true } -ModuleName $script:ModuleName
        Mock Get-FabricWorkspace { [pscustomobject]@{ id = 'w1'; displayName = 'mls-operations' } } -ModuleName $script:ModuleName
        Mock Get-FabricLakehouse { [pscustomobject]@{ id = 'l1'; displayName = 'mls_operations' } } -ModuleName $script:ModuleName
        Mock Get-FabricTable { @() } -ModuleName $script:ModuleName
        # The transports throw everywhere: any scenario that reaches the network fails
        # loudly rather than silently passing on a mock that returned something plausible.
        Mock Invoke-SeedWebRequest { throw 'no raw HTTP expected in this scenario' } -ModuleName $script:ModuleName
        Mock Invoke-FabricApi { throw 'no direct control-plane call expected in this scenario' } -ModuleName $script:ModuleName
    }

    Context 'empty lakehouse (first seed)' {
        BeforeEach {
            Mock Send-OneLakeFile { [pscustomobject]@{ RelativePath = $RelativePath; Bytes = 10 } } -ModuleName $script:ModuleName
            Mock Import-LakehouseTable { [pscustomobject]@{ Table = $TableName; Operation = $null; Awaited = $true } } -ModuleName $script:ModuleName
            $script:TableCall = 0
            Mock Get-FabricTable {
                $script:TableCall++
                if ($script:TableCall -eq 1) { return @() }
                return @([pscustomobject]@{ name = 'vehicles' }, [pscustomobject]@{ name = 'launches' })
            } -ModuleName $script:ModuleName
        }

        It 'uploads then loads every table in manifest order' {
            $result = Invoke-LakehouseSeedForTest
            Should -Invoke Send-OneLakeFile -ModuleName $script:ModuleName -Exactly -Times 2
            Should -Invoke Import-LakehouseTable -ModuleName $script:ModuleName -Exactly -Times 2
            @($result.Loaded).Table | Should -Be @('vehicles', 'launches')
        }

        It 'stages each table under its own Files/seed folder' {
            Invoke-LakehouseSeedForTest | Out-Null
            Should -Invoke Send-OneLakeFile -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
                $RelativePath -eq 'Files/seed/launches/launches.csv'
            }
        }

        It 'reads the table list back and confirms the manifest set is present' {
            $result = Invoke-LakehouseSeedForTest
            @($result.Tables) | Should -Be @('vehicles', 'launches')
        }
    }

    Context 'already seeded (idempotent replay)' {
        BeforeEach {
            Mock Send-OneLakeFile { [pscustomobject]@{ RelativePath = $RelativePath; Bytes = 10 } } -ModuleName $script:ModuleName
            Mock Import-LakehouseTable { [pscustomobject]@{ Table = $TableName; Operation = $null; Awaited = $true } } -ModuleName $script:ModuleName
            Mock Get-FabricTable {
                @([pscustomobject]@{ name = 'vehicles' }, [pscustomobject]@{ name = 'launches' })
            } -ModuleName $script:ModuleName
        }

        It 'uploads nothing and loads nothing' {
            $result = Invoke-LakehouseSeedForTest
            $result.SkippedAlreadySeeded | Should -BeTrue
            Should -Invoke Send-OneLakeFile -ModuleName $script:ModuleName -Exactly -Times 0
            Should -Invoke Import-LakehouseTable -ModuleName $script:ModuleName -Exactly -Times 0
        }

        It 'reloads under -Force' {
            $result = Invoke-LakehouseSeedForTest -AsForce
            $result.SkippedAlreadySeeded | Should -BeFalse
            Should -Invoke Import-LakehouseTable -ModuleName $script:ModuleName -Exactly -Times 2
        }
    }

    Context 'preconditions owned by another script' {
        BeforeEach {
            Mock Send-OneLakeFile { [pscustomobject]@{ RelativePath = $RelativePath; Bytes = 10 } } -ModuleName $script:ModuleName
            Mock Import-LakehouseTable { [pscustomobject]@{ Table = $TableName; Operation = $null; Awaited = $true } } -ModuleName $script:ModuleName
        }

        It 'refuses to create the workspace itself' {
            Mock Get-FabricWorkspace { $null } -ModuleName $script:ModuleName
            { Invoke-LakehouseSeedForTest } | Should -Throw '*provision-workspace.ps1*'
            Should -Invoke Send-OneLakeFile -ModuleName $script:ModuleName -Exactly -Times 0
        }

        It 'refuses to create the lakehouse itself' {
            Mock Get-FabricLakehouse { $null } -ModuleName $script:ModuleName
            { Invoke-LakehouseSeedForTest } | Should -Throw '*does not exist in workspace*'
            Should -Invoke Send-OneLakeFile -ModuleName $script:ModuleName -Exactly -Times 0
        }

        It 'fails when the load leaves a manifest table unregistered' {
            $script:TableCall = 0
            Mock Get-FabricTable {
                $script:TableCall++
                if ($script:TableCall -eq 1) { return @() }
                return @([pscustomobject]@{ name = 'vehicles' })
            } -ModuleName $script:ModuleName
            { Invoke-LakehouseSeedForTest } | Should -Throw '*launches*'
        }
    }

    Context '-WhatIf (real helpers, mocked transport)' {
        # Send-OneLakeFile and Import-LakehouseTable are deliberately NOT mocked in this
        # context: the real ones run, and the two transports throw if reached. That is
        # the whole -WhatIf claim, asserted end to end rather than one layer at a time.

        It 'issues no OneLake upload and no table load' {
            Invoke-LakehouseSeedForTest -AsWhatIf | Out-Null
            Should -Invoke Invoke-SeedWebRequest -ModuleName $script:ModuleName -Exactly -Times 0
            Should -Invoke Invoke-FabricApi -ModuleName $script:ModuleName -Exactly -Times 0
        }

        It 'reports nothing uploaded and nothing loaded' {
            $result = Invoke-LakehouseSeedForTest -AsWhatIf
            @($result.Uploaded).Count | Should -Be 0
            @($result.Loaded).Count | Should -Be 0
        }

        It 'does not re-list tables to verify a load that never happened' {
            Invoke-LakehouseSeedForTest -AsWhatIf | Out-Null
            Should -Invoke Get-FabricTable -ModuleName $script:ModuleName -Exactly -Times 1
        }
    }
}
