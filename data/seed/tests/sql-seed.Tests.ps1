# Pester tests for data/seed/sql/sql-seed.psm1.
#
# ZERO DATABASE CALLS. Invoke-SeedSqlCommand is the module's only route to a server and
# is mocked in every scenario that would reach one; Invoke-Sqlcmd is never installed in
# this environment and is never resolved. Generated data is supplied as in-memory
# fixtures, so data/generated/ (gitignored) is never read.

BeforeAll {
    $script:SeedRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
    $script:ModuleName = 'sql-seed'
    Import-Module (Join-Path -Path $script:SeedRoot -ChildPath 'seed-common.psm1') -Force
    Import-Module (Join-Path -Path $script:SeedRoot -ChildPath 'sql' -AdditionalChildPath 'sql-seed.psm1') -Force

    # A two-table stand-in manifest: enough shape to exercise ordering, typing and the
    # count contract without dragging the real ten-table file into unit tests.
    $script:TestManifest = @{
        generator_seed = 20260822
        load_order     = @('vehicles', 'launches')
        tables         = @{
            vehicles = @{
                plane         = 'reference'
                ddl_file      = '010_vehicles.sql'
                expected_rows = 2
                primary_key   = @('vehicle_id')
                foreign_keys  = @()
                columns       = @(
                    @{ name = 'vehicle_id'; sql_type = 'NVARCHAR(16)'; nullable = $false }
                    @{ name = 'reusable'; sql_type = 'BIT'; nullable = $false }
                    @{ name = 'gto_capacity_kg'; sql_type = 'INT'; nullable = $true }
                )
            }
            launches = @{
                plane         = 'operational'
                ddl_file      = '050_launches.sql'
                expected_rows = 2
                primary_key   = @('launch_id')
                foreign_keys  = @(@{ columns = @('vehicle_id'); references = 'vehicles' })
                columns       = @(
                    @{ name = 'launch_id'; sql_type = 'NVARCHAR(16)'; nullable = $false }
                    @{ name = 'vehicle_id'; sql_type = 'NVARCHAR(16)'; nullable = $false }
                    @{ name = 'customer'; sql_type = 'NVARCHAR(128)'; nullable = $false }
                    @{ name = 'actual_date'; sql_type = 'DATE'; nullable = $false }
                    @{ name = 'payload_mass_kg'; sql_type = 'FLOAT'; nullable = $false }
                    @{ name = 'insurance_value_musd'; sql_type = 'DECIMAL(18,2)'; nullable = $true }
                )
            }
        }
    }

    $script:VehicleRows = @(
        @{ vehicle_id = 'VEH-001'; reusable = $true; gto_capacity_kg = 8300 }
        @{ vehicle_id = 'VEH-003'; reusable = $false; gto_capacity_kg = $null }
    )
    $script:LaunchRows = @(
        @{ launch_id = 'LNH-0001'; vehicle_id = 'VEH-001'; customer = "O'Neill Orbital"
            actual_date = '2024-03-02'; payload_mass_kg = 12345.6; insurance_value_musd = 210.5
        }
        @{ launch_id = 'LNH-0002'; vehicle_id = 'VEH-003'; customer = '  Aurora Sat Networks'
            actual_date = '2024-03-09'; payload_mass_kg = 250.0; insurance_value_musd = $null
        }
    )

    $script:Connection = @{
        ServerInstance = 'mls-ops-demo-sql.database.windows.net'
        Database       = 'mls-ops-demo-db'
        AccessToken    = 'tok-sql'
    }

    function Get-FixtureRow {
        param([Parameter(Mandatory)][string]$Name)
        if ($Name -eq 'vehicles') { return $script:VehicleRows }
        return $script:LaunchRows
    }

    # -AsWhatIf, never -WhatIf: a helper parameter literally named WhatIf on a function
    # that does not call ShouldProcess trips PSUseSupportsShouldProcess, and lint-ci
    # fails on any warning.
    function Invoke-SqlSeedForTest {
        param(
            [switch]$AsWhatIf, [switch]$AsForce, [switch]$AsSchemaOnly, [string]$DataPath,
            [string]$WorkloadUserName = '', [string]$WorkloadUserClientId = ''
        )
        if (-not $DataPath) { $DataPath = Join-Path -Path $TestDrive -ChildPath 'generated' }
        Invoke-SqlSeed -Connection $script:Connection -Manifest $script:TestManifest `
            -DataPath $DataPath -DdlPath (Join-Path -Path $TestDrive -ChildPath 'ddl') `
            -WorkloadUserName $WorkloadUserName -WorkloadUserClientId $WorkloadUserClientId `
            -Force:$AsForce -SchemaOnly:$AsSchemaOnly -WhatIf:$AsWhatIf -Confirm:$false
    }

    # THE THREE GUIDS THIS SUITE REFUSES TO CONFLATE. The whole of F172 turns on Azure SQL
    # storing an APPLICATION's SID as its client id, so a fixture that used one value for
    # two roles could not tell a correct grant from a wrong one.
    #
    # SYNTHETIC, AND DELIBERATELY SO. The first draft used the live 2026-09-03 clientId and
    # principalId of mls-data-api-demo-id, on F114's reasoning that a fixture should be
    # pinned to the estate. That is the wrong instinct HERE and it is F172's own class:
    # a user-assigned identity is destroyed with its resource group and returns with new
    # GUIDs on every rebuild, so those two values are rebuild-scoped and would have been
    # committed stale within the hour. Nothing in these tests needs a real GUID - they need
    # three that a reader cannot mistake for one another.
    $script:DataApiClientId = 'c1c1c1c1-0000-4000-8000-00000000c1d1'
    $script:DataApiPrincipalId = 'b0b0b0b0-0000-4000-8000-00000000b0b0'
    # A previous identity of the same NAME - what a database that outlived a rebuild holds.
    $script:DeadIdentityClientId = 'dead0000-0000-4000-8000-00000000dead'
}

AfterAll {
    Remove-Module 'sql-seed' -Force -ErrorAction SilentlyContinue
    Remove-Module 'seed-common' -Force -ErrorAction SilentlyContinue
}

Describe 'Split-SqlBatch' {
    It 'splits on a line that is nothing but GO' {
        $batches = Split-SqlBatch -Script "SELECT 1;`nGO`nSELECT 2;`nGO`n"
        @($batches).Count | Should -Be 2
        @($batches)[0] | Should -Be 'SELECT 1;'
        @($batches)[1] | Should -Be 'SELECT 2;'
    }

    It 'leaves GO alone when it is part of a statement or a string' {
        $batches = Split-SqlBatch -Script "SELECT N'GO' AS GOING, GO_COL FROM t;"
        @($batches).Count | Should -Be 1
        @($batches)[0] | Should -Match 'GO_COL'
    }

    It 'tolerates indentation, trailing whitespace and a trailing comment on the separator' {
        $batches = Split-SqlBatch -Script "SELECT 1;`n   GO   -- batch one`nSELECT 2;"
        @($batches).Count | Should -Be 2
    }

    It 'drops empty batches instead of sending blank queries' {
        @(Split-SqlBatch -Script "GO`n`nGO`n   `nGO").Count | Should -Be 0
    }

    It 'returns a single batch when there is no separator at all' {
        @(Split-SqlBatch -Script 'CREATE TABLE dbo.t (a INT);').Count | Should -Be 1
    }

    It 'splits a CRLF file, which is what a Windows checkout produces' {
        # .NET multiline `$` anchors before \n, so without an explicit \r? the CR sits
        # between GO and the anchor and nothing splits - every batch would then carry
        # its GO to the server.
        $batches = Split-SqlBatch -Script "SELECT 1;`r`nGO`r`nSELECT 2;`r`nGO`r`n"
        @($batches).Count | Should -Be 2
        @($batches) | ForEach-Object { $_ | Should -Not -Match '(?im)^\s*GO\s*$' }
    }
}

Describe 'ConvertTo-SqlLiteral' {
    It 'renders $null as NULL for every type' {
        foreach ($type in @('NVARCHAR(16)', 'INT', 'FLOAT', 'DECIMAL(18,2)', 'DATE', 'BIT')) {
            ConvertTo-SqlLiteral -Value $null -SqlType $type | Should -Be 'NULL'
        }
    }

    It 'renders booleans as BIT 1/0' {
        ConvertTo-SqlLiteral -Value $true -SqlType 'BIT' | Should -Be '1'
        ConvertTo-SqlLiteral -Value $false -SqlType 'BIT' | Should -Be '0'
    }

    It 'renders the CSV spelling of a boolean too, defensively' {
        ConvertTo-SqlLiteral -Value 'True' -SqlType 'BIT' | Should -Be '1'
        ConvertTo-SqlLiteral -Value 'False' -SqlType 'BIT' | Should -Be '0'
    }

    It 'doubles single quotes rather than dropping or escaping them another way' {
        ConvertTo-SqlLiteral -Value "O'Neill Orbital" -SqlType 'NVARCHAR(128)' |
            Should -Be "N'O''Neill Orbital'"
    }

    It 'preserves the deliberate whitespace damage on dirty columns' {
        # DIRTY_RATE 0.06 produces leading/trailing/doubled spaces on purpose. A loader
        # that trims here silently destroys the data-quality story.
        ConvertTo-SqlLiteral -Value '  Aurora Sat Networks' -SqlType 'NVARCHAR(128)' |
            Should -Be "N'  Aurora Sat Networks'"
        ConvertTo-SqlLiteral -Value 'Inconel 718 ' -SqlType 'NVARCHAR(64)' |
            Should -Be "N'Inconel 718 '"
    }

    It 'renders a DATE as a quoted ISO string' {
        ConvertTo-SqlLiteral -Value '2026-06-21' -SqlType 'DATE' | Should -Be "'2026-06-21'"
    }

    It 'throws on a date that is not ISO rather than coercing it' {
        { ConvertTo-SqlLiteral -Value '21/06/2026' -SqlType 'DATE' } | Should -Throw '*ISO YYYY-MM-DD*'
    }

    It 'round-trips a float exactly' {
        ConvertTo-SqlLiteral -Value 12345.6 -SqlType 'FLOAT' | Should -Be '12345.6'
        ConvertTo-SqlLiteral -Value -80.5772 -SqlType 'FLOAT' | Should -Be '-80.5772'
    }

    It 'renders DECIMAL without scientific notation' {
        # A float-formatted 4.2E+02 would be taken as a float and implicitly converted;
        # money must not take that path.
        ConvertTo-SqlLiteral -Value 420.0 -SqlType 'DECIMAL(18,2)' | Should -Not -Match '[Ee]'
        ConvertTo-SqlLiteral -Value 1234.56 -SqlType 'DECIMAL(18,2)' | Should -Be '1234.56'
    }

    It 'formats numbers invariantly, whatever the host culture is' {
        $original = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::GetCultureInfo('de-DE')
            ConvertTo-SqlLiteral -Value 1234.56 -SqlType 'DECIMAL(18,2)' | Should -Be '1234.56'
            ConvertTo-SqlLiteral -Value 12345.6 -SqlType 'FLOAT' | Should -Be '12345.6'
        }
        finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $original
        }
    }
}

Describe 'Assert-SqlIdentifier' {
    It 'accepts a plain table name' {
        Assert-SqlIdentifier -Name 'telemetry_summary' | Should -Be 'telemetry_summary'
    }

    It 'refuses anything that could close an identifier and smuggle SQL' {
        foreach ($bad in @('launches];DROP TABLE x--', 'a b', '1abc', '')) {
            { Assert-SqlIdentifier -Name $bad } | Should -Throw '*not a plain*'
        }
    }
}

Describe 'New-SqlInsertStatement' {
    It 'names every column explicitly, in manifest order' {
        $sql = New-SqlInsertStatement -TableName 'vehicles' `
            -Table $script:TestManifest.tables.vehicles -Row $script:VehicleRows
        $sql | Should -Match '^INSERT INTO dbo\.\[vehicles\] \(\[vehicle_id\], \[reusable\], \[gto_capacity_kg\]\) VALUES'
    }

    It 'emits exactly one tuple per source row - no de-duplication anywhere' {
        $duplicated = @($script:VehicleRows[0], $script:VehicleRows[0], $script:VehicleRows[0])
        $sql = New-SqlInsertStatement -TableName 'vehicles' `
            -Table $script:TestManifest.tables.vehicles -Row $duplicated
        @([regex]::Matches($sql, "\(N'VEH-001'")).Count | Should -Be 3
    }

    It 'types each value by its manifest column, not by guessing' {
        $sql = New-SqlInsertStatement -TableName 'launches' `
            -Table $script:TestManifest.tables.launches -Row @($script:LaunchRows[0])
        $sql | Should -Match "'2024-03-02'"
        $sql | Should -Match '12345\.6'
        $sql | Should -Match "N'O''Neill Orbital'"
    }

    It 'writes NULL for a missing nullable value' {
        $sql = New-SqlInsertStatement -TableName 'launches' `
            -Table $script:TestManifest.tables.launches -Row @($script:LaunchRows[1])
        $sql | Should -Match 'NULL\)'
    }

    It 'returns an empty string for an empty chunk rather than invalid SQL' {
        New-SqlInsertStatement -TableName 'vehicles' `
            -Table $script:TestManifest.tables.vehicles -Row @() | Should -Be ''
    }
}

Describe 'New-SqlConnectionDescriptor' {
    It 'accepts empty values so the actionable message comes from the prerequisite check' {
        # Rejecting them here would surface PowerShell's "Cannot bind argument to
        # parameter 'ServerInstance' because it is an empty string" instead - exactly
        # what a caller who forgot the parameter does not need to read. This is the path
        # a no-argument invocation takes.
        $connection = New-SqlConnectionDescriptor -ServerInstance '' -Database ''
        $connection.ServerInstance | Should -Be ''
        $connection.AccessToken | Should -Be ''
    }

    It 'carries the caller-supplied token without altering it' {
        (New-SqlConnectionDescriptor -ServerInstance 's' -Database 'd' -AccessToken 'tok').AccessToken |
            Should -Be 'tok'
    }
}

Describe 'Assert-SqlSeedPrerequisite' {
    BeforeEach {
        Mock Write-SeedStatus {} -ModuleName $script:ModuleName
        Mock Test-GeneratedDataComplete { $true } -ModuleName $script:ModuleName
        Mock Get-Command { [pscustomobject]@{ Name = 'Invoke-Sqlcmd' } } -ModuleName $script:ModuleName
        New-Item -ItemType Directory -Path (Join-Path -Path $TestDrive -ChildPath 'ddl') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'ddl' -AdditionalChildPath '000_schema_version.sql') -Value 'SELECT 1;' -Encoding utf8
    }

    It 'names the missing server rather than failing at connect time' {
        $connection = @{ ServerInstance = ''; Database = 'db'; AccessToken = 't' }
        { Assert-SqlSeedPrerequisite -Connection $connection -DdlPath (Join-Path -Path $TestDrive -ChildPath 'ddl') `
                -DataPath (Join-Path -Path $TestDrive -ChildPath 'generated') -Manifest $script:TestManifest } |
            Should -Throw '*-SqlServerInstance*'
    }

    It 'names the missing database' {
        $connection = @{ ServerInstance = 's'; Database = ''; AccessToken = 't' }
        { Assert-SqlSeedPrerequisite -Connection $connection -DdlPath (Join-Path -Path $TestDrive -ChildPath 'ddl') `
                -DataPath (Join-Path -Path $TestDrive -ChildPath 'generated') -Manifest $script:TestManifest } |
            Should -Throw '*-SqlDatabase*'
    }

    It 'tells the operator how to install the SqlServer module when it is absent' {
        Mock Get-Command { $null } -ModuleName $script:ModuleName
        { Assert-SqlSeedPrerequisite -Connection $script:Connection -DdlPath (Join-Path -Path $TestDrive -ChildPath 'ddl') `
                -DataPath (Join-Path -Path $TestDrive -ChildPath 'generated') -Manifest $script:TestManifest } |
            Should -Throw '*Install-Module SqlServer*'
    }

    It 'refuses a DDL directory that does not exist' {
        { Assert-SqlSeedPrerequisite -Connection $script:Connection -DdlPath (Join-Path -Path $TestDrive -ChildPath 'nope') `
                -DataPath (Join-Path -Path $TestDrive -ChildPath 'generated') -Manifest $script:TestManifest } |
            Should -Throw '*does not exist*'
    }

    It 'refuses a DDL directory with no .sql files instead of creating nothing' {
        New-Item -ItemType Directory -Path (Join-Path -Path $TestDrive -ChildPath 'emptyddl') -Force | Out-Null
        { Assert-SqlSeedPrerequisite -Connection $script:Connection -DdlPath (Join-Path -Path $TestDrive -ChildPath 'emptyddl') `
                -DataPath (Join-Path -Path $TestDrive -ChildPath 'generated') -Manifest $script:TestManifest } |
            Should -Throw '*no .sql files*'
    }

    It 'tells the operator to run the generators when the dataset is incomplete' {
        Mock Test-GeneratedDataComplete { $false } -ModuleName $script:ModuleName
        { Assert-SqlSeedPrerequisite -Connection $script:Connection -DdlPath (Join-Path -Path $TestDrive -ChildPath 'ddl') `
                -DataPath (Join-Path -Path $TestDrive -ChildPath 'generated') -Manifest $script:TestManifest } |
            Should -Throw '*python -m generators build*'
    }

    It 'warns but does not fail when no access token was supplied' {
        $connection = @{ ServerInstance = 's'; Database = 'd'; AccessToken = '' }
        { Assert-SqlSeedPrerequisite -Connection $connection -DdlPath (Join-Path -Path $TestDrive -ChildPath 'ddl') `
                -DataPath (Join-Path -Path $TestDrive -ChildPath 'generated') -Manifest $script:TestManifest } | Should -Not -Throw
        Should -Invoke Write-SeedStatus -ModuleName $script:ModuleName -Exactly -Times 1
    }

    It 'requires the generated dataset by default (baseline for the next test)' {
        Mock Test-GeneratedDataComplete { $false } -ModuleName $script:ModuleName
        { Assert-SqlSeedPrerequisite -Connection $script:Connection -DdlPath (Join-Path -Path $TestDrive -ChildPath 'ddl') `
                -DataPath (Join-Path -Path $TestDrive -ChildPath 'generated') -Manifest $script:TestManifest } |
            Should -Throw '*python -m generators build*'
    }

    It 'skips the generated-dataset check under -SchemaOnly (F20: DDL/grants need no data)' {
        Mock Test-GeneratedDataComplete { $false } -ModuleName $script:ModuleName
        { Assert-SqlSeedPrerequisite -Connection $script:Connection -DdlPath (Join-Path -Path $TestDrive -ChildPath 'ddl') `
                -DataPath (Join-Path -Path $TestDrive -ChildPath 'generated') -Manifest $script:TestManifest -SchemaOnly } |
            Should -Not -Throw
        Should -Invoke Test-GeneratedDataComplete -ModuleName $script:ModuleName -Exactly -Times 0
    }
}

Describe 'Install-SeedSchema' {
    BeforeEach {
        Mock Write-SeedStatus {} -ModuleName $script:ModuleName
        Mock Invoke-SeedSqlCommand {} -ModuleName $script:ModuleName
        New-Item -ItemType Directory -Path (Join-Path -Path $TestDrive -ChildPath 'ddl2') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'ddl2' -AdditionalChildPath '010_a.sql') -Value "SELECT 1;`nGO`nSELECT 2;`nGO" -Encoding utf8
        Set-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'ddl2' -AdditionalChildPath '000_first.sql') -Value "SELECT 0;`nGO" -Encoding utf8
        Set-Content -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'ddl2' -AdditionalChildPath '110_last.sql') -Value "SELECT 3;`nGO" -Encoding utf8
    }

    It 'applies files in filename order, which is dependency order' {
        $applied = Install-SeedSchema -Connection $script:Connection -DdlPath (Join-Path -Path $TestDrive -ChildPath 'ddl2') -Confirm:$false
        @($applied) | Should -Be @('000_first.sql', '010_a.sql', '110_last.sql')
    }

    It 'sends each GO-separated batch as its own query' {
        Install-SeedSchema -Connection $script:Connection -DdlPath (Join-Path -Path $TestDrive -ChildPath 'ddl2') -Confirm:$false | Out-Null
        Should -Invoke Invoke-SeedSqlCommand -ModuleName $script:ModuleName -Exactly -Times 4
    }

    It 'never sends the GO separator itself to the server' {
        Install-SeedSchema -Connection $script:Connection -DdlPath (Join-Path -Path $TestDrive -ChildPath 'ddl2') -Confirm:$false | Out-Null
        Should -Invoke Invoke-SeedSqlCommand -ModuleName $script:ModuleName -Exactly -Times 0 -ParameterFilter {
            $Query -match '(?im)^\s*GO\s*$'
        }
    }

    It 'under -WhatIf issues no query and reports nothing applied' {
        $applied = Install-SeedSchema -Connection $script:Connection -DdlPath (Join-Path -Path $TestDrive -ChildPath 'ddl2') -WhatIf
        Should -Invoke Invoke-SeedSqlCommand -ModuleName $script:ModuleName -Exactly -Times 0
        @($applied).Count | Should -Be 0
    }
}

Describe 'Import-SeedTable' {
    BeforeEach {
        Mock Write-SeedStatus {} -ModuleName $script:ModuleName
        Mock Invoke-SeedSqlCommand {} -ModuleName $script:ModuleName
        Mock Get-SeedTableRowCount { 2 } -ModuleName $script:ModuleName
    }

    It 'refuses to load a table whose row count already disagrees with the contract' {
        { Import-SeedTable -Connection $script:Connection -TableName 'vehicles' `
                -Table $script:TestManifest.tables.vehicles -Row @($script:VehicleRows[0]) -Confirm:$false } |
            Should -Throw '*expects 2*'
        Should -Invoke Invoke-SeedSqlCommand -ModuleName $script:ModuleName -Exactly -Times 0
    }

    It 'throws when the read-back count does not match, instead of reporting success' {
        Mock Get-SeedTableRowCount { 1 } -ModuleName $script:ModuleName
        { Import-SeedTable -Connection $script:Connection -TableName 'vehicles' `
                -Table $script:TestManifest.tables.vehicles -Row $script:VehicleRows -Confirm:$false } |
            Should -Throw '*INCOMPLETE*'
    }

    It 'verifies the load and reports the counts' {
        $result = Import-SeedTable -Connection $script:Connection -TableName 'vehicles' `
            -Table $script:TestManifest.tables.vehicles -Row $script:VehicleRows -Confirm:$false
        $result.Loaded | Should -Be 2
        $result.Expected | Should -Be 2
        $result.Verified | Should -BeTrue
    }

    It 'chunks large loads without losing or duplicating a row' {
        $rows = 1..10 | ForEach-Object { @{ vehicle_id = "VEH-$_"; reusable = $true; gto_capacity_kg = $_ } }
        $table = @{ expected_rows = 10; columns = $script:TestManifest.tables.vehicles.columns }
        Mock Get-SeedTableRowCount { 10 } -ModuleName $script:ModuleName
        $sent = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-SeedSqlCommand { $sent.Add($Query) } -ModuleName $script:ModuleName
        Import-SeedTable -Connection $script:Connection -TableName 'vehicles' -Table $table `
            -Row @($rows) -BatchSize 3 -Confirm:$false | Out-Null
        @($sent).Count | Should -Be 4
        $tuples = ($sent -join "`n" | Select-String -Pattern "\(N'VEH-\d+'" -AllMatches).Matches.Count
        $tuples | Should -Be 10
    }

    It 'under -WhatIf issues no query at all' {
        Import-SeedTable -Connection $script:Connection -TableName 'vehicles' `
            -Table $script:TestManifest.tables.vehicles -Row $script:VehicleRows -WhatIf | Out-Null
        Should -Invoke Invoke-SeedSqlCommand -ModuleName $script:ModuleName -Exactly -Times 0
    }
}

Describe 'Clear-SeedTable' {
    BeforeEach {
        Mock Write-SeedStatus {} -ModuleName $script:ModuleName
        Mock Invoke-SeedSqlCommand {} -ModuleName $script:ModuleName
    }

    It 'uses DELETE, never TRUNCATE (which a foreign key would refuse)' {
        Clear-SeedTable -Connection $script:Connection -TableName @('launches') -Confirm:$false | Out-Null
        Should -Invoke Invoke-SeedSqlCommand -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
            $Query -eq 'DELETE FROM dbo.[launches];'
        }
    }

    It 'never disables a constraint to make the wipe easier' {
        Clear-SeedTable -Connection $script:Connection -TableName @('launches', 'vehicles') -Confirm:$false | Out-Null
        Should -Invoke Invoke-SeedSqlCommand -ModuleName $script:ModuleName -Exactly -Times 0 -ParameterFilter {
            $Query -match '(?i)NOCHECK|DISABLE\s+TRIGGER|DROP\s+CONSTRAINT'
        }
    }

    It 'under -WhatIf deletes nothing' {
        Clear-SeedTable -Connection $script:Connection -TableName @('launches') -WhatIf | Out-Null
        Should -Invoke Invoke-SeedSqlCommand -ModuleName $script:ModuleName -Exactly -Times 0
    }
}

Describe 'Invoke-SqlSeed' {
    BeforeEach {
        Mock Write-SeedStatus {} -ModuleName $script:ModuleName
        Mock Assert-SqlSeedPrerequisite {} -ModuleName $script:ModuleName
        Mock Install-SeedSchema { @('000_schema_version.sql') } -ModuleName $script:ModuleName
        Mock Get-SeedTableRow { Get-FixtureRow -Name $Name } -ModuleName $script:ModuleName
        Mock Invoke-SeedSqlCommand {} -ModuleName $script:ModuleName
        Mock Clear-SeedTable { @() } -ModuleName $script:ModuleName
        Mock Import-SeedTable {
            [pscustomobject]@{ Table = $TableName; Loaded = 2; Expected = 2; Verified = $true }
        } -ModuleName $script:ModuleName
    }

    Context 'already seeded (idempotent replay)' {
        BeforeEach {
            Mock Get-SeedTableRowCount { 2 } -ModuleName $script:ModuleName
        }

        It 'loads nothing and says so' {
            $result = Invoke-SqlSeedForTest
            $result.SkippedAlreadySeeded | Should -BeTrue
            Should -Invoke Import-SeedTable -ModuleName $script:ModuleName -Exactly -Times 0
            Should -Invoke Clear-SeedTable -ModuleName $script:ModuleName -Exactly -Times 0
        }

        It 'still applies the DDL, because that is guarded and free' {
            Invoke-SqlSeedForTest | Out-Null
            Should -Invoke Install-SeedSchema -ModuleName $script:ModuleName -Exactly -Times 1
        }

        It 'reloads anyway under -Force (the wipe-and-reseed remediation)' {
            $result = Invoke-SqlSeedForTest -AsForce
            $result.SkippedAlreadySeeded | Should -BeFalse
            Should -Invoke Import-SeedTable -ModuleName $script:ModuleName -Exactly -Times 2
            Should -Invoke Clear-SeedTable -ModuleName $script:ModuleName -Exactly -Times 1
        }
    }

    Context 'empty database (first seed)' {
        BeforeEach {
            Mock Get-SeedTableRowCount { 0 } -ModuleName $script:ModuleName
        }

        It 'loads every table in manifest load order' {
            $result = Invoke-SqlSeedForTest
            @($result.Loaded).Table | Should -Be @('vehicles', 'launches')
        }

        It 'does not try to clear tables that are already empty' {
            Invoke-SqlSeedForTest | Out-Null
            Should -Invoke Clear-SeedTable -ModuleName $script:ModuleName -Exactly -Times 0
        }
    }

    Context 'partially loaded database' {
        BeforeEach {
            # launches short by one row: the classic half-finished load.
            Mock Get-SeedTableRowCount {
                if ($TableName -eq 'launches') { return 1 }
                return 2
            } -ModuleName $script:ModuleName
        }

        It 'wipes before reloading rather than appending onto the partial state' {
            Invoke-SqlSeedForTest | Out-Null
            Should -Invoke Clear-SeedTable -ModuleName $script:ModuleName -Exactly -Times 1
            Should -Invoke Import-SeedTable -ModuleName $script:ModuleName -Exactly -Times 2
        }

        It 'clears in reverse dependency order so foreign keys stay enforced' {
            Invoke-SqlSeedForTest | Out-Null
            Should -Invoke Clear-SeedTable -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
                @($TableName) -join ',' -eq 'launches,vehicles'
            }
        }
    }

    Context '-SchemaOnly (F20: second run on an already-seeded estate must still reach the grant)' {
        BeforeEach {
            # Every table already holds its expected row count - the exact state a
            # post-L7 re-invocation finds after L6's seed has run. If -SchemaOnly ever
            # regressed into consulting row counts (the short-circuit this finding is
            # named for), this mock turns that into a hard failure instead of a silent
            # pass, because a real Azure SQL connection would throw here too.
            Mock Get-SeedTableRowCount { throw 'must not probe row counts under -SchemaOnly' } -ModuleName $script:ModuleName
            Mock Install-SeedSchema { @('000_first.sql', '900-contained-users.sql') } -ModuleName $script:ModuleName
        }

        It 'applies the DDL - including the grant file - without consulting row counts at all' {
            $result = Invoke-SqlSeedForTest -AsSchemaOnly
            $result.AppliedDdl | Should -Contain '900-contained-users.sql'
            $result.SchemaOnly | Should -BeTrue
            Should -Invoke Install-SeedSchema -ModuleName $script:ModuleName -Exactly -Times 1
            Should -Invoke Get-SeedTableRowCount -ModuleName $script:ModuleName -Exactly -Times 0
        }

        It 'never wipes or loads table data' {
            Invoke-SqlSeedForTest -AsSchemaOnly | Out-Null
            Should -Invoke Clear-SeedTable -ModuleName $script:ModuleName -Exactly -Times 0
            Should -Invoke Import-SeedTable -ModuleName $script:ModuleName -Exactly -Times 0
        }

        It 'does not require data/generated/ to exist' {
            # A path that cannot possibly hold a complete dataset - if Assert-
            # SqlSeedPrerequisite's real (unmocked) dataset check ran, this would throw.
            { Invoke-SqlSeedForTest -AsSchemaOnly -DataPath (Join-Path -Path $TestDrive -ChildPath 'does-not-exist') } |
                Should -Not -Throw
            Should -Invoke Assert-SqlSeedPrerequisite -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
                $SchemaOnly -eq $true
            }
        }

        It 'reports an empty Loaded list and SkippedAlreadySeeded false - this is not the same outcome as the load short-circuit' {
            $result = Invoke-SqlSeedForTest -AsSchemaOnly
            @($result.Loaded).Count | Should -Be 0
            $result.SkippedAlreadySeeded | Should -BeFalse
        }
    }

    Context 'the workload contained-user grant (F172)' {
        BeforeEach {
            # A tiny in-memory sys.database_principals: name -> the GUID its SID decodes
            # to. Every statement the module issues is routed through the one mocked
            # choke point and interpreted, so the tests exercise the SQL the module
            # actually writes rather than a paraphrase of it.
            $script:Principal = @{}
            $script:RoleMember = @{}
            $script:IssuedQuery = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-SeedSqlCommand -ModuleName $script:ModuleName {
                $script:IssuedQuery.Add($Query)
                if ($Query -match 'FROM sys\.database_principals\s*\r?\n?WHERE \[name\] = N''([^'']+)''') {
                    $name = $Matches[1]
                    if (-not $script:Principal.ContainsKey($name)) { return @() }
                    return @(@{ type_desc = 'EXTERNAL_USER'; sid_guid = $script:Principal[$name] })
                }
                if ($Query -match 'SELECT COUNT_BIG\(\*\) AS n' -and $Query -match 'database_role_members') {
                    $role = ([regex]::Match($Query, "r\.\[name\] = N'([^']+)'")).Groups[1].Value
                    $member = ([regex]::Match($Query, "m\.\[name\] = N'([^']+)'")).Groups[1].Value
                    return @(@{ n = [int64]$(if ($script:RoleMember["$role|$member"]) { 1 } else { 0 }) })
                }
                if ($Query -match "CREATE USER \[([^\]]+)\] WITH SID = ' \+ CONVERT") {
                    # The module builds the literal in T-SQL, so the fixture reads the
                    # GUID out of the DECLARE the same way the engine would.
                    $name = $Matches[1]
                    $guid = ([regex]::Match($Query, "CAST\(N'([0-9a-fA-F-]{36})' AS UNIQUEIDENTIFIER\)")).Groups[1].Value
                    $script:Principal[$name] = $guid
                    return @()
                }
                if ($Query -match 'DROP USER \[([^\]]+)\]') {
                    $script:Principal.Remove($Matches[1]) | Out-Null
                    return @()
                }
                if ($Query -match 'ALTER ROLE \[([^\]]+)\] ADD MEMBER \[([^\]]+)\]') {
                    $script:RoleMember["$($Matches[1])|$($Matches[2])"] = $true
                    return @()
                }
                return @()
            }
        }

        It 'creates the user with the identity CLIENT id as its SID, and never asks Graph' {
            $result = Set-SeedWorkloadUser -Connection $script:Connection `
                -PrincipalName 'mls-data-api-demo-id' -ClientId $script:DataApiClientId -Confirm:$false
            $result.Action | Should -Be 'created'
            $script:Principal['mls-data-api-demo-id'] | Should -Be $script:DataApiClientId
            # THE DEFECT, ENCODED. FROM EXTERNAL PROVIDER resolves the principal in
            # Microsoft Graph via the SQL server's own managed identity, which teardown
            # destroys and rebuilds with a new principal id - so the Directory Readers
            # grant it depends on silently stops existing on the first rebuild (F172).
            ($script:IssuedQuery -join ' ') | Should -Not -Match 'FROM EXTERNAL PROVIDER' `
                -Because 'the grant must not depend on a tenant-level role assignment that a rebuild erases'
        }

        It 'adds the user to db_datareader and proves the membership rather than announcing it' {
            Set-SeedWorkloadUser -Connection $script:Connection `
                -PrincipalName 'mls-data-api-demo-id' -ClientId $script:DataApiClientId -Confirm:$false | Out-Null
            $script:RoleMember['db_datareader|mls-data-api-demo-id'] | Should -BeTrue
        }

        It 'is a no-op on replay - the second run neither drops nor recreates' {
            Set-SeedWorkloadUser -Connection $script:Connection `
                -PrincipalName 'mls-data-api-demo-id' -ClientId $script:DataApiClientId -Confirm:$false | Out-Null
            $script:IssuedQuery.Clear()
            $again = Set-SeedWorkloadUser -Connection $script:Connection `
                -PrincipalName 'mls-data-api-demo-id' -ClientId $script:DataApiClientId -Confirm:$false
            $again.Action | Should -Be 'already correct'
            ($script:IssuedQuery -join ' ') | Should -Not -Match 'DROP USER'
            ($script:IssuedQuery -join ' ') | Should -Not -Match 'CREATE USER'
        }

        It 'repairs a user left behind by a PREVIOUS identity of the same name' {
            # The rebuild case the old name-only check could not see: a user-assigned
            # identity destroyed with its resource group and recreated under the same
            # name gets a new clientId, and a database that outlived it holds a user
            # nobody can log in as. "A principal of this name exists" passes on it.
            $script:Principal['mls-data-api-demo-id'] = $script:DeadIdentityClientId
            $result = Set-SeedWorkloadUser -Connection $script:Connection `
                -PrincipalName 'mls-data-api-demo-id' -ClientId $script:DataApiClientId -Confirm:$false
            $result.Action | Should -Be 'recreated'
            ($script:IssuedQuery -join ' ') | Should -Match 'DROP USER'
            $script:Principal['mls-data-api-demo-id'] | Should -Be $script:DataApiClientId
        }

        It 'throws when the user exists with the wrong SID after the writes ran' {
            # Assert the effect, not the exit code: every statement can run without
            # throwing and leave the wrong thing behind.
            Mock Invoke-SeedSqlCommand -ModuleName $script:ModuleName {
                if ($Query -match 'FROM sys\.database_principals\s*\r?\n?WHERE') {
                    return @(@{ type_desc = 'EXTERNAL_USER'; sid_guid = $script:DeadIdentityClientId })
                }
                return @()
            }
            { Set-SeedWorkloadUser -Connection $script:Connection -PrincipalName 'mls-data-api-demo-id' `
                    -ClientId $script:DataApiClientId -Confirm:$false } |
                Should -Throw "*exists with SID*$($script:DeadIdentityClientId)*"
        }

        It 'throws when the user is absent after CREATE USER ran without throwing' {
            Mock Invoke-SeedSqlCommand -ModuleName $script:ModuleName { return @() }
            { Set-SeedWorkloadUser -Connection $script:Connection -PrincipalName 'mls-data-api-demo-id' `
                    -ClientId $script:DataApiClientId -Confirm:$false } |
                Should -Throw '*does not exist after CREATE USER*'
        }

        It 'throws when the user exists with the right SID but holds no role membership' {
            Mock Invoke-SeedSqlCommand -ModuleName $script:ModuleName {
                if ($Query -match 'FROM sys\.database_principals\s*\r?\n?WHERE') {
                    return @(@{ type_desc = 'EXTERNAL_USER'; sid_guid = $script:DataApiClientId })
                }
                if ($Query -match 'COUNT_BIG') { return @(@{ n = [int64]0 }) }
                return @()
            }
            { Set-SeedWorkloadUser -Connection $script:Connection -PrincipalName 'mls-data-api-demo-id' `
                    -ClientId $script:DataApiClientId -Confirm:$false } |
                Should -Throw '*not a member of [[]db_datareader[]]*'
        }

        It 'refuses a principalId supplied where a clientId belongs, by refusing anything that is not a GUID' {
            # The GUID guard cannot tell a principalId from a clientId - both are GUIDs -
            # so this asserts the guard it CAN enforce, and V7.6 is what settles the other.
            { Set-SeedWorkloadUser -Connection $script:Connection -PrincipalName 'mls-data-api-demo-id' `
                    -ClientId 'mls-data-api-demo-id' -Confirm:$false } |
                Should -Throw '*is not a GUID*'
        }

        It 'refuses a principal name that could close the bracket it is interpolated into' {
            { Set-SeedWorkloadUser -Connection $script:Connection -PrincipalName 'evil]; DROP TABLE launches; --' `
                    -ClientId $script:DataApiClientId -Confirm:$false } |
                Should -Throw '*not a plain*'
        }

        It 'accepts the hyphenated estate naming convention Assert-SqlIdentifier rejects' {
            # <prefix>-<role>-<env>-<type> per CLAUDE.md. Reusing Assert-SqlIdentifier
            # here would reject every workload identity this estate has.
            { Assert-SqlIdentifier -Name 'mls-data-api-demo-id' } | Should -Throw
            Assert-SqlPrincipalName -Name 'mls-data-api-demo-id' | Should -Be 'mls-data-api-demo-id'
        }

        It 'grants nothing when the seed is invoked without an identity - the L6 case' {
            Mock Set-SeedWorkloadUser -ModuleName $script:ModuleName {}
            $result = Invoke-SqlSeedForTest -AsSchemaOnly
            $result.WorkloadUser | Should -BeNullOrEmpty
            Should -Invoke Set-SeedWorkloadUser -ModuleName $script:ModuleName -Exactly -Times 0
        }

        It 'grants when L7 supplies the identity, through the -SchemaOnly path' {
            Mock Set-SeedWorkloadUser -ModuleName $script:ModuleName {
                [pscustomobject]@{ PrincipalName = $PrincipalName; ClientId = $ClientId; Action = 'created'; Role = @('db_datareader') }
            }
            $result = Invoke-SqlSeedForTest -AsSchemaOnly -WorkloadUserName 'mls-data-api-demo-id' `
                -WorkloadUserClientId $script:DataApiClientId
            $result.WorkloadUser.ClientId | Should -Be $script:DataApiClientId
            Should -Invoke Set-SeedWorkloadUser -ModuleName $script:ModuleName -Exactly -Times 1 -ParameterFilter {
                $PrincipalName -eq 'mls-data-api-demo-id' -and $ClientId -eq $script:DataApiClientId
            }
        }

        It 'refuses half a pair rather than skipping the grant silently' {
            { Invoke-SqlSeedForTest -AsSchemaOnly -WorkloadUserName 'mls-data-api-demo-id' } |
                Should -Throw '*are a pair*'
            { Invoke-SqlSeedForTest -AsSchemaOnly -WorkloadUserClientId $script:DataApiClientId } |
                Should -Throw '*are a pair*'
        }
    }

    Context '-WhatIf' {
        It 'makes no database call whatsoever' {
            Mock Get-SeedTableRowCount { throw 'must not probe the database under -WhatIf' } -ModuleName $script:ModuleName
            $result = Invoke-SqlSeedForTest -AsWhatIf
            $result.WhatIf | Should -BeTrue
            Should -Invoke Invoke-SeedSqlCommand -ModuleName $script:ModuleName -Exactly -Times 0
            Should -Invoke Get-SeedTableRowCount -ModuleName $script:ModuleName -Exactly -Times 0
            Should -Invoke Import-SeedTable -ModuleName $script:ModuleName -Exactly -Times 0
            Should -Invoke Clear-SeedTable -ModuleName $script:ModuleName -Exactly -Times 0
        }

        It 'still checks prerequisites, because they are local' {
            Invoke-SqlSeedForTest -AsWhatIf | Out-Null
            Should -Invoke Assert-SqlSeedPrerequisite -ModuleName $script:ModuleName -Exactly -Times 1
        }
    }
}
