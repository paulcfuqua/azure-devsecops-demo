# =============================================================================
# The drift test. Three independent descriptions of the same ten tables have to
# agree, and nothing at runtime would tell us if they stopped:
#
#   A. data/generators/build.py + pools.py  - what the generators actually emit
#   B. data/seed/schema-manifest.json       - the seed contract
#   C. data/seed/sql/*.sql                  - the Azure SQL DDL
#
# A mismatch between B and C is a load failure at L6. A mismatch between A and B
# is worse: the load succeeds and the wrong data lands, so L7 renders blanks and
# L8 answers questions from columns that are not there. Both directions of both
# comparisons are asserted here.
#
# NO CLOUD, NO DATABASE, NO NETWORK. This file reads three repo-tracked source
# trees and parses them. It never touches data/generated/ (gitignored, may not
# exist) and never opens a connection - those are mocked in the sibling suites.
# =============================================================================

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', '..')).Path
    $script:SeedRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
    $script:SqlRoot = Join-Path -Path $script:SeedRoot -ChildPath 'sql'
    $script:GeneratorRoot = Join-Path -Path $script:RepoRoot -ChildPath 'data' -AdditionalChildPath 'generators'

    Import-Module (Join-Path -Path $script:SeedRoot -ChildPath 'seed-common.psm1') -Force
    $script:Manifest = Get-SeedManifest -Path (Join-Path -Path $script:SeedRoot -ChildPath 'schema-manifest.json')
    $script:LoadOrder = @($script:Manifest['load_order'])

    # The counts the Verifier asserts post-seed (L05 playbook V5.3). Hardcoded here on
    # purpose: if someone "fixes" the manifest to match a drifted generator, this list
    # is the thing that refuses to move with it.
    $script:VerifierCounts = @{
        launches = 1200; scrubs = 475; vehicles = 12; pads = 11
        telemetry_summary = 1200; parts = 300; suppliers = 24
        work_orders = 800; cost_daily = 4515; findings_history = 420
    }

    function Get-DdlTableDefinition {
        <#
            Parse CREATE TABLE dbo.<name> ( ... ); out of a .sql file.
            Returns @{ table = [ordered]@{ column = @{ Type; Nullable } } }.
            Constraint lines are skipped; only bracketed column definitions count.
        #>
        param([Parameter(Mandatory)][string]$Path)
        $text = Get-Content -LiteralPath $Path -Raw -Encoding utf8
        $tables = [ordered]@{}
        foreach ($table in [regex]::Matches($text, '(?s)CREATE\s+TABLE\s+dbo\.(?<name>\w+)\s*\((?<body>.*?)\r?\n\s*\);')) {
            $columns = [ordered]@{}
            # Columns always precede constraints in a CREATE TABLE, so the first
            # CONSTRAINT line ends the column list. Without that latch, a multi-line
            # CHECK body such as `[disposition] IS NULL OR [disposition] IN (...)`
            # reads as a column definition and overwrites the real one.
            $inColumns = $true
            foreach ($line in ($table.Groups['body'].Value -split '\r?\n')) {
                $trimmed = $line.Trim()
                if ($trimmed -match '^CONSTRAINT\b') { $inColumns = $false }
                $column = [regex]::Match($trimmed, '^\[(?<col>[A-Za-z_][A-Za-z0-9_]*)\]\s+(?<type>[A-Za-z]+(\s*\(\s*[0-9]+(\s*,\s*[0-9]+)?\s*\))?)')
                if ($inColumns -and $column.Success) {
                    # [regex]::Match rather than -match: the automatic $Matches is
                    # clobbered by the very next -notmatch on this line, which would
                    # leave the group lookups reading null.
                    $columns[$column.Groups['col'].Value] = @{
                        Type     = ($column.Groups['type'].Value -replace '\s+', '').ToUpperInvariant()
                        Nullable = ($trimmed -notmatch '\bNOT\s+NULL\b')
                    }
                }
            }
            $tables[$table.Groups['name'].Value] = $columns
        }
        return $tables
    }

    function Get-AllDdlTable {
        <# Every CREATE TABLE across data/seed/sql, keyed by table name. #>
        param([Parameter(Mandatory)][string]$Path)
        $all = [ordered]@{}
        foreach ($file in (Get-ChildItem -LiteralPath $Path -Filter '*.sql' -File | Sort-Object -Property Name)) {
            foreach ($entry in (Get-DdlTableDefinition -Path $file.FullName).GetEnumerator()) {
                $all[$entry.Key] = $entry.Value
            }
        }
        return $all
    }

    function Get-PythonRowLiteral {
        <#
            The `rows.append({ ... })` dict literal inside one generator function - the
            single expression that defines what a row IS.

            Anchoring on rows.append rather than on the whole function body matters:
            a function region also contains module-level dicts that happen to sit
            before the next `def` (_TLM_BASE, _APOGEE_KM) and comparisons of the shape
            `if status == "closed":`, both of which look exactly like dict keys to a
            naive scan and would smuggle phantom columns into the contract.
        #>
        param(
            [Parameter(Mandatory)][string]$Source,
            [Parameter(Mandatory)][string]$FunctionName
        )
        $region = [regex]::Match($Source, "(?s)\ndef\s+$([regex]::Escape($FunctionName))\s*\(.*?(?=\ndef\s|\Z)")
        if (-not $region.Success) { throw "Could not find def $FunctionName in the generator source." }
        $literal = [regex]::Match($region.Value, '(?s)rows\.append\(\{(?<body>.*?)\n\s*\}\)')
        if (-not $literal.Success) { throw "Could not find the rows.append({...}) literal in $FunctionName." }
        return $literal.Groups['body'].Value
    }

    function Get-DictLiteralKey {
        <#
            Ordered dict-literal keys in a chunk of Python: "<key>": ...
            The quote-word-quote-colon shape deliberately does NOT match a subscript
            (v["vehicle_class"]) or a comprehension key (v["vehicle_id"]: ...), because
            a `]` sits between the closing quote and the colon in both.
        #>
        param([Parameter(Mandatory)][string]$Source)
        $keys = [System.Collections.Generic.List[string]]::new()
        foreach ($match in [regex]::Matches($Source, '"(?<key>\w+)"\s*:')) {
            $key = $match.Groups['key'].Value
            if (-not $keys.Contains($key)) { $keys.Add($key) }
        }
        return @($keys)
    }

    function Get-GeneratorTableColumn {
        <# Column names per table, read straight out of the generator source. #>
        param(
            [Parameter(Mandatory)][string]$BuildPath,
            [Parameter(Mandatory)][string]$PoolsPath
        )
        $build = Get-Content -LiteralPath $BuildPath -Raw -Encoding utf8
        $pools = Get-Content -LiteralPath $PoolsPath -Raw -Encoding utf8

        $functions = [ordered]@{
            launches          = 'gen_launches'
            scrubs            = 'gen_scrubs'
            vehicles          = 'gen_vehicles'
            telemetry_summary = 'gen_telemetry'
            parts             = 'gen_parts'
            suppliers         = 'gen_suppliers'
            work_orders       = 'gen_work_orders'
            cost_daily        = 'gen_cost_daily'
            findings_history  = 'gen_findings'
        }
        $columns = [ordered]@{}
        foreach ($entry in $functions.GetEnumerator()) {
            $columns[$entry.Key] = Get-DictLiteralKey -Source (Get-PythonRowLiteral -Source $build -FunctionName $entry.Value)
        }

        # pads is `return [dict(p) for p in P.PADS]`, so its shape lives in pools.PADS.
        $padsBlock = [regex]::Match($pools, '(?s)PADS\s*=\s*\[\s*\{(?<body>.*?)\}')
        if (-not $padsBlock.Success) { throw 'Could not find the PADS literal in the generator pools.' }
        $columns['pads'] = Get-DictLiteralKey -Source $padsBlock.Groups['body'].Value

        return $columns
    }

    $script:Ddl = Get-AllDdlTable -Path $script:SqlRoot
    $script:GeneratorColumns = Get-GeneratorTableColumn `
        -BuildPath (Join-Path -Path $script:GeneratorRoot -ChildPath 'build.py') `
        -PoolsPath (Join-Path -Path $script:GeneratorRoot -ChildPath 'pools.py')
}

AfterAll {
    Remove-Module 'seed-common' -Force -ErrorAction SilentlyContinue
}

Describe 'schema parity: the parsers themselves' {
    # A parity test that silently extracts nothing would pass forever. These assert the
    # extraction worked before anything is compared against it.

    It 'extracted a CREATE TABLE for schema_version plus all ten data tables' {
        @($script:Ddl.Keys) | Should -Contain 'schema_version'
        foreach ($table in $script:LoadOrder) {
            @($script:Ddl.Keys) | Should -Contain $table
        }
    }

    It 'extracted ten tables from the generator source, none of them empty' {
        @($script:GeneratorColumns.Keys).Count | Should -Be 10
        foreach ($entry in $script:GeneratorColumns.GetEnumerator()) {
            @($entry.Value).Count | Should -BeGreaterThan 4 -Because "table '$($entry.Key)' should have parsed more than four columns"
        }
    }

    It 'extracted the same total column count from the generators and the manifest' {
        $fromGenerators = (@($script:GeneratorColumns.Values) | ForEach-Object { @($_).Count } | Measure-Object -Sum).Sum
        $fromManifest = ($script:LoadOrder | ForEach-Object {
                @(Get-SeedColumnName -Table (Get-SeedTable -Manifest $script:Manifest -Name $_)).Count
            } | Measure-Object -Sum).Sum
        $fromGenerators | Should -Be $fromManifest
        $fromManifest | Should -BeGreaterThan 90
    }
}

Describe 'schema parity: generators -> manifest' {
    It 'covers exactly the ten generator tables, no more and no fewer' {
        @($script:LoadOrder | Sort-Object) | Should -Be @(@($script:GeneratorColumns.Keys) | Sort-Object)
    }

    It '<_> has the same columns, in the same order, as the generator emits' -ForEach @(
        'launches', 'scrubs', 'vehicles', 'pads', 'telemetry_summary',
        'parts', 'suppliers', 'work_orders', 'cost_daily', 'findings_history'
    ) {
        $expected = @($script:GeneratorColumns[$_])
        $actual = @(Get-SeedColumnName -Table (Get-SeedTable -Manifest $script:Manifest -Name $_))
        $actual | Should -Be $expected
    }

    It 'marks exactly the generator NULLABLE_COLUMNS as nullable, plus the structurally optional ones' {
        # NULLABLE_COLUMNS from data/generators/config.py - the messiness knob columns.
        $knobNullable = @(
            'launches.weather_delay_min', 'launches.insurance_value_musd',
            'scrubs.recycle_hours', 'telemetry_summary.data_dropout_s', 'parts.material'
        )
        # Nullable for structural reasons, not the NULL_RATE knob (a small vehicle has no
        # GTO capacity; an open work order has no closed date; and so on).
        $structuralNullable = @(
            'vehicles.gto_capacity_kg', 'vehicles.last_flight_year',
            'work_orders.launch_id', 'work_orders.closed_date', 'work_orders.disposition',
            'findings_history.cve_id', 'findings_history.closed_date'
        )
        $manifestNullable = foreach ($table in $script:LoadOrder) {
            foreach ($column in @((Get-SeedTable -Manifest $script:Manifest -Name $table)['columns'])) {
                if ($column['nullable']) { "$table.$($column['name'])" }
            }
        }
        @($manifestNullable | Sort-Object) | Should -Be @(($knobNullable + $structuralNullable) | Sort-Object)
    }
}

Describe 'schema parity: manifest -> DDL' {
    It '<_> exists in the DDL with exactly the manifest columns, in order' -ForEach @(
        'launches', 'scrubs', 'vehicles', 'pads', 'telemetry_summary',
        'parts', 'suppliers', 'work_orders', 'cost_daily', 'findings_history'
    ) {
        $manifestColumns = @(Get-SeedColumnName -Table (Get-SeedTable -Manifest $script:Manifest -Name $_))
        @($script:Ddl[$_].Keys) | Should -Be $manifestColumns
    }

    It '<_> declares the manifest SQL type for every column' -ForEach @(
        'launches', 'scrubs', 'vehicles', 'pads', 'telemetry_summary',
        'parts', 'suppliers', 'work_orders', 'cost_daily', 'findings_history'
    ) {
        $table = Get-SeedTable -Manifest $script:Manifest -Name $_
        foreach ($column in @($table['columns'])) {
            $declared = $script:Ddl[$_][$column['name']]
            $declared.Type | Should -Be ($column['sql_type'] -replace '\s+', '').ToUpperInvariant() `
                -Because "$_.$($column['name']) must match the manifest type"
        }
    }

    It '<_> declares the manifest nullability for every column' -ForEach @(
        'launches', 'scrubs', 'vehicles', 'pads', 'telemetry_summary',
        'parts', 'suppliers', 'work_orders', 'cost_daily', 'findings_history'
    ) {
        $table = Get-SeedTable -Manifest $script:Manifest -Name $_
        foreach ($column in @($table['columns'])) {
            $script:Ddl[$_][$column['name']].Nullable | Should -Be ([bool]$column['nullable']) `
                -Because "$_.$($column['name']) nullability must match the manifest"
        }
    }
}

Describe 'schema parity: DDL -> manifest (no orphan tables or columns)' {
    It 'defines no data table the manifest does not know about' {
        $known = @($script:LoadOrder) + @('schema_version')
        foreach ($table in @($script:Ddl.Keys)) {
            $known | Should -Contain $table -Because "dbo.$table is in the DDL but not in schema-manifest.json"
        }
    }

    It 'defines no column the manifest does not know about' {
        foreach ($table in $script:LoadOrder) {
            $manifestColumns = @(Get-SeedColumnName -Table (Get-SeedTable -Manifest $script:Manifest -Name $table))
            foreach ($column in @($script:Ddl[$table].Keys)) {
                $manifestColumns | Should -Contain $column -Because "dbo.$table.$column is in the DDL but not in the manifest"
            }
        }
    }
}

Describe 'schema parity: structure and ordering' {
    It 'names a ddl_file for every table, and the file exists' {
        foreach ($table in $script:LoadOrder) {
            $file = (Get-SeedTable -Manifest $script:Manifest -Name $table)['ddl_file']
            $file | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path -Path $script:SqlRoot -ChildPath $file) | Should -BeTrue
        }
    }

    It 'orders the DDL files so filename order is dependency order' {
        # Every FK target must be created by a lower-numbered file than its dependant.
        foreach ($table in $script:LoadOrder) {
            $entry = Get-SeedTable -Manifest $script:Manifest -Name $table
            foreach ($fk in @($entry['foreign_keys'])) {
                $parent = (Get-SeedTable -Manifest $script:Manifest -Name $fk['references'])['ddl_file']
                $parent | Should -BeLessThan $entry['ddl_file'] `
                    -Because "$table references $($fk['references']), so $parent must sort before $($entry['ddl_file'])"
            }
        }
    }

    It 'orders the load so every FK target is loaded before its dependant' {
        for ($i = 0; $i -lt $script:LoadOrder.Count; $i++) {
            $table = $script:LoadOrder[$i]
            foreach ($fk in @((Get-SeedTable -Manifest $script:Manifest -Name $table)['foreign_keys'])) {
                $parentIndex = $script:LoadOrder.IndexOf($fk['references'])
                $parentIndex | Should -BeLessThan $i -Because "$table must load after $($fk['references'])"
            }
        }
    }

    It 'declares every foreign key in the DDL that the manifest declares' {
        $sqlText = (Get-ChildItem -LiteralPath $script:SqlRoot -Filter '*.sql' -File |
                ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8 }) -join "`n"
        foreach ($table in $script:LoadOrder) {
            foreach ($fk in @((Get-SeedTable -Manifest $script:Manifest -Name $table)['foreign_keys'])) {
                $column = @($fk['columns'])[0]
                $pattern = "FOREIGN\s+KEY\s*\(\s*\[$column\]\s*\)\s*REFERENCES\s+dbo\.$($fk['references'])\b"
                $sqlText | Should -Match $pattern `
                    -Because "$table.$column -> $($fk['references']) is in the manifest and must be in the DDL"
            }
        }
    }

    It 'declares a primary key in the DDL for every table' {
        foreach ($table in $script:LoadOrder) {
            $file = Join-Path -Path $script:SqlRoot -ChildPath (Get-SeedTable -Manifest $script:Manifest -Name $table)['ddl_file']
            $key = @((Get-SeedTable -Manifest $script:Manifest -Name $table)['primary_key'])[0]
            (Get-Content -LiteralPath $file -Raw -Encoding utf8) |
                Should -Match "CONSTRAINT\s+PK_$table\s+PRIMARY\s+KEY\s+CLUSTERED\s*\(\s*\[$key\]\s*\)"
        }
    }
}

Describe 'schema parity: row counts match the Verifier' {
    It 'declares <_.Name> = <_.Value> rows' -ForEach @(
        @{ Name = 'launches'; Value = 1200 }
        @{ Name = 'scrubs'; Value = 475 }
        @{ Name = 'vehicles'; Value = 12 }
        @{ Name = 'pads'; Value = 11 }
        @{ Name = 'telemetry_summary'; Value = 1200 }
        @{ Name = 'parts'; Value = 300 }
        @{ Name = 'suppliers'; Value = 24 }
        @{ Name = 'work_orders'; Value = 800 }
        @{ Name = 'cost_daily'; Value = 4515 }
        @{ Name = 'findings_history'; Value = 420 }
    ) {
        (Get-SeedTable -Manifest $script:Manifest -Name $_.Name)['expected_rows'] | Should -Be $_.Value
    }

    It 'covers every table the Verifier counts, and no others' {
        @($script:LoadOrder | Sort-Object) | Should -Be @($script:VerifierCounts.Keys | Sort-Object)
    }

    It 'pins the generator seed at 20260822' {
        $script:Manifest['generator_seed'] | Should -Be 20260822
    }
}

Describe 'schema parity: planes' {
    It 'assigns every table to a known plane' {
        foreach ($table in $script:LoadOrder) {
            (Get-SeedTable -Manifest $script:Manifest -Name $table)['plane'] |
                Should -BeIn @('operational', 'reference', 'analytical-mirror')
        }
    }

    It 'keeps cost_daily an analytical mirror (the lakehouse is its system of record)' {
        # L6: Cost Management export -> storage -> Function -> lakehouse cost_daily.
        # If this ever flips to "operational", the L6 ingestion pipeline has been
        # re-pointed and the master plan needs re-reading, not this test relaxing.
        (Get-SeedTable -Manifest $script:Manifest -Name 'cost_daily')['plane'] | Should -Be 'analytical-mirror'
    }

    It 'keeps the three CRUD tables operational' {
        foreach ($table in @('launches', 'scrubs', 'work_orders')) {
            (Get-SeedTable -Manifest $script:Manifest -Name $table)['plane'] | Should -Be 'operational'
        }
    }
}
