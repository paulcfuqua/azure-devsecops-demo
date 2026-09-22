#Requires -Version 7.0
<#
.SYNOPSIS
    L4 - apply column- and row-level security to the two mixed-sensitivity tables in the
    Fabric lakehouse `mls_operations`. Idempotent; safe to replay.

.DESCRIPTION
    The enforcement half of the tiered-access demo. L5 seeds `hr_roster` and
    `defect_reports`; this script makes them actually restricted:

      hr_roster       COLUMN-level. `salary_usd`, `bonus_target_pct` and
                      `performance_band` are DENIED to the standard role. Reading them
                      raises a visible permission error naming the column, while
                      `start_date`, `department` and the rest of the same row read
                      normally. A denied column REFUSES.

      defect_reports  ROW-level. A security policy over a schema-bound view filters rows
                      classified THIRD_PARTY_PROPRIETARY unless the caller is in the
                      privileged role. The standard role simply sees fewer rows, with no
                      error and no indication that anything was removed. RLS HIDES.

    The contrast is deliberate and is the point of having two tables: you choose the
    control by whether the EXISTENCE of the data is itself sensitive.

    WHAT A SENSITIVITY LABEL DOES NOT DO. `infra/purview/labels.ps1` classifies these
    tables with <prefix>-hr-sensitive and <prefix>-3ppi. A label is classification, DLP
    and audit metadata - it does not gate a read. Enforcement is here, in the data layer,
    and nowhere else. L04.md once claimed labels were applied to the lakehouse and
    checked at runtime; that was finding F18, corrected rather than implemented.

.NOTES
    PROVEN BEFORE IT WAS WRITTEN. Every mechanism below was verified against the live
    lakehouse SQL analytics endpoint on 2026-09-20, because a lakehouse endpoint is not a
    Warehouse and the documentation does not settle what it supports (spike probes A/A2/A3,
    recorded in docs/superpowers/specs/2026-09-20-tiered-data-access-demo-design.md).
    `DENY SELECT ON <table>(<column>)`, `CREATE VIEW ... WITH SCHEMABINDING`,
    `CREATE FUNCTION ... RETURNS TABLE WITH SCHEMABINDING` and
    `CREATE SECURITY POLICY ... WITH (STATE = ON)` all work, and the policy appears in
    `sys.security_policies` with `is_enabled = 1` so an audit can verify it.

    RLS binds to the schema-bound VIEW, not to the base Delta table. That is not a
    limitation worked around - it is the shape that was proven, and it gives the standard
    role a single door: the base table is denied outright.

    THE SCHEMA IS RESOLVED, NEVER REMEMBERED. Two spike attempts failed on a column name
    written from memory, and both times the error named the security policy, which was
    fine. `Invoke-TableProtection` reads INFORMATION_SCHEMA first and refuses to apply
    anything when the endpoint disagrees with this script - an unlisted column on
    hr_roster is one the DENY does not cover, which is a silent hole, not a cosmetic drift.

    NOT a G3 action. These are database objects inside the lakehouse, not tenant-level
    objects; the teardown half is infra/fabric/teardown-protection.ps1.

.EXAMPLE
    ./protect-tables.ps1 -SqlEndpoint $fqdn -AccessToken $token -Prefix mls
#>
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'AccessToken',
    Justification = 'An Entra access token arrives from az account get-access-token or a workflow step as a plain string and is handed to Invoke-Sqlcmd -AccessToken, which takes a plain string. SecureString would not protect it: on .NET for Linux - and CI is ubuntu-latest - SecureString is not encrypted, and the value would return to plain text at the call anyway. It is never logged.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'SqlEndpoint, AccessToken, Database and TimeoutSec are read by Get-EndpointColumn and Invoke-ProtectionSql through PowerShell dynamic scoping rather than being passed down explicitly, which the analyser cannot follow. They are the connection, so a genuinely unused one would fail on the first query. The parameters that were REALLY unused - StandardPrincipal and PrivilegedPrincipal - were removed rather than suppressed: see Invoke-TableProtection.')]
param(
    # The lakehouse SQL analytics endpoint FQDN. RESOLVED from the Fabric API by the
    # caller, never stored.
    #
    # NOT because it changes every rebuild - MEASURED 2026-09-21, it does not. The
    # lakehouse was deleted and recreated (id 6c8f6a71... -> f578ec8c...) and the FQDN
    # was identical, because it is WORKSPACE-scoped and the standard teardown leaves the
    # workspace shell standing. The earlier comment here claimed otherwise and was wrong.
    #
    # Resolving is still correct, for reasons that survive that correction: recreating
    # the WORKSPACE is a G3 path that does exist, the lakehouse id demonstrably does
    # change, and a stored endpoint is a claim somebody has to keep true. A value the
    # template derives beats one a human stores (F129) even when the stored one would
    # have happened to work.
    [Parameter(Mandatory)][string]$SqlEndpoint,

    [Parameter(Mandatory)][string]$AccessToken,

    [string]$Database = 'mls_operations',

    # Empty resolves from MLS_COMPANY_PREFIX, then infra/bicep/naming.bicep.
    [string]$Prefix = '',

    [int]$TimeoutSec = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------
# The schema this script protects. Kept as literals so a drifted generator fails LOUDLY
# at Assert-ExpectedColumn rather than quietly leaving a column uncovered.
# Source of truth: data/generators/build.py :: gen_hr_roster / gen_defect_reports.
# ---------------------------------------------------------------------------------------
$script:HrRosterColumn = @(
    'employee_id', 'display_name', 'department', 'job_family', 'location',
    'start_date', 'tenure_years', 'manager_id', 'employment_type',
    'salary_usd', 'bonus_target_pct', 'performance_band'
)
# The three the standard role may not read. Every other hr_roster column is open.
$script:HrRestrictedColumn = @('salary_usd', 'bonus_target_pct', 'performance_band')

$script:DefectReportColumn = @(
    'defect_id', 'vehicle_id', 'supplier_id', 'reported_date', 'severity',
    'subsystem', 'status', 'summary', 'root_cause', 'classification'
)
$script:RestrictedClassification = 'THIRD_PARTY_PROPRIETARY'

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Deploy script; console output is the product and is read from workflow logs.')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

function Get-CompanyPrefix {
    <#
        MLS_COMPANY_PREFIX first, naming.bicep second - the same resolution order as
        infra/purview/labels.ps1 and verification/layer-04-audit.ps1. A resolver that
        reads only the file disagrees with every one that honours the override, and the
        estate splits down the middle (F91).
    #>
    param([string]$Path = (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'bicep', 'naming.bicep'))
    if (-not [string]::IsNullOrWhiteSpace($env:MLS_COMPANY_PREFIX)) { return $env:MLS_COMPANY_PREFIX }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cannot resolve the role-name prefix: '$Path' does not exist. Names come from infra/bicep/naming.bicep and nowhere else (CLAUDE.md). Pass -Prefix explicitly, or run from a clone of the repository."
    }
    $match = [regex]::Match((Get-Content -LiteralPath $Path -Raw), "var\s+defaultCompanyPrefix\s*=\s*'([^']+)'")
    if (-not $match.Success) { throw "Could not parse 'defaultCompanyPrefix' out of '$Path'. Nothing was applied." }
    return $match.Groups[1].Value
}

function ConvertTo-SqlLiteral {
    <# Double every single quote so a statement survives being wrapped in EXEC('...'). #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return $Text.Replace("'", "''")
}

function Get-ProtectionStatement {
    <#
    .SYNOPSIS
        Every statement this script applies, in dependency order, each one safe to replay.
    .DESCRIPTION
        Returned rather than executed so the whole plan is inspectable - by the Pester
        suite, by -WhatIf, and by a human reading a workflow log before it runs.

        CREATE VIEW / FUNCTION / SECURITY POLICY must each be the first statement in their
        batch, so they cannot sit inside an IF. The guarded form is EXEC('...'), which is
        why the inner quotes are doubled.
    #>
    param([Parameter(Mandatory)][string]$Prefix)

    $standard = "${Prefix}_data_standard"
    $privileged = "${Prefix}_data_privileged"
    $restrictedList = ($script:HrRestrictedColumn | ForEach-Object { "[$_]" }) -join ', '
    $viewColumnList = ($script:DefectReportColumn | ForEach-Object { "[$_]" }) -join ', '

    $viewBody = "CREATE VIEW dbo.v_defect_reports WITH SCHEMABINDING AS SELECT $viewColumnList FROM dbo.defect_reports"
    $predicateBody = @"
CREATE FUNCTION dbo.fn_defect_tier(@classification NVARCHAR(32))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN SELECT 1 AS allowed
WHERE @classification <> N'$($script:RestrictedClassification)'
   OR IS_ROLEMEMBER('$privileged') = 1
"@
    $policyBody = "CREATE SECURITY POLICY dbo.sp_defect_tier ADD FILTER PREDICATE dbo.fn_defect_tier([classification]) ON dbo.v_defect_reports WITH (STATE = ON)"

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

    # sys.database_principals, NOT DATABASE_PRINCIPAL_ID(). That function is not
    # supported on a Fabric lakehouse SQL analytics endpoint - it fails with
    # "FUNCTION 'DATABASE_PRINCIPAL_ID' is not supported" (Msg 15871), verified live
    # 2026-09-20. The guard then threw, the role was never created, and every GRANT and
    # DENY after it failed with "Principal could not be found". Every unit test still
    # passed, because they inspect the SQL text and not what the endpoint does with it.
    # CREATE ROLE itself is fine inside an IF - only VIEW/FUNCTION/POLICY must begin a batch.
    Add-Statement -Key 'role_standard' -Description 'the standard tier' -Sql @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE [name] = N'$standard' AND [type] = 'R')
    CREATE ROLE [$standard];
"@

    Add-Statement -Key 'role_privileged' -Description 'the privileged tier' -Sql @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE [name] = N'$privileged' AND [type] = 'R')
    CREATE ROLE [$privileged];
"@

    Add-Statement -Key 'grant_hr_open' -Description 'standard tier may read hr_roster' -Sql @"
GRANT SELECT ON dbo.hr_roster TO [$standard];
"@

    # COLUMN-LEVEL SECURITY. A DENY outranks the table-level GRANT above, so the standard
    # role reads every other column of the same row and is refused on these three.
    Add-Statement -Key 'cls_hr_roster' -Description 'restricted hr_roster columns denied to the standard tier' -Sql @"
DENY SELECT ($restrictedList) ON dbo.hr_roster TO [$standard];
"@

    # THE HR HALF HAD NO VIEW, ONLY THE INERT COLUMN DENY ABOVE.
    #
    # cls_hr_roster denies the compensation columns to $standard, and no principal can be
    # a member of $standard - CREATE USER is unsupported on this endpoint (F218). So the
    # DENY binds to nobody and salary_usd was readable by every caller, including the
    # agent's SQL tool.
    #
    # defect_reports got a schema-bound view and a row-level policy; hr_roster got a
    # column DENY that cannot bind. This is the missing half: a view that simply does not
    # project the restricted columns, which needs no role membership to be true.
    $hrOpenColumn = @($script:HrRosterColumn | Where-Object { $_ -notin $script:HrRestrictedColumn })
    $hrViewColumnList = ($hrOpenColumn | ForEach-Object { "[$_]" }) -join ', '
    $hrViewBody = "CREATE VIEW dbo.v_hr_roster WITH SCHEMABINDING AS SELECT $hrViewColumnList FROM dbo.hr_roster"

    Add-Statement -Key 'hr_view' -Description 'schema-bound view over hr_roster without the compensation columns' -Sql @"
IF NOT EXISTS (SELECT 1 FROM sys.views WHERE [name] = N'v_hr_roster' AND [schema_id] = SCHEMA_ID(N'dbo'))
    EXEC('$(ConvertTo-SqlLiteral $hrViewBody)');
"@

    Add-Statement -Key 'grant_hr_view' -Description 'both tiers may read the governed hr view' -Sql @"
GRANT SELECT ON dbo.v_hr_roster TO [$standard];
GRANT SELECT ON dbo.v_hr_roster TO [$privileged];
"@

    Add-Statement -Key 'rls_view' -Description 'schema-bound view over defect_reports' -Sql @"
IF NOT EXISTS (SELECT 1 FROM sys.views WHERE [name] = N'v_defect_reports' AND [schema_id] = SCHEMA_ID(N'dbo'))
    EXEC('$(ConvertTo-SqlLiteral $viewBody)');
"@

    Add-Statement -Key 'rls_predicate' -Description 'row-level security predicate' -Sql @"
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE [name] = N'fn_defect_tier' AND [schema_id] = SCHEMA_ID(N'dbo'))
    EXEC('$(ConvertTo-SqlLiteral $predicateBody)');
"@

    # STATE = ON matters. A policy created OFF exists, looks healthy in sys.security_policies
    # and filters nothing - F119's class, a thing present but not enabled.
    Add-Statement -Key 'rls_policy' -Description 'row-level security policy, enabled' -Sql @"
IF NOT EXISTS (SELECT 1 FROM sys.security_policies WHERE [name] = N'sp_defect_tier')
    EXEC('$(ConvertTo-SqlLiteral $policyBody)');
"@

    Add-Statement -Key 'grant_view' -Description 'standard tier reads defects through the filtered view' -Sql @"
GRANT SELECT ON dbo.v_defect_reports TO [$standard];
"@

    # The view is the ONLY door. Without this the standard role reads the base table and
    # the policy protects nothing at all.
    Add-Statement -Key 'deny_base' -Description 'standard tier denied the unfiltered base table' -Sql @"
DENY SELECT ON dbo.defect_reports TO [$standard];
"@

    Add-Statement -Key 'grant_privileged' -Description 'privileged tier reads both tables unfiltered' -Sql @"
GRANT SELECT ON dbo.hr_roster TO [$privileged];
GRANT SELECT ON dbo.defect_reports TO [$privileged];
GRANT SELECT ON dbo.v_defect_reports TO [$privileged];
"@

    return $statements
}

function Assert-ExpectedColumn {
    <#
    .SYNOPSIS
        Refuse to protect a table whose shape is not the one this script was written for.
    .DESCRIPTION
        Both directions are fatal, and the second is the one that matters: a column the
        endpoint has and this script does not know about is a column the DENY does not
        cover, so it stays readable by the standard role. That is a silent hole, not a
        cosmetic drift - so it fails rather than warns.
    #>
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Expected,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Actual
    )
    $missing = @($Expected | Where-Object { $_ -notin $Actual })
    $unknown = @($Actual | Where-Object { $_ -notin $Expected })
    if ($missing.Count -eq 0 -and $unknown.Count -eq 0) { return }

    $parts = @()
    if ($missing.Count -gt 0) { $parts += "missing expected column(s): $($missing -join ', ')" }
    if ($unknown.Count -gt 0) { $parts += "column(s) this script does not cover: $($unknown -join ', ')" }
    throw "Schema mismatch on dbo.$Table - $($parts -join '; '). Nothing was applied. An uncovered column on a protected table is readable by the standard role, so this refuses rather than protecting part of the table. Reconcile data/generators/build.py, data/seed/schema-manifest.json and this script."
}

function Get-EndpointColumn {
    <#
        The columns the endpoint actually reports for a table. Resolved, never remembered.

        ALWAYS RETURNS AN ARRAY, never $null. The first version could hand back $null when
        the endpoint reported nothing, and the caller then failed with "Cannot bind argument
        to parameter 'Actual' because it is null" - an error naming a PowerShell binding
        rule and saying nothing about the sync lag that actually caused it.
    #>
    param([Parameter(Mandatory)][string]$Table)
    $rows = @(Invoke-Sqlcmd -ServerInstance $SqlEndpoint -Database $Database -AccessToken $AccessToken `
            -ConnectionTimeout $TimeoutSec -ErrorAction Stop -Query @"
SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = '$(ConvertTo-SqlLiteral $Table)'
"@)
    $names = @($rows | ForEach-Object { "$($_.COLUMN_NAME)" } | Where-Object { $_ })
    return , $names
}

function Wait-EndpointTable {
    <#
    .SYNOPSIS
        Wait for the SQL analytics endpoint to see tables the seed has just loaded.
    .DESCRIPTION
        A newly loaded Delta table is NOT immediately visible to the SQL analytics endpoint.
        MEASURED 2026-09-20: Fabric's /tables route reported all twelve tables while the SQL
        catalog still reported ten, and the two new ones appeared there after 63 seconds.

        This step runs immediately after the load, so without a wait it queries an endpoint
        that has not caught up and concludes the tables do not exist. V5.5 already carries a
        retry window citing this measurement; the deploy path had none, which is how a
        CORRECT seed produced a failed protection step.

        The window is ten minutes - roughly 10x the observation - and the failure names the
        lag rather than the symptom, because "no columns" and "not synced yet" are the same
        observation five seconds apart.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Table,
        [int]$TimeoutMinutes = 10,
        [int]$PollSeconds = 15
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $pending = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $Table) { $pending.Add($t) }

    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        foreach ($t in @($pending)) {
            if ((Get-EndpointColumn -Table $t).Count -gt 0) {
                Write-Status "  visible to the SQL endpoint: $t" -Color Green
                $pending.Remove($t) | Out-Null
            }
        }
        if ($pending.Count -eq 0) { break }
        Write-Status "  waiting for the SQL endpoint to catch up on: $($pending -join ', ')" -Color Yellow
        Start-Sleep -Seconds $PollSeconds
    }

    if ($pending.Count -gt 0) {
        throw "The SQL analytics endpoint still reports no columns for $($pending -join ', ') after $TimeoutMinutes minute(s). A newly loaded Delta table is invisible to this endpoint for a short period - measured at 63 seconds on 2026-09-20 - but this is well beyond that. Check that the L5 seed actually loaded the tables (Fabric's /tables route answers independently of the SQL catalog) before assuming the protection is at fault."
    }
}

function Invoke-ProtectionSql {
    <# One statement against the endpoint. The single place this script touches TDS. #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Sql
    )
    Write-Verbose "Applying protection statement '$Key'."
    Invoke-Sqlcmd -ServerInstance $SqlEndpoint -Database $Database -AccessToken $AccessToken `
        -ConnectionTimeout $TimeoutSec -Query $Sql -ErrorAction Stop | Out-Null
}

function Invoke-TableProtection {
    <#
    .SYNOPSIS
        Verify the schema, then apply every statement, reporting on all of them.
    .DESCRIPTION
        Fails at the END, not at the first error. A run against a rate-limited remote
        endpoint is an expensive observation and returns everything it saw; stopping at
        the first failure makes the discovery rate equal to the deploy rate (CLAUDE.md).

        The schema check is the exception and is deliberately fail-fast: applying half a
        protection set to a table whose shape is unrecognised is worse than applying none.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Prefix = '')

    if ([string]::IsNullOrWhiteSpace($Prefix)) { $Prefix = Get-CompanyPrefix }

    # WAIT BEFORE RESOLVING. This runs immediately after the seed, and the SQL analytics
    # endpoint lags the Delta load by roughly a minute (F223). Without this the schema
    # resolution below reads an empty catalog and reports a correct seed as a broken one.
    Write-Status 'Waiting for the SQL analytics endpoint to see the seeded tables...' -Color Cyan
    Wait-EndpointTable -Table @('hr_roster', 'defect_reports')

    Write-Status 'Resolving the live schema for dbo.hr_roster and dbo.defect_reports...' -Color Cyan
    Assert-ExpectedColumn -Table 'hr_roster' -Expected $script:HrRosterColumn -Actual (Get-EndpointColumn -Table 'hr_roster')
    Assert-ExpectedColumn -Table 'defect_reports' -Expected $script:DefectReportColumn -Actual (Get-EndpointColumn -Table 'defect_reports')
    Write-Status 'Schema matches; applying protection.' -Color Green

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($statement in Get-ProtectionStatement -Prefix $Prefix) {
        if (-not $PSCmdlet.ShouldProcess("dbo ($Database)", "apply '$($statement.Key)' - $($statement.Description)")) {
            $results.Add([pscustomobject]@{ Key = $statement.Key; Status = 'WhatIf'; Error = $null })
            continue
        }
        try {
            Invoke-ProtectionSql -Key $statement.Key -Sql $statement.Sql
            $results.Add([pscustomobject]@{ Key = $statement.Key; Status = 'Applied'; Error = $null })
            Write-Status "  [applied] $($statement.Key) - $($statement.Description)" -Color Green
        } catch {
            $results.Add([pscustomobject]@{ Key = $statement.Key; Status = 'Failed'; Error = $_.Exception.Message })
            Write-Status "  [FAILED ] $($statement.Key) - $($_.Exception.Message)" -Color Red
        }
    }

    $failed = @($results | Where-Object Status -eq 'Failed')
    if ($failed.Count -gt 0) {
        Write-Error "Table protection incomplete: $($failed.Count) of $($results.Count) statement(s) failed - $((($failed).Key) -join ', '). Every statement was attempted; see the per-statement errors above."
    }
    return $results
}

if (-not $env:MLS_SKIP_MAIN) {
    Invoke-TableProtection -Prefix $Prefix
}
