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

    IDEMPOTENCY: the DDL is guarded statement by statement and is ALWAYS (re)applied; the
    load short-circuits when every table already holds exactly its expected row count. A
    second run against an already-seeded estate issues the DDL again (free - every
    statement is a no-op) plus counts, and nothing else.

    -SchemaOnly (F20) goes further: apply the DDL and stop - no row-count probe either.
    That is the post-L7 grant pass for data/seed/sql/900-contained-users.sql, which needs
    neither a row count nor data/generated/ to exist. See Invoke-SqlSeed.

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
    .PARAMETER SchemaOnly
        Skip the generated-dataset check (F20: the post-L7 grant pass applies
        data/seed/sql/*.sql only - no table is loaded, so data/generated/ is
        irrelevant to it and must not be required). See Invoke-SqlSeed.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$DdlPath,
        [Parameter(Mandatory)][string]$DataPath,
        [Parameter(Mandatory)]$Manifest,
        [switch]$SchemaOnly
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
    if (-not $SchemaOnly -and -not (Test-GeneratedDataComplete -Manifest $Manifest -DataPath $DataPath)) {
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

function Assert-SqlPrincipalName {
    <#
    .SYNOPSIS
        Reject any database-principal name that is not a plain estate resource name.
    .DESCRIPTION
        Assert-SqlIdentifier is deliberately stricter than this and CANNOT be reused:
        it forbids hyphens, and every workload identity in this estate is named
        <prefix>-<role>-<env>-<type> (CLAUDE.md, Naming and tagging). The name reaches
        the SQL text inside [brackets], so the thing that must be impossible is a `]`
        closing them early; restricting to [A-Za-z0-9_-] makes that unreachable rather
        than escaped.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
    if ($Name -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,127}$') {
        throw "Refusing to build SQL around the principal name '$Name': it is not a plain [A-Za-z][A-Za-z0-9_-]* estate resource name."
    }
    return $Name
}

function Get-SeedWorkloadUser {
    <#
    .SYNOPSIS
        What the database currently holds for one principal name: its type and the GUID
        its SID decodes to, or $null for both when no such principal exists.
    .DESCRIPTION
        DATALENGTH guards the conversion: a SQL-authenticated principal carries a
        variable-length SID and CONVERT(UNIQUEIDENTIFIER, ...) would throw on it, which
        would report "the database is broken" for "this name belongs to a different kind
        of principal".
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$PrincipalName,
        [int]$TimeoutSeconds = 300
    )
    Assert-SqlPrincipalName -Name $PrincipalName | Out-Null
    $query = @"
SET NOCOUNT ON;
SELECT TOP (1)
    [type_desc] AS type_desc,
    CASE WHEN DATALENGTH([sid]) = 16 THEN CONVERT(CHAR(36), CONVERT(UNIQUEIDENTIFIER, [sid])) END AS sid_guid
FROM sys.database_principals
WHERE [name] = N'$PrincipalName';
"@
    $result = Invoke-SeedSqlCommand -Connection $Connection -Query $query -TimeoutSeconds $TimeoutSeconds
    $rows = @($result)
    if ($rows.Count -eq 0 -or $null -eq $rows[0]) {
        return [pscustomobject]@{ Exists = $false; TypeDescription = ''; SidGuid = '' }
    }
    return [pscustomobject]@{
        Exists          = $true
        TypeDescription = "$(Get-QueryScalar -Result $result -Name 'type_desc')".Trim()
        SidGuid         = "$(Get-QueryScalar -Result $result -Name 'sid_guid')".Trim()
    }
}

function Set-SeedWorkloadUser {
    <#
    .SYNOPSIS
        Create - or repair - the contained-database user for one workload managed
        identity, WITHOUT asking Microsoft Graph, and then prove it took.

    .DESCRIPTION
        THIS EXISTS BECAUSE `CREATE USER ... FROM EXTERNAL PROVIDER` CANNOT SURVIVE A
        REBUILD, AND NOBODY NOTICED FOR AS LONG AS NOBODY REBUILT (F172).

        FROM EXTERNAL PROVIDER makes the SQL engine resolve the principal in Microsoft
        Graph. An application cannot impersonate another application, so under CI the
        engine falls back to THE SQL SERVER'S OWN managed identity, which must therefore
        hold directory read - the Entra "Directory Readers" role. That role assignment was
        a G0 step documented as "One assignment, once per tenant".

        It is not once per tenant. The server is created by L6 in `mls-rg-data`, teardown
        deletes that resource group, and the server's SYSTEM-ASSIGNED identity dies with
        it and comes back with a NEW principal id. Entra removes the dangling assignment
        along with the deleted service principal. So the grant silently stops existing the
        first time the estate is rebuilt - which is the one thing this demo exists to do.

        Read on 2026-09-03, after the re-baseline rebuild: the directory audit log records
        `mls-ops-demo-sql` added to Directory Readers on 2026-09-01T12:23:23Z for a service
        principal that no longer exists, the current server identity holds zero directory
        role assignments, and the Directory Readers role has zero members. Four layers
        later data-api answered `Login failed for user '<token-identified principal>'` and
        V7.6 went red.

        SO THE GRANT NO LONGER ASKS GRAPH ANYTHING. Azure SQL stores an Entra principal's
        SID, and for an application - a service principal or a managed identity - that SID
        is its APPLICATION (CLIENT) ID, not its object id. Supplying it explicitly is the
        documented route for exactly this case, and it needs no server identity, no
        Directory Readers, and no tenant-level privilege anywhere. The estate rebuilds
        itself with no human in the loop.

        THE CLIENT-ID-VERSUS-OBJECT-ID CHOICE IS THE ONE CONSTANT HERE THAT NAMES
        SOMETHING IN ANOTHER SYSTEM, and this function's own read-back CANNOT verify it -
        comparing the SID we just wrote against the value we wrote it from is a mirror,
        not a test (CLAUDE.md). What settles it is L7's V7.6, which asks the running
        data-api for a row over a real login: a wrong SID leaves the criterion red. The
        read-back below is for a different, real failure - a user of this name left behind
        by a PREVIOUS identity, whose SID belongs to a principal that no longer exists.
        The old check asked only whether a principal of this name existed and would have
        accepted exactly that.

    .PARAMETER ClientId
        The managed identity's clientId (`az identity show --query clientId`), NOT its
        principalId.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$PrincipalName,
        [Parameter(Mandatory)][string]$ClientId,
        [string[]]$DatabaseRole = @('db_datareader'),
        [int]$TimeoutSeconds = 300
    )
    Assert-SqlPrincipalName -Name $PrincipalName | Out-Null
    foreach ($role in $DatabaseRole) { Assert-SqlIdentifier -Name $role | Out-Null }
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($ClientId, [ref]$parsed)) {
        throw "Refusing to create the contained user '$PrincipalName': '$ClientId' is not a GUID. This parameter takes the managed identity's clientId (az identity show --query clientId), not its name or its principalId."
    }
    $wanted = $parsed.ToString()

    $before = Get-SeedWorkloadUser -Connection $Connection -PrincipalName $PrincipalName -TimeoutSeconds $TimeoutSeconds
    $action = 'created'
    if ($before.Exists -and $before.SidGuid -eq $wanted) {
        $action = 'already correct'
    }
    elseif ($before.Exists) {
        # A NAME COLLISION WITH A DEAD IDENTITY IS THE NORMAL RE-RUN CASE, NOT A CRISIS.
        # A user-assigned identity destroyed with its resource group and recreated gets a
        # new clientId under the same name, so a database that outlived it holds a user
        # whose SID nobody can log in as. Dropping a contained database user is
        # RG-scoped - the gate-free half of the teardown contract - and leaving it in
        # place would block the grant permanently while every name-based check passed.
        if ($PSCmdlet.ShouldProcess($PrincipalName, "DROP the existing contained user (SID '$($before.SidGuid)' does not match clientId '$wanted')")) {
            Write-SeedStatus "  '$PrincipalName' exists with SID '$($before.SidGuid)', which is not this identity's clientId '$wanted' - dropping and recreating it (a previous identity of the same name)." -Color Yellow
            Invoke-SeedSqlCommand -Connection $Connection -Query "DROP USER [$PrincipalName];" -TimeoutSeconds $TimeoutSeconds | Out-Null
        }
        $action = 'recreated'
    }

    if ($action -ne 'already correct') {
        # T-SQL DOES THE BYTE ORDER, NOT POWERSHELL. CAST(uniqueidentifier AS varbinary(16))
        # produces exactly the layout Azure SQL stores, so there is no hand-rolled encoding
        # to get subtly wrong, and CONVERT(..., 1) renders it as the 0x literal CREATE USER
        # wants. $wanted came out of [guid]::TryParse, so it cannot carry SQL.
        $create = @"
DECLARE @sid VARBINARY(16) = CAST(CAST(N'$wanted' AS UNIQUEIDENTIFIER) AS VARBINARY(16));
DECLARE @cmd NVARCHAR(MAX) = N'CREATE USER [$PrincipalName] WITH SID = ' + CONVERT(NVARCHAR(64), @sid, 1) + N', TYPE = E;';
EXEC sp_executesql @cmd;
"@
        if ($PSCmdlet.ShouldProcess($PrincipalName, "CREATE USER ... WITH SID (clientId $wanted), TYPE = E")) {
            Invoke-SeedSqlCommand -Connection $Connection -Query $create -TimeoutSeconds $TimeoutSeconds | Out-Null
        }
    }

    foreach ($role in $DatabaseRole) {
        $addMember = @"
IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members AS rm
    JOIN sys.database_principals AS r ON r.[principal_id] = rm.[role_principal_id]
    JOIN sys.database_principals AS m ON m.[principal_id] = rm.[member_principal_id]
    WHERE r.[name] = N'$role' AND m.[name] = N'$PrincipalName'
)
    ALTER ROLE [$role] ADD MEMBER [$PrincipalName];
"@
        if ($PSCmdlet.ShouldProcess($PrincipalName, "ALTER ROLE [$role] ADD MEMBER")) {
            Invoke-SeedSqlCommand -Connection $Connection -Query $addMember -TimeoutSeconds $TimeoutSeconds | Out-Null
        }
    }

    # VERIFY, DO NOT ANNOUNCE (F112). Every statement above can run without throwing and
    # leave nothing behind; the only report worth making is one the database agreed to.
    if (-not $PSCmdlet.ShouldProcess($PrincipalName, 'read back the contained user and its role membership')) {
        return [pscustomobject]@{ PrincipalName = $PrincipalName; ClientId = $wanted; Action = 'skipped (-WhatIf)'; Role = @($DatabaseRole) }
    }
    $after = Get-SeedWorkloadUser -Connection $Connection -PrincipalName $PrincipalName -TimeoutSeconds $TimeoutSeconds
    if (-not $after.Exists) {
        throw "The contained user '$PrincipalName' does not exist after CREATE USER ... WITH SID ran without throwing. Nothing here asked Microsoft Graph, so this is not the Directory Readers problem (F172): check that the connection is the database data-api reads and that the caller is a Microsoft Entra admin on the server."
    }
    if ($after.SidGuid -ne $wanted) {
        throw "The contained user '$PrincipalName' exists with SID '$($after.SidGuid)' but this identity's clientId is '$wanted'. A login presenting the identity's token will be refused. Drop the user and re-run, or check that -ClientId was given the clientId rather than the principalId."
    }
    foreach ($role in $DatabaseRole) {
        $memberQuery = @"
SET NOCOUNT ON;
SELECT COUNT_BIG(*) AS n
FROM sys.database_role_members AS rm
JOIN sys.database_principals AS r ON r.[principal_id] = rm.[role_principal_id]
JOIN sys.database_principals AS m ON m.[principal_id] = rm.[member_principal_id]
WHERE r.[name] = N'$role' AND m.[name] = N'$PrincipalName';
"@
        $count = Get-QueryScalar -Result (Invoke-SeedSqlCommand -Connection $Connection -Query $memberQuery -TimeoutSeconds $TimeoutSeconds) -Name 'n'
        if ([int64]$count -lt 1) {
            throw "The contained user '$PrincipalName' exists with the right SID but is not a member of [$role], so every SELECT it issues will be denied."
        }
    }
    Write-SeedStatus "  contained user '$PrincipalName' $action and VERIFIED: SID = clientId $wanted, member of $($DatabaseRole -join ', ')." -Color Green
    return [pscustomobject]@{ PrincipalName = $PrincipalName; ClientId = $wanted; Action = $action; Role = @($DatabaseRole) }
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

        The DDL in data/seed/sql/ is applied UNCONDITIONALLY, before any of the above -
        every file there is individually guarded (IF NOT EXISTS / sys.database_principals),
        so a replay is free, and gating it behind the row-count check would mean a DDL-only
        fix (a grant, an index, a new guarded statement) never lands on a re-run against an
        already-seeded estate.

        Under -WhatIf no database call is made at all - not even a count. See the module
        header for why.
    .PARAMETER SchemaOnly
        F20 (compliance/findings/2026-08-26-prepublication-review.md#f20): apply the DDL
        and return - no row-count probe, no wipe, no load, and (via
        Assert-SqlSeedPrerequisite -SchemaOnly) no requirement that data/generated/
        exists. This is the post-L7 invocation that applies the data-api contained-user
        grant once that identity exists: a grant is idempotent DDL, not a data load, so it
        needs none of the machinery a reseed does. Mutually exclusive with -Force in
        spirit (there is no data to wipe or reload here); -Force is ignored when
        -SchemaOnly is set.
    .PARAMETER WorkloadUserName
        Contained-database user to create for a workload managed identity, with
        -WorkloadUserClientId. ABSENT IS THE NORMAL L6 CASE: L6 runs before L7 exists to
        create the identity, so it passes neither and no grant is attempted. Supplying
        one without the other is refused rather than half-done.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$DataPath,
        [string]$DdlPath = '',
        [int]$BatchSize = 250,
        [int]$TimeoutSeconds = 300,
        [string]$WorkloadUserName = '',
        [string]$WorkloadUserClientId = '',
        [switch]$Force,
        [switch]$SchemaOnly
    )
    if ([string]::IsNullOrWhiteSpace($DdlPath)) { $DdlPath = $PSScriptRoot }
    $loadOrder = @(Get-MapValue -InputObject $Manifest -Name 'load_order')

    Assert-SqlSeedPrerequisite -Connection $Connection -DdlPath $DdlPath -DataPath $DataPath -Manifest $Manifest -SchemaOnly:$SchemaOnly

    Write-SeedStatus "Azure SQL: $(Get-MapValue -InputObject $Connection -Name 'ServerInstance') / $(Get-MapValue -InputObject $Connection -Name 'Database')" -Color Cyan
    Write-SeedStatus 'Applying DDL (data/seed/sql, filename order = dependency order)...' -Color Cyan
    $applied = @(Install-SeedSchema -Connection $Connection -DdlPath $DdlPath -TimeoutSeconds $TimeoutSeconds)

    # THE WORKLOAD GRANT IS NOT A .sql FILE, AND THAT IS THE POINT (F172). It needs the
    # identity's clientId, which is discovered from Azure at deploy time and cannot be
    # written into static text - data/seed/sql/ holds no templates by design. Half a pair
    # is refused: silently skipping on one supplied value is how a grant goes missing.
    $wantWorkloadUser = -not [string]::IsNullOrWhiteSpace($WorkloadUserName) -or -not [string]::IsNullOrWhiteSpace($WorkloadUserClientId)
    $workloadUser = $null
    if ($wantWorkloadUser) {
        if ([string]::IsNullOrWhiteSpace($WorkloadUserName) -or [string]::IsNullOrWhiteSpace($WorkloadUserClientId)) {
            throw "-WorkloadUserName and -WorkloadUserClientId are a pair: got name '$WorkloadUserName' and clientId '$WorkloadUserClientId'. Pass both or neither."
        }
        Write-SeedStatus "Granting the workload contained-database user '$WorkloadUserName'..." -Color Cyan
        $workloadUser = Set-SeedWorkloadUser -Connection $Connection -PrincipalName $WorkloadUserName `
            -ClientId $WorkloadUserClientId -TimeoutSeconds $TimeoutSeconds
    }

    if ($SchemaOnly) {
        # Install-SeedSchema gates each file on ShouldProcess, so under -WhatIf
        # it applies nothing and returns an empty set. Reporting "0 DDL file(s)
        # applied" would read as a failure rather than a dry run; the
        # non-SchemaOnly branch's own -WhatIf wording never runs because this
        # return precedes it.
        $summary = if ($WhatIfPreference) {
            '-SchemaOnly -WhatIf: no DDL applied (dry run); each file was listed above as it would be applied'
        }
        else {
            "-SchemaOnly: $($applied.Count) DDL file(s) applied"
        }
        Write-SeedStatus "$summary; no row-count check and no data load - this mode never touches table data." -Color Green
        return [pscustomobject]@{
            AppliedDdl           = $applied
            WorkloadUser         = $workloadUser
            Loaded               = @()
            SkippedAlreadySeeded = $false
            SchemaOnly           = $true
            WhatIf               = [bool]$WhatIfPreference
        }
    }

    if ($WhatIfPreference) {
        Write-SeedStatus "(-WhatIf) Would load $($loadOrder.Count) table(s) in order: $($loadOrder -join ', '). No database call was made." -Color Yellow
        return [pscustomobject]@{
            AppliedDdl            = $applied
            WorkloadUser          = $workloadUser
            Loaded                = @()
            SkippedAlreadySeeded  = $false
            SchemaOnly            = $false
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
            WorkloadUser         = $workloadUser
            Loaded               = @()
            SkippedAlreadySeeded = $true
            SchemaOnly           = $false
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
        WorkloadUser         = $workloadUser
        Loaded               = @($loaded)
        SkippedAlreadySeeded = $false
        SchemaOnly           = $false
        WhatIf               = $false
    }
}

Export-ModuleMember -Function @(
    'Assert-SqlIdentifier',
    'Assert-SqlPrincipalName',
    'Get-SeedWorkloadUser',
    'Set-SeedWorkloadUser',
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
