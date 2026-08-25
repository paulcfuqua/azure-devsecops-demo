#Requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for the L5/L6 data-plane seed (schema manifest, generated-data
    reader, console status).

.DESCRIPTION
    Imported by data/seed/sql/sql-seed.psm1 and data/seed/lakehouse/lakehouse-seed.psm1
    so the manifest is parsed and validated in exactly one place. Everything here is
    pure or filesystem-read-only: no network, no cloud, no writes.

    The manifest (data/seed/schema-manifest.json) is the single source of truth for
    table names, column names, column ORDER, SQL types, nullability and expected row
    counts. The DDL is written to match it and a Pester test asserts the match in both
    directions, plus a third direction against the generator source itself.
#>

Set-StrictMode -Version Latest

$script:ManifestFileName = 'schema-manifest.json'

function Write-SeedStatus {
    <#
    .SYNOPSIS
        Console progress line. The seed is an operator-facing script; its output is the
        product, so this is Write-Host by design and mocked wholesale in tests.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Operator-facing seeding script; console progress output is the deliverable, and a stream that a caller could redirect away would hide a half-finished load.')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

function Get-MapValue {
    <#
    .SYNOPSIS
        Strict-mode-safe read of a key from a hashtable or a PSObject property bag.
    .DESCRIPTION
        ConvertFrom-Json -AsHashtable yields hashtables; ConvertFrom-Json without it
        yields PSCustomObjects; Pester fixtures hand back either. One reader copes with
        all three without tripping Set-StrictMode on a missing member.
    #>
    param(
        $InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-SeedManifestPath {
    <#
    .SYNOPSIS
        Absolute path to schema-manifest.json, resolved from this module, never the cwd.
    .OUTPUTS
        System.String
    #>
    param([string]$SeedRoot = '')
    if ([string]::IsNullOrWhiteSpace($SeedRoot)) { $SeedRoot = $PSScriptRoot }
    return (Join-Path -Path $SeedRoot -ChildPath $script:ManifestFileName)
}

function Get-SeedManifest {
    <#
    .SYNOPSIS
        Parse and validate data/seed/schema-manifest.json.
    .DESCRIPTION
        Validation is deliberately strict: a manifest that has drifted from the DDL or
        the generators must fail here, loudly, before a single row is written. A silent
        partial seed is the L5 failure mode this whole layer is trying to avoid.
    .PARAMETER Path
        Manifest path. Defaults to the one next to this module.
    #>
    param([string]$Path = '')
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-SeedManifestPath }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Seed manifest not found at '$Path'. It is the contract the DDL and both loaders are derived from; the seed cannot run without it."
    }

    $manifest = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $loadOrder = @(Get-MapValue -InputObject $manifest -Name 'load_order')
    $tables = Get-MapValue -InputObject $manifest -Name 'tables'
    if ($loadOrder.Count -eq 0 -or $null -eq $tables) {
        throw "Seed manifest '$Path' is missing 'load_order' or 'tables'."
    }

    $tableNames = @($tables.Keys)
    $missing = @($loadOrder | Where-Object { $_ -notin $tableNames })
    if ($missing.Count -gt 0) {
        throw "Seed manifest '$Path' lists $($missing -join ', ') in load_order but defines no such table(s)."
    }
    $unordered = @($tableNames | Where-Object { $_ -notin $loadOrder })
    if ($unordered.Count -gt 0) {
        throw "Seed manifest '$Path' defines $($unordered -join ', ') but leaves them out of load_order; load order must cover every table."
    }

    foreach ($name in $loadOrder) {
        $table = $tables[$name]
        $columns = @(Get-MapValue -InputObject $table -Name 'columns')
        if ($columns.Count -eq 0) {
            throw "Seed manifest '$Path': table '$name' declares no columns."
        }
        $expected = Get-MapValue -InputObject $table -Name 'expected_rows'
        if ($null -eq $expected -or [int]$expected -le 0) {
            throw "Seed manifest '$Path': table '$name' declares no positive expected_rows. Row counts are contract (L5 V5.3), not a hint."
        }
    }
    return $manifest
}

function Get-SeedTable {
    <#
    .SYNOPSIS
        The manifest entry for one table, or a throw naming the table.
    #>
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Name
    )
    $tables = Get-MapValue -InputObject $Manifest -Name 'tables'
    $table = Get-MapValue -InputObject $tables -Name $Name
    if ($null -eq $table) { throw "Seed manifest has no table named '$Name'." }
    return $table
}

function Get-SeedColumnName {
    <#
    .SYNOPSIS
        Ordered column names for a table, straight from the manifest.
    .OUTPUTS
        System.String[] - in generator order, which is also CSV header order.
    #>
    param([Parameter(Mandatory)]$Table)
    return @(@(Get-MapValue -InputObject $Table -Name 'columns') | ForEach-Object {
            Get-MapValue -InputObject $_ -Name 'name'
        })
}

function Get-GeneratedDataPath {
    <#
    .SYNOPSIS
        Resolve data/generated/, the gitignored output of `python -m generators build`.
    .DESCRIPTION
        Resolved relative to this module (data/seed/ -> data/generated/), never the cwd,
        because the L5 workflow invokes the seed from the repo root while a human runs
        it from data/seed/.
    #>
    param([string]$Path = '')
    if (-not [string]::IsNullOrWhiteSpace($Path)) { return $Path }
    return (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'generated')
}

function Test-GeneratedDataComplete {
    <#
    .SYNOPSIS
        Does every table in the manifest have both a .json and a .csv beside it?
    .DESCRIPTION
        Both formats are required because the two planes read different ones on purpose:
        Azure SQL loads from JSON (native null/true/false, no empty-string-vs-null
        ambiguity, no whitespace-trim risk on the deliberately dirty columns), and the
        Fabric lakehouse loads from CSV (the Load Table REST API accepts Csv or Parquet
        and the generators emit no Parquet).
    #>
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$DataPath
    )
    if (-not (Test-Path -LiteralPath $DataPath)) { return $false }
    foreach ($name in @(Get-MapValue -InputObject $Manifest -Name 'load_order')) {
        foreach ($extension in @('json', 'csv')) {
            $file = Join-Path -Path $DataPath -ChildPath "$name.$extension"
            if (-not (Test-Path -LiteralPath $file)) { return $false }
        }
    }
    return $true
}

function Get-SeedTableRow {
    <#
    .SYNOPSIS
        Read one table's generated JSON rows as hashtables, in generator order.
    .DESCRIPTION
        JSON, not CSV, and -AsHashtable: this is the fidelity decision behind the whole
        SQL loader. JSON carries native null, native true/false and unambiguous
        whitespace, so a null never arrives as an empty string and a deliberately dirty
        value ("  Titanium" / "Inconel ") is never trimmed on the way in.

        Row order is preserved exactly as generated. Nothing here filters, de-duplicates
        or coerces - the row count that comes out equals the row count on disk.
    #>
    param(
        [Parameter(Mandatory)][string]$DataPath,
        [Parameter(Mandatory)][string]$Name
    )
    $file = Join-Path -Path $DataPath -ChildPath "$Name.json"
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Generated data for table '$Name' not found at '$file'. Run ``python -m generators build`` from the repo's data/ directory."
    }
    $rows = @(Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)
    return $rows
}

Export-ModuleMember -Function @(
    'Write-SeedStatus',
    'Get-MapValue',
    'Get-SeedManifestPath',
    'Get-SeedManifest',
    'Get-SeedTable',
    'Get-SeedColumnName',
    'Get-GeneratedDataPath',
    'Test-GeneratedDataComplete',
    'Get-SeedTableRow'
)
