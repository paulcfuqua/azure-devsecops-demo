#Requires -Version 7.0
<#
.SYNOPSIS
    Azure SQL half of the L5/L6 data-plane seed: apply the DDL in data/seed/sql/, then
    load the ten generated tables.

.DESCRIPTION
    Every database call goes through ONE choke point, Invoke-SeedSqlCommand, which is
    what the Pester suite mocks - there is no second path to the database anywhere in
    this module. The module never authenticates by itself: the caller supplies a
    connection descriptor carrying an Entra access token (OIDC-derived in CI), exactly
    as infra/fabric/*.ps1 does with its bearer token.

    ROW-COUNT FIDELITY - the property the L5 audit checks (V5.3, +/- 0):
      * rows are read from the generated JSON, not the CSV, so a null is a null and not
        an empty string, a boolean is a boolean and not the text "True", and the
        deliberately dirty values ("  Titanium", "Inconel ") keep their whitespace;
      * loads are plain multi-row INSERTs in generator order - no MERGE, no
        `INSERT ... SELECT DISTINCT`, no `IGNORE_DUP_KEY`, nothing that could de-duplicate;
      * a reload wipes first (DELETE in reverse dependency order) and never appends, so a
        second run cannot double a table;
      * after each table the loaded count is read back and compared to the manifest's
        expected_rows; a mismatch throws instead of being reported as success.

    IDEMPOTENCY: the DDL is guarded statement by statement, and the load short-circuits
    when every table already holds exactly its expected row count. A second run is a
    no-op that issues counts and nothing else.

    -WhatIf: issues NO database calls at all, not even reads. Prerequisites are still
    checked (they are local), and the plan is printed. The alternative - probing row
    counts under -WhatIf - would fail on a database whose DDL has not been applied yet,
    which is precisely the state a dry run is most useful in.
#>

Set-StrictMode -Version Latest

# No -Force on a dependency import. -Force removes and re-imports seed-common, and the
# re-import lands in THIS module's scope - so a caller that had already imported
# seed-common for itself silently loses every command it exported.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'seed-common.psm1')

# Table and column names are interpolated into SQL text, so they are validated against
# this pattern first. The manifest is trusted-but-verified: a tampered or hand-edited
# manifest must not be able to smuggle SQL through an identifier.
$script:IdentifierPattern = '^[A-Za-z_][A-Za-z0-9_]{0,127}$'

function Assert-SqlIdentifier {
    <#
    .SYNOPSIS
        Reject any identifier that is not a plain unquoted-safe SQL name.
    .DESCRIPTION
        Table and column names reach the SQL text by interpolation, so the manifest is
        trusted but verified: a hand-edited or tampered manifest must not be able to
        smuggle SQL through an identifier.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    if ($Name -notmatch $script:IdentifierPattern) {
        throw "Refusing to build SQL around the identifier '$Name': it is not a plain [A-Za-z_][A-Za-z0-9_]* name. Check data/seed/schema-manifest.json."
    }
    return $Name
}

function Split-SqlBatch {
    <#
    .SYNOPSIS
        Split a .sql file on its GO batch separators.
    .DESCRIPTION
        GO is a client-side separator, not T-SQL - a server rejects it. Splitting here
        rather than relying on Invoke-Sqlcmd's own handling keeps the .sql files portable
        across sqlcmd, Invoke-Sqlcmd and a raw client, and makes the behaviour unit
        testable. Only a line that is nothing but GO (with optional whitespace or a
        trailing comment) separates; the word GO inside a statement or a string is left
        alone. Blank batches are dropped.

        The trailing \r? is load-bearing. In .NET multiline mode `$` matches immediately
        before a \n, so on a CRLF checkout - which is what these files are on Windows -
        the CR sits between GO and the anchor and the line does not match. The separator
        would then travel to the server inside the batch, and every DDL file would fail
        with "Could not find stored procedure 'GO'".
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Script)
    $batches = [regex]::Split($Script, '(?im)^[ \t]*GO[ \t]*(?:--[^\r\n]*)?[ \t]*\r?$')
    return @($batches | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
}

function ConvertTo-SqlLiteral {
    <#
    .SYNOPSIS
        One generated value -> one T-SQL literal, typed by the manifest.
    .DESCRIPTION
        Formatting is invariant-culture throughout: a seed run on a machine with a comma
        decimal separator must produce byte-identical SQL to one on a machine without.
        FLOAT uses the round-trip ('R') format so the literal reads back as exactly the
        IEEE double the generator produced. DECIMAL goes through [decimal], which never
        emits scientific notation - a float-formatted '4.2E+02' would be accepted by SQL
        Server as a float and silently converted, and money should not take that path.
        A DATE that is not ISO YYYY-MM-DD throws rather than being coerced.
    #>
    param(
        $Value,
        [Parameter(Mandatory)][string]$SqlType
    )
    if ($null -eq $Value) { return 'NULL' }
    $invariant = [cultureinfo]::InvariantCulture
    $base = (($SqlType -split '\(')[0]).Trim().ToUpperInvariant()

    switch ($base) {
        'BIT' {
            if ($Value -is [string]) {
                # Defensive: only the CSV renders booleans as text, but a fixture might.
                if ($Value -eq 'True') { return '1' }
                if ($Value -eq 'False') { return '0' }
                throw "Cannot read '$Value' as a BIT value."
            }
            if ([bool]$Value) { return '1' }
            return '0'
        }
        'INT' { return ([int64]$Value).ToString($invariant) }
        'BIGINT' { return ([int64]$Value).ToString($invariant) }
        'FLOAT' { return ([double]$Value).ToString('R', $invariant) }
        'DECIMAL' { return ([decimal]$Value).ToString($invariant) }
        'NUMERIC' { return ([decimal]$Value).ToString($invariant) }
        'DATE' {
            $text = "$Value"
            if ($text -notmatch '^\d{4}-\d{2}-\d{2}$') {
                throw "Cannot read '$text' as a DATE: the generators emit ISO YYYY-MM-DD and nothing else."
            }
            return "'$text'"
        }
        default {
            # NVARCHAR / NCHAR and anything else textual. Doubling the single quote is the
            # whole escape rule for a T-SQL string literal; N'' keeps it Unicode.
            return "N'" + ("$Value").Replace("'", "''") + "'"
        }
    }
}

function New-SqlInsertStatement {
    <#
    .SYNOPSIS
        Build one multi-row INSERT for a chunk of rows. Pure function - no database, no
        side effects, fully unit-testable.
    .DESCRIPTION
        Columns are named explicitly and in manifest order, so the statement is immune to
        a column being added in the middle of the table later. Values are inlined
        literals rather than parameters because Invoke-Sqlcmd's parameter surface
        (-Variable) is string substitution, not real parameterisation, and would be a
        worse escape story than ConvertTo-SqlLiteral.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure builder: returns a SQL string and changes no state anywhere. The state change happens in Invoke-SeedSqlCommand, which the caller gates with ShouldProcess.')]
    param(
        [Parameter(Mandatory)][string]$TableName,
        [Parameter(Mandatory)]$Table,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Row
    )
    Assert-SqlIdentifier -Name $TableName | Out-Null
    if ($Row.Count -eq 0) { return '' }

    $columns = @(Get-MapValue -InputObject $Table -Name 'columns')
    $names = @($columns | ForEach-Object { Assert-SqlIdentifier -Name (Get-MapValue -InputObject $_ -Name 'name') })
    $types = @($columns | ForEach-Object { Get-MapValue -InputObject $_ -Name 'sql_type' })
    $columnList = (($names | ForEach-Object { "[$_]" }) -join ', ')

    # $sourceRow, deliberately not $row: PowerShell variable names are case-insensitive,
    # so `foreach ($row in $Row)` would rebind the [object[]] parameter on every
    # iteration and re-coerce each element into a one-element array - every column would
    # then read as NULL and the whole table would load as blanks.
    $tuples = foreach ($sourceRow in $Row) {
        $values = for ($i = 0; $i -lt $names.Count; $i++) {
            ConvertTo-SqlLiteral -Value (Get-MapValue -InputObject $sourceRow -Name $names[$i]) -SqlType $types[$i]
        }
        '(' + ($values -join ', ') + ')'
    }
    return "INSERT INTO dbo.[$TableName] ($columnList) VALUES" + [Environment]::NewLine + (($tuples) -join ("," + [Environment]::NewLine)) + ';'
}

function New-SqlConnectionDescriptor {
    <#
    .SYNOPSIS
        Bundle the connection inputs. Plain data - no connection is opened here.
    .DESCRIPTION
        Empty values are ACCEPTED on purpose. Validation lives in exactly one place,
        Assert-SqlSeedPrerequisite, which names the missing parameter and offers
        `-Target lakehouse` as the way past it. Marking these Mandatory-and-non-empty
        here would instead surface PowerShell's "Cannot bind argument to parameter
        'ServerInstance' because it is an empty string" - which is precisely what a
        caller who forgot the parameter does not need to read.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure builder: returns an in-memory descriptor. Nothing is connected, opened or changed.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'AccessToken is a short-lived Entra bearer token supplied by the caller (OIDC in CI), handled the same way infra/fabric/fabric-api.psm1 handles its -Token. It is never persisted, logged or defaulted, and the repo has no SecureString path for OIDC tokens.')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ServerInstance,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Database,
        [string]$AccessToken = ''
    )
    return @{
        ServerInstance = $ServerInstance
        Database       = $Database
        AccessToken    = $AccessToken
    }
}

function Invoke-SeedSqlCommand {
    <#
    .SYNOPSIS
        Single choke point for every Azure SQL call (mocked in tests).
    .DESCRIPTION
        Delegates to Invoke-Sqlcmd from the SqlServer module, resolved at call time so a
        missing module produces the actionable message in Assert-SqlSeedPrerequisite
        rather than a CommandNotFoundException from inside a load loop.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Query,
        [int]$TimeoutSeconds = 300
    )
    $sqlcmd = Get-Command -Name 'Invoke-Sqlcmd' -ErrorAction SilentlyContinue
    if (-not $sqlcmd) {
        throw 'Invoke-Sqlcmd is not available. Install the SqlServer module (Install-Module SqlServer -Scope CurrentUser -MinimumVersion 22.0.0) - version 22 or later is required for -AccessToken.'
    }
    $arguments = @{
        ServerInstance = (Get-MapValue -InputObject $Connection -Name 'ServerInstance')
        Database       = (Get-MapValue -InputObject $Connection -Name 'Database')
        Query          = $Query
        QueryTimeout   = $TimeoutSeconds
        ErrorAction    = 'Stop'
    }
    $token = Get-MapValue -InputObject $Connection -Name 'AccessToken'
    if (-not [string]::IsNullOrWhiteSpace($token)) { $arguments['AccessToken'] = $token }
    return & $sqlcmd @arguments
}

function Get-QueryScalar {
    <#
    .SYNOPSIS
        First column of the first row of a query result, whatever shape the client used.
    .DESCRIPTION
        Invoke-Sqlcmd hands back a DataRow, a Pester fixture hands back a hashtable, and
        a bare scalar is possible too; one reader copes with all three.
    #>
    param(
        $Result,
        [Parameter(Mandatory)][string]$Name
    )
    $rows = @($Result)
    if ($rows.Count -eq 0) { return $null }
    $first = $rows[0]
    if ($null -eq $first) { return $null }
    $value = Get-MapValue -InputObject $first -Name $Name
    if ($null -ne $value) { return $value }
    if ($first -is [System.ValueType] -or $first -is [string]) { return $first }
    return $null
}

function Assert-SqlSeedPrerequisite {
    <#
    .SYNOPSIS
        Fail before the first write, with a message that says what to do.
    .DESCRIPTION
        Everything checked here is local: no connection is opened, so this runs
        identically under -WhatIf. A half-seeded database is the expensive failure; an
        early throw is the cheap one.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$DdlPath,
        [Parameter(Mandatory)][string]$DataPath,
        [Parameter(Mandatory)]$Manifest
    )
    $server = Get-MapValue -InputObject $Connection -Name 'ServerInstance'
    $database = Get-MapValue -InputObject $Connection -Name 'Database'
    if ([string]::IsNullOrWhiteSpace($server)) {
        throw 'No Azure SQL server was supplied. Pass -SqlServerInstance <name>.database.windows.net (the L6 deployment output; CLAUDE.md naming: mls-ops-demo-sql) or run with -Target lakehouse.'
    }
    if ([string]::IsNullOrWhiteSpace($database)) {
        throw "No Azure SQL database was supplied for server '$server'. Pass -SqlDatabase <name>."
    }
    if (-not (Get-Command -Name 'Invoke-Sqlcmd' -ErrorAction SilentlyContinue)) {
        throw 'The SqlServer PowerShell module is not installed, so the SQL half of the seed cannot run. Install-Module SqlServer -Scope CurrentUser -MinimumVersion 22.0.0 (version 22+ is required for -AccessToken), or run with -Target lakehouse.'
    }
    if (-not (Test-Path -LiteralPath $DdlPath)) {
        throw "DDL directory '$DdlPath' does not exist. It ships with the repo at data/seed/sql/."
    }
    $ddlFiles = @(Get-ChildItem -LiteralPath $DdlPath -Filter '*.sql' -File)
    if ($ddlFiles.Count -eq 0) {
        throw "DDL directory '$DdlPath' contains no .sql files. Nothing would be created and the load would fail table by table."
    }
    if (-not (Test-GeneratedDataComplete -Manifest $Manifest -DataPath $DataPath)) {
        throw "Generated dataset is missing or incomplete at '$DataPath'. Run ``python -m generators build`` from the repo's data/ directory (seed 20260822), or let data/seed/seed.ps1 run it for you."
    }
    if ([string]::IsNullOrWhiteSpace((Get-MapValue -InputObject $Connection -Name 'AccessToken'))) {
        Write-SeedStatus 'No -SqlAccessToken supplied; Invoke-Sqlcmd will fall back to its own authentication. In CI this is a misconfiguration - the token comes from the OIDC login.' -Color Yellow
    }
}

function Install-SeedSchema {
    <#
    .SYNOPSIS
        Apply every .sql in the DDL directory, in filename order, one batch at a time.
    .DESCRIPTION
        Filename order IS dependency order (see data/seed/sql/README.md): the zero-padded
        prefixes sort lexicographically into a sequence with no forward references, so
        the whole schema applies in one pass. Each file is individually gated by
        ShouldProcess, so -WhatIf lists exactly what would run and calls nothing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$DdlPath,
        [int]$TimeoutSeconds = 300
    )
    $files = @(Get-ChildItem -LiteralPath $DdlPath -Filter '*.sql' -File | Sort-Object -Property Name)
    $applied = @()
    foreach ($file in $files) {
        $batches = @(Split-SqlBatch -Script (Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8))
        if (-not $PSCmdlet.ShouldProcess($file.Name, "Apply DDL ($($batches.Count) batch(es)) to Azure SQL")) {
            continue
        }
        foreach ($batch in $batches) {
            Invoke-SeedSqlCommand -Connection $Connection -Query $batch -TimeoutSeconds $TimeoutSeconds | Out-Null
        }
        Write-SeedStatus "  applied $($file.Name) ($($batches.Count) batch(es))" -Color Gray
        $applied += $file.Name
    }
    return $applied
}

function Get-SeedTableRowCount {
    <#
    .SYNOPSIS
        COUNT_BIG(*) for one table.
    .DESCRIPTION
        COUNT_BIG rather than COUNT so a future larger table cannot overflow the counter
        that the L5 row-count contract is checked against.
    .OUTPUTS
        System.Int64
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$TableName,
        [int]$TimeoutSeconds = 300
    )
    Assert-SqlIdentifier -Name $TableName | Out-Null
    $result = Invoke-SeedSqlCommand -Connection $Connection `
        -Query "SELECT COUNT_BIG(*) AS row_count FROM dbo.[$TableName];" -TimeoutSeconds $TimeoutSeconds
    $value = Get-QueryScalar -Result $result -Name 'row_count'
    if ($null -eq $value) { return 0 }
    return [int64]$value
}

function Clear-SeedTable {
    <#
    .SYNOPSIS
        Empty the seeded tables in REVERSE dependency order.
    .DESCRIPTION
        DELETE, not TRUNCATE: TRUNCATE is refused on a table referenced by a foreign key,
        and the whole point of the FK graph is that it stays enforced during a reseed. No
        constraint is ever disabled here - a reseed that needs NOCHECK to succeed is a
        reseed that has already lost referential integrity.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string[]]$TableName,
        [int]$TimeoutSeconds = 300
    )
    $cleared = @()
    foreach ($table in $TableName) {
        Assert-SqlIdentifier -Name $table | Out-Null
        if (-not $PSCmdlet.ShouldProcess($table, 'Delete all rows before reload')) { continue }
        Invoke-SeedSqlCommand -Connection $Connection -Query "DELETE FROM dbo.[$table];" -TimeoutSeconds $TimeoutSeconds | Out-Null
        $cleared += $table
    }
    return $cleared
}

function Import-SeedTable {
    <#
    .SYNOPSIS
        Load one table's generated rows, then read the count back and prove it.
    .DESCRIPTION
        Rows are inserted in generator order in chunks of -BatchSize. The read-back is
        not decoration: it is the only thing standing between a partially applied batch
        and an L5 audit that reports success (L5 failure mode 3, "row counts off").
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$TableName,
        [Parameter(Mandatory)]$Table,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Row,
        [int]$BatchSize = 250,
        [int]$TimeoutSeconds = 300
    )
    Assert-SqlIdentifier -Name $TableName | Out-Null
    $expected = [int](Get-MapValue -InputObject $Table -Name 'expected_rows')
    if ($Row.Count -ne $expected) {
        throw "Generated data for '$TableName' holds $($Row.Count) row(s) but the seed contract expects $expected. Either the generators drifted from seed 20260822 or data/generated/ is stale - regenerate rather than loading this."
    }
    if (-not $PSCmdlet.ShouldProcess($TableName, "Load $($Row.Count) row(s) into Azure SQL")) {
        return [pscustomobject]@{ Table = $TableName; Loaded = 0; Expected = $expected; Verified = $false }
    }

    for ($offset = 0; $offset -lt $Row.Count; $offset += $BatchSize) {
        $take = [Math]::Min($BatchSize, $Row.Count - $offset)
        $chunk = @($Row[$offset..($offset + $take - 1)])
        $statement = New-SqlInsertStatement -TableName $TableName -Table $Table -Row $chunk
        Invoke-SeedSqlCommand -Connection $Connection -Query $statement -TimeoutSeconds $TimeoutSeconds | Out-Null
    }

    $loaded = Get-SeedTableRowCount -Connection $Connection -TableName $TableName -TimeoutSeconds $TimeoutSeconds
    if ($loaded -ne $expected) {
        throw "Loaded '$TableName' but the table now holds $loaded row(s) instead of $expected. The seed is INCOMPLETE - wipe and reseed (data/seed/seed.ps1 -Force); do not repair in place."
    }
    Write-SeedStatus "  $TableName".PadRight(26) -Color Gray
    return [pscustomobject]@{ Table = $TableName; Loaded = $loaded; Expected = $expected; Verified = $true }
}

function Invoke-SqlSeed {
    <#
    .SYNOPSIS
        Apply the DDL and load the ten tables into the Azure SQL operational database.
    .DESCRIPTION
        Idempotent. When every table already holds exactly its expected row count the
        load is skipped entirely and the run reports SkippedAlreadySeeded - that is the
        "second run no-ops" contract. -Force wipes and reloads unconditionally, which is
        the L5 playbook's wipe-and-reseed remediation.

        Under -WhatIf no database call is made at all - not even a count. See the module
        header for why.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$DataPath,
        [string]$DdlPath = '',
        [int]$BatchSize = 250,
        [int]$TimeoutSeconds = 300,
        [switch]$Force
    )
    if ([string]::IsNullOrWhiteSpace($DdlPath)) { $DdlPath = $PSScriptRoot }
    $loadOrder = @(Get-MapValue -InputObject $Manifest -Name 'load_order')

    Assert-SqlSeedPrerequisite -Connection $Connection -DdlPath $DdlPath -DataPath $DataPath -Manifest $Manifest

    Write-SeedStatus "Azure SQL: $(Get-MapValue -InputObject $Connection -Name 'ServerInstance') / $(Get-MapValue -InputObject $Connection -Name 'Database')" -Color Cyan
    Write-SeedStatus 'Applying DDL (data/seed/sql, filename order = dependency order)...' -Color Cyan
    $applied = @(Install-SeedSchema -Connection $Connection -DdlPath $DdlPath -TimeoutSeconds $TimeoutSeconds)

    if ($WhatIfPreference) {
        Write-SeedStatus "(-WhatIf) Would load $($loadOrder.Count) table(s) in order: $($loadOrder -join ', '). No database call was made." -Color Yellow
        return [pscustomobject]@{
            AppliedDdl            = $applied
            Loaded                = @()
            SkippedAlreadySeeded  = $false
            WhatIf                = $true
        }
    }

    # ---- is it already seeded? -------------------------------------------------------
    $current = @{}
    foreach ($name in $loadOrder) {
        $current[$name] = Get-SeedTableRowCount -Connection $Connection -TableName $name -TimeoutSeconds $TimeoutSeconds
    }
    $alreadySeeded = $true
    foreach ($name in $loadOrder) {
        $expected = [int](Get-MapValue -InputObject (Get-SeedTable -Manifest $Manifest -Name $name) -Name 'expected_rows')
        if ($current[$name] -ne $expected) { $alreadySeeded = $false }
    }
    if ($alreadySeeded -and -not $Force) {
        Write-SeedStatus "All $($loadOrder.Count) tables already hold their expected row counts - nothing to load." -Color Green
        return [pscustomobject]@{
            AppliedDdl           = $applied
            Loaded               = @()
            SkippedAlreadySeeded = $true
            WhatIf               = $false
        }
    }

    # ---- wipe (reverse dependency order), then load (forward) ------------------------
    $occupied = @($loadOrder | Where-Object { $current[$_] -gt 0 })
    if ($occupied.Count -gt 0) {
        $reverse = @($loadOrder | Where-Object { $_ -in $occupied })
        [array]::Reverse($reverse)
        Write-SeedStatus "Clearing $($reverse.Count) table(s) before reload (reverse dependency order)..." -Color Yellow
        Clear-SeedTable -Connection $Connection -TableName $reverse -TimeoutSeconds $TimeoutSeconds -Confirm:$false | Out-Null
    }

    Write-SeedStatus "Loading $($loadOrder.Count) tables..." -Color Cyan
    $loaded = foreach ($name in $loadOrder) {
        $table = Get-SeedTable -Manifest $Manifest -Name $name
        $rows = @(Get-SeedTableRow -DataPath $DataPath -Name $name)
        Import-SeedTable -Connection $Connection -TableName $name -Table $table -Row $rows `
            -BatchSize $BatchSize -TimeoutSeconds $TimeoutSeconds -Confirm:$false
    }

    $total = ($loaded | Measure-Object -Property Loaded -Sum).Sum
    Write-SeedStatus "Azure SQL seeded: $($loadOrder.Count) tables, $total rows, all counts verified." -Color Green
    return [pscustomobject]@{
        AppliedDdl           = $applied
        Loaded               = @($loaded)
        SkippedAlreadySeeded = $false
        WhatIf               = $false
    }
}

Export-ModuleMember -Function @(
    'Assert-SqlIdentifier',
    'Split-SqlBatch',
    'ConvertTo-SqlLiteral',
    'New-SqlInsertStatement',
    'New-SqlConnectionDescriptor',
    'Invoke-SeedSqlCommand',
    'Get-QueryScalar',
    'Assert-SqlSeedPrerequisite',
    'Install-SeedSchema',
    'Get-SeedTableRowCount',
    'Clear-SeedTable',
    'Import-SeedTable',
    'Invoke-SqlSeed'
)
