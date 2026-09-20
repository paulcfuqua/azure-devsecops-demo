#Requires -Version 7.0
<#
.SYNOPSIS
    L4 - remove the column- and row-level security applied by protect-tables.ps1.
    Removes PROTECTION, never DATA. Idempotent; safe to replay.

.DESCRIPTION
    The teardown third of protect-tables.ps1's triplet (CLAUDE.md: "Every layer ships a
    deploy path, a teardown script, a verification audit script. A layer without all
    three is not done.").

    Drops, in this order and for these reasons:

      1. the security policy   - a view bound by a live policy cannot be dropped, and
                                 neither can a predicate the policy still references
      2. the REVOKEs           - a permission cannot be revoked from a role that has
                                 already been dropped
      3. the view              - now unbound
      4. the predicate         - now unreferenced
      5. the two roles         - now holding nothing

    `hr_roster` and `defect_reports` are NOT touched. They are L5's, seeded from
    data/generators, and a teardown that dropped them would turn "remove the access
    controls" into "destroy the demo dataset". The tests assert this negatively - no
    DROP TABLE, no TRUNCATE, no DELETE, and no DROP naming either base table.

.NOTES
    NOT a G3 action, and deliberately so. G3 covers TENANT-level deletions - Entra
    objects, sensitivity labels, the Fabric workspace, OIDC federation - things nothing
    in the deploy path can recreate. These are database objects inside a lakehouse that
    protect-tables.ps1 recreates in full on the next run, and RG-scoped teardown of demo
    resources is gate-free by design (CLAUDE.md gate G3).

    Kept as a deliberate DUPLICATE of protect-tables.ps1's object list rather than
    importing it, for the same reason infra/purview/teardown.ps1 and
    verification/layer-04-audit.ps1 each keep their own copy of the label taxonomy: a
    destructive path that imports the creating one couples them, and the import can drag
    in the very state being removed. The cost is that both must be updated together,
    which is exactly how hr-sensitive and 3ppi were nearly left as orphans in the Purview
    taxonomy - so a test asserts every object named here.

    DATABASE_PRINCIPAL_ID() is not used, here or anywhere: it fails on a Fabric lakehouse
    SQL analytics endpoint with Msg 15871 (verified live 2026-09-20). A test pins it.

.EXAMPLE
    ./teardown-protection.ps1 -SqlEndpoint $fqdn -AccessToken $token -Prefix mls
#>
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'AccessToken',
    Justification = 'An Entra access token arrives as a plain string and Invoke-Sqlcmd -AccessToken takes a plain string. SecureString is not encrypted on .NET for Linux, and CI is ubuntu-latest. The value is never logged.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'SqlEndpoint, AccessToken, Database and TimeoutSec are read by Invoke-TeardownSql through PowerShell dynamic scoping rather than being passed down explicitly, which the analyser cannot follow. They are the connection, so a genuinely unused one would fail on the first statement.')]
param(
    [Parameter(Mandatory)][string]$SqlEndpoint,
    [Parameter(Mandatory)][string]$AccessToken,
    [string]$Database = 'mls_operations',
    [string]$Prefix = '',
    [int]$TimeoutSec = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Teardown script; console output is the product and is read from workflow logs.')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

function Get-CompanyPrefix {
    <# MLS_COMPANY_PREFIX first, naming.bicep second - the estate's standard order (F91). #>
    param([string]$Path = (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'bicep', 'naming.bicep'))
    if (-not [string]::IsNullOrWhiteSpace($env:MLS_COMPANY_PREFIX)) { return $env:MLS_COMPANY_PREFIX }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cannot resolve the role-name prefix: '$Path' does not exist. Pass -Prefix explicitly. Nothing was removed."
    }
    $match = [regex]::Match((Get-Content -LiteralPath $Path -Raw), "var\s+defaultCompanyPrefix\s*=\s*'([^']+)'")
    if (-not $match.Success) { throw "Could not parse 'defaultCompanyPrefix' out of '$Path'. Nothing was removed." }
    return $match.Groups[1].Value
}

function Get-TeardownStatement {
    <#
    .SYNOPSIS
        Every statement this script applies, in dependency order, each safe to replay.
    .DESCRIPTION
        Returned rather than executed so the whole plan is inspectable before anything
        destructive runs - by the Pester suite, by -WhatIf, and by a human reading a log.
    #>
    param([Parameter(Mandatory)][string]$Prefix)

    $standard = "${Prefix}_data_standard"
    $privileged = "${Prefix}_data_privileged"

    $statements = [System.Collections.Generic.List[object]]::new()
    function Add-Statement {
        param([string]$Key, [string]$Sql, [string]$Description)
        $statements.Add([pscustomobject]@{
                Key         = $Key
                Sql         = $Sql.Trim()
                Description = $Description
                Idempotent  = $true
            })
    }

    # 1. The policy first: it binds the view and references the predicate, so nothing
    #    underneath it can be dropped while it exists.
    Add-Statement -Key 'rls_policy' -Description 'row-level security policy' -Sql @"
IF EXISTS (SELECT 1 FROM sys.security_policies WHERE [name] = N'sp_defect_tier')
    DROP SECURITY POLICY dbo.sp_defect_tier;
"@

    # 2. Revoke while the roles still exist. REVOKE against a dropped principal fails
    #    with "Principal could not be found", so the guard is the principal, not the
    #    permission - a REVOKE of a permission that was never granted is a no-op.
    Add-Statement -Key 'revoke_standard' -Description 'permissions held by the standard tier' -Sql @"
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE [name] = N'$standard' AND [type] = 'R')
BEGIN
    REVOKE SELECT ([salary_usd], [bonus_target_pct], [performance_band]) ON dbo.hr_roster FROM [$standard];
    REVOKE SELECT ON dbo.hr_roster FROM [$standard];
    REVOKE SELECT ON dbo.defect_reports FROM [$standard];
    IF EXISTS (SELECT 1 FROM sys.views WHERE [name] = N'v_defect_reports' AND [schema_id] = SCHEMA_ID(N'dbo'))
        REVOKE SELECT ON dbo.v_defect_reports FROM [$standard];
END;
"@

    Add-Statement -Key 'revoke_privileged' -Description 'permissions held by the privileged tier' -Sql @"
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE [name] = N'$privileged' AND [type] = 'R')
BEGIN
    REVOKE SELECT ON dbo.hr_roster FROM [$privileged];
    REVOKE SELECT ON dbo.defect_reports FROM [$privileged];
    IF EXISTS (SELECT 1 FROM sys.views WHERE [name] = N'v_defect_reports' AND [schema_id] = SCHEMA_ID(N'dbo'))
        REVOKE SELECT ON dbo.v_defect_reports FROM [$privileged];
END;
"@

    # 3. The view - now unbound. dbo.v_defect_reports, NOT dbo.defect_reports: the two
    #    differ by four characters and one of them is the demo dataset.
    Add-Statement -Key 'rls_view' -Description 'schema-bound view over defect_reports' -Sql @"
IF EXISTS (SELECT 1 FROM sys.views WHERE [name] = N'v_defect_reports' AND [schema_id] = SCHEMA_ID(N'dbo'))
    DROP VIEW dbo.v_defect_reports;
"@

    # 4. The predicate - now unreferenced.
    Add-Statement -Key 'rls_predicate' -Description 'row-level security predicate' -Sql @"
IF EXISTS (SELECT 1 FROM sys.objects WHERE [name] = N'fn_defect_tier' AND [schema_id] = SCHEMA_ID(N'dbo'))
    DROP FUNCTION dbo.fn_defect_tier;
"@

    # 5. The roles - now holding nothing.
    Add-Statement -Key 'role_standard' -Description 'the standard tier role' -Sql @"
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE [name] = N'$standard' AND [type] = 'R')
    DROP ROLE [$standard];
"@

    Add-Statement -Key 'role_privileged' -Description 'the privileged tier role' -Sql @"
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE [name] = N'$privileged' AND [type] = 'R')
    DROP ROLE [$privileged];
"@

    return $statements
}

function Invoke-TeardownSql {
    <# One statement against the endpoint. The single place this script touches TDS. #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Sql
    )
    Write-Verbose "Applying teardown statement '$Key'."
    Invoke-Sqlcmd -ServerInstance $SqlEndpoint -Database $Database -AccessToken $AccessToken `
        -ConnectionTimeout $TimeoutSec -Query $Sql -ErrorAction Stop | Out-Null
}

function Invoke-ProtectionTeardown {
    <#
    .SYNOPSIS
        Apply every teardown statement, reporting on all of them.
    .DESCRIPTION
        Continues past a failure and fails at the END. A teardown that stops at the first
        error leaves a half-removed estate, which is the state that is most expensive to
        reason about later - and the run is an expensive observation either way, so it
        returns everything it saw (CLAUDE.md).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Prefix = '')

    if ([string]::IsNullOrWhiteSpace($Prefix)) { $Prefix = Get-CompanyPrefix }

    Write-Status "Removing table protection from $Database (data is not touched)..." -Color Cyan

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($statement in Get-TeardownStatement -Prefix $Prefix) {
        if (-not $PSCmdlet.ShouldProcess("dbo ($Database)", "remove '$($statement.Key)' - $($statement.Description)")) {
            $results.Add([pscustomobject]@{ Key = $statement.Key; Status = 'WhatIf'; Error = $null })
            continue
        }
        try {
            Invoke-TeardownSql -Key $statement.Key -Sql $statement.Sql
            # 'Applied', not 'Removed'. Every statement is guarded, so a successful run
            # against an estate where the object never existed is a no-op that succeeds
            # exactly like a real deletion. Reporting 'Removed' for both would be a
            # status that cannot distinguish two states, which is not evidence of
            # anything (CLAUDE.md). What this records is that the statement ran.
            $results.Add([pscustomobject]@{ Key = $statement.Key; Status = 'Applied'; Error = $null })
            Write-Status "  [applied] $($statement.Key) - $($statement.Description)" -Color Green
        } catch {
            $results.Add([pscustomobject]@{ Key = $statement.Key; Status = 'Failed'; Error = $_.Exception.Message })
            Write-Status "  [FAILED ] $($statement.Key) - $($_.Exception.Message)" -Color Red
        }
    }

    $failed = @($results | Where-Object Status -eq 'Failed')
    if ($failed.Count -gt 0) {
        Write-Error "Protection teardown incomplete: $($failed.Count) of $($results.Count) statement(s) failed - $((($failed).Key) -join ', '). Every statement was attempted; see the per-statement errors above. Re-run: every statement is guarded and safe to replay."
    }
    return $results
}

if (-not $env:MLS_SKIP_MAIN) {
    Invoke-ProtectionTeardown -Prefix $Prefix
}
