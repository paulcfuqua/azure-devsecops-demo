#Requires -Version 7.0
<#
.SYNOPSIS
    L5 Verifier audit - Fabric workspace, lakehouse, seeded tables, capacity. READ-ONLY.

.DESCRIPTION
    Implements the four master-plan Verify criteria owned by
    docs/runbooks/layers/L05.md section Validation cycle, and nothing else:

      V5.1  Fabric REST: workspace + lakehouse exist.
      V5.2  Table list matches manifest.
      V5.3  SQL analytics endpoint returns expected row counts (launches = 1,200 +/- 0).
      V5.4  Capacity state == Paused after layer completes.

    Sequence matters: V5.1 -> V5.2 -> V5.3 run while the capacity is resumed (SQL-endpoint
    reads on a paused capacity fail), V5.4 after the layer's pause step completes
    (L05.md V5.3 Retry/propagation note). The audit resumes nothing - it is Reader-only,
    and a resume would be a G2 spend decision.

    V5.2 ESTABLISHES THAT IT COULD LOOK BEFORE IT REPORTS WHAT IT SAW. Fabric's
    /lakehouses/<id>/tables answers 200 with an empty list - never 403 - to a caller
    without OneLake read, and mls-verifier holds workspace Viewer, which does not carry
    it. So the criterion probes OneLake directly (which DOES answer 403), and reads the
    table list over the route this identity has been shown to be able to read: the Fabric
    list when OneLake is readable, the SQL analytics catalog when it is not, and
    UNOBSERVABLE - never "the tables are missing" - when neither answers (F105, F171).

    The row-count expectations come from the deterministic seed 20260822: launches = 1,200
    is pinned by the master plan itself; the other nine tables come from Track A's
    committed expected-counts fixture. If that fixture is absent the criterion records a
    labelled SKIP rather than passing on the one value it could check.

.EXAMPLE
    ./layer-05-audit.ps1 -FabricCapacityId <capacity-id> -FabricToken $token
#>
[CmdletBinding()]
param(
    [string]$FabricCapacityId,
    [string]$FabricToken,
    [string]$WorkspaceName = 'mls-operations',
    [string]$LakehouseName = 'mls_operations',
    [string[]]$ExpectedTable = @(
        'launches', 'scrubs', 'vehicles', 'pads', 'telemetry_summary',
        'parts', 'suppliers', 'work_orders', 'cost_daily', 'findings_history'
    ),
    [int]$ExpectedLaunchCount = 1200,
    [string]$ExpectedCountPath,
    [string]$SqlEndpoint,
    # Entra token for https://database.windows.net. Omit it in CI and pass
    # $env:MLS_SQL_ACCESS_TOKEN instead - process arguments are visible on the runner - or
    # omit both and MlsAudit mints one from the mls-verifier login.
    [string]$SqlAccessToken,
    # Entra token for https://storage.azure.com - the OneLake DATA plane, a different
    # audience from the Fabric control plane above. V5.2 uses it to establish whether this
    # identity can see OneLake at all, BEFORE it reads anything into a verdict (F105).
    [string]$OneLakeToken,
    [string]$ReportRoot,
    [switch]$NoRetry,
    # Run only these criteria (e.g. -OnlyCriterion V5.2). Everything else reports SKIP
    # naming the reason, and the run exits 3 - a DIAGNOSTIC, never a sign-off (P-10).
    [string[]]$OnlyCriterion = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'MlsAudit.psm1') -Force

$script:FabricApiBaseUrl = 'https://api.fabric.microsoft.com/v1'

function Get-FabricAuthHeader {
    <# Bearer header for the Fabric REST API as mls-verifier (workspace Viewer, granted
       by the L5 provisioning script). #>
    param([Parameter(Mandatory)][string]$Token)
    return @{ Authorization = "Bearer $Token" }
}

function Get-VerifierFabricToken {
    <# Explicit token wins; otherwise mint one from the current read-only login. #>
    param([AllowEmptyString()][string]$Token)
    if (-not [string]::IsNullOrWhiteSpace($Token)) { return $Token }
    $fromEnvironment = [Environment]::GetEnvironmentVariable('MLS_FABRIC_TOKEN')
    if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) { return $fromEnvironment }
    $response = Invoke-MlsAz -Argument @(
        'account', 'get-access-token', '--resource', 'https://api.fabric.microsoft.com', '--output', 'json'
    )
    $token = Get-MlsProperty -InputObject $response -Name 'accessToken'
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'Could not obtain a Fabric access token. Sign in as mls-verifier (az login --service-principal ...) or pass -FabricToken / $env:MLS_FABRIC_TOKEN.'
    }
    return $token
}

function Get-VerifierOneLakeToken {
    <# ONELAKE IS A STORAGE AUDIENCE, NOT THE FABRIC ONE. Reusing the Fabric control-plane
       token here returns an opaque 401 bearer challenge - data/seed/lakehouse's own module
       says so at the point it mints one. Explicit value, then the environment, then the
       current read-only login. -AllowFailure: an identity that cannot even MINT the token
       is a case V5.2 handles (it reports what it could not do), not a reason to end the
       run. #>
    param([AllowEmptyString()][AllowNull()][string]$Token)
    if (-not [string]::IsNullOrWhiteSpace($Token)) { return $Token }
    $fromEnvironment = [Environment]::GetEnvironmentVariable('MLS_ONELAKE_TOKEN')
    if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) { return $fromEnvironment }
    # SWALLOWED HERE, AND ONLY HERE, BECAUSE THE FAILURE IS REPORTED RATHER THAN READ AS A
    # FACT. Invoke-MlsAz raises on an expired federated assertion even under -AllowFailure,
    # deliberately, so that "could not tell" never becomes "not there". This token is not a
    # source of facts: it is the instrument V5.2 uses to find out whether it can see, and an
    # instrument that cannot be built produces "NOT PROBED" - which V5.2 reports verbatim
    # and which is neither a grant nor a denial. Letting it throw instead would end the run
    # at exit 2 with no criterion recorded at all, which is strictly less information.
    try {
        $response = Invoke-MlsAz -AllowFailure -Argument @(
            'account', 'get-access-token', '--resource', 'https://storage.azure.com', '--output', 'json'
        )
    }
    catch { return '' }
    if ($null -eq $response) { return '' }
    return "$(Get-MlsProperty -InputObject $response -Name 'accessToken')"
}

function Test-OneLakeReadable {
    <#
    .SYNOPSIS
        CAN THIS IDENTITY SEE ONELAKE AT ALL? Asked BEFORE anything is concluded from
        /lakehouses/<id>/tables, because that endpoint cannot answer it.

    .DESCRIPTION
        F105's rule is "establish that you could observe before reporting what you saw".
        This is that establishment step, and it exists because the two endpoints disagree
        about how to say no:

          GET  https://api.fabric.microsoft.com/v1/.../lakehouses/<id>/tables
               -> HTTP 200 { "data": [] }        to a caller without OneLake read
          GET  https://onelake.dfs.fabric.microsoft.com/<ws>/<lh>/Tables?resource=filesystem
               -> HTTP 403 Forbidden             to the same caller, same second

        Verified against the live estate on 2026-09-03, as a principal holding no
        workspace role: the Fabric route answered 200 with an empty list while OneLake
        answered 403 "User is not authorized to perform current operation for workspace
        ... artifact ...". So OneLake DOES distinguish denial from emptiness and the
        Fabric route does not - which makes the DFS probe the discriminator the whole
        criterion was missing.

        Three outcomes, never two. Readable, Denied, and Unknown - and Unknown is not
        Denied: a probe that never produced a status has established nothing.
    #>
    param(
        [AllowEmptyString()][AllowNull()][string]$TablesPath,
        [AllowEmptyString()][AllowNull()][string]$Token
    )
    if ([string]::IsNullOrWhiteSpace($TablesPath)) {
        return [pscustomobject]@{
            Readable = $false; Denied = $false
            Evidence = 'OneLake read: NOT PROBED - the lakehouse metadata carried no properties.oneLakeTablesPath'
        }
    }
    if ([string]::IsNullOrWhiteSpace($Token)) {
        return [pscustomobject]@{
            Readable = $false; Denied = $false
            Evidence = 'OneLake read: NOT PROBED - no https://storage.azure.com token could be minted for this identity'
        }
    }
    $uri = "$TablesPath" + '?resource=filesystem&recursive=false'
    $probe = Invoke-MlsHttp -Uri $uri -Header @{ Authorization = "Bearer $Token" } -TimeoutSec 60
    $status = [int](Get-MlsProperty -InputObject $probe -Name 'StatusCode')
    if ($status -ge 200 -and $status -lt 300) {
        return [pscustomobject]@{
            Readable = $true; Denied = $false
            Evidence = "OneLake read: $uri -> HTTP $status (this identity CAN see the lakehouse's data plane)"
        }
    }
    if ($status -eq 401 -or $status -eq 403) {
        return [pscustomobject]@{
            Readable = $false; Denied = $true
            Evidence = "OneLake read: $uri -> HTTP $status (denied - so the Fabric /tables list this identity receives is UNOBSERVABLE, not empty)"
        }
    }
    $probeError = "$(Get-MlsProperty -InputObject $probe -Name 'Error')"
    return [pscustomobject]@{
        Readable = $false; Denied = $false
        Evidence = "OneLake read: $uri -> HTTP $status$(if ($probeError) { " ($probeError)" }) - neither a grant nor a denial, so nothing is established"
    }
}

function Get-FabricWorkspaceByName {
    param(
        [Parameter(Mandatory)][hashtable]$Header,
        [Parameter(Mandatory)][string]$Name
    )
    $response = Invoke-MlsRest -Uri "$($script:FabricApiBaseUrl)/workspaces" -Header $Header
    $found = @(Get-MlsCollection -Response $response | Where-Object { (Get-MlsProperty -InputObject $_ -Name 'displayName') -eq $Name })
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

function Get-FabricLakehouseByName {
    param(
        [Parameter(Mandatory)][hashtable]$Header,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$Name
    )
    $response = Invoke-MlsRest -Uri "$($script:FabricApiBaseUrl)/workspaces/$WorkspaceId/lakehouses" -Header $Header
    return @(Get-MlsCollection -Response $response | Where-Object { (Get-MlsProperty -InputObject $_ -Name 'displayName') -eq $Name })
}

function Test-FabricWorkspaceAndLakehouse {
    <# V5.1 - workspace present and bound to the configured capacity; exactly one lakehouse. #>
    param(
        [Parameter(Mandatory)][hashtable]$Header,
        [Parameter(Mandatory)][string]$WorkspaceName,
        [Parameter(Mandatory)][string]$LakehouseName,
        [Parameter(Mandatory)][string]$CapacityId,
        [Parameter(Mandatory)]$Context
    )
    $workspace = Get-FabricWorkspaceByName -Header $Header -Name $WorkspaceName
    if ($null -eq $workspace) {
        return New-MlsCheckResult -Passed $false -Observed "workspace '$WorkspaceName' not returned by GET /v1/workspaces"
    }
    $workspaceId = "$(Get-MlsProperty -InputObject $workspace -Name 'id')"
    $workspaceCapacity = "$(Get-MlsProperty -InputObject $workspace -Name 'capacityId')"
    $Context.Evidence['workspaceId'] = $workspaceId
    $lakehouse = Get-FabricLakehouseByName -Header $Header -WorkspaceId $workspaceId -Name $LakehouseName
    if ($lakehouse.Count -ne 1) {
        return New-MlsCheckResult -Passed $false `
            -Observed "workspace '$WorkspaceName' ($workspaceId) present; lakehouse '$LakehouseName' resolved to $($lakehouse.Count) item(s)"
    }
    $Context.Evidence['lakehouseId'] = "$(Get-MlsProperty -InputObject $lakehouse[0] -Name 'id')"
    $sqlProperties = Get-MlsProperty -InputObject $lakehouse[0] -Name 'properties'
    $endpoint = Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $sqlProperties -Name 'sqlEndpointProperties') -Name 'connectionString'
    if ($endpoint) { $Context.Evidence['sqlEndpoint'] = "$endpoint" }
    # THE ITEM TELLS US WHERE ITS OWN DATA LIVES - do not build the OneLake URL by hand.
    # properties.oneLakeTablesPath is the absolute DFS path to this lakehouse's Tables
    # directory, and V5.2 probes it to find out whether this identity may read OneLake at
    # all. Deriving it beats concatenating workspace and item ids onto a hostname a rename
    # could strand (F90's class).
    $oneLakeTablesPath = Get-MlsProperty -InputObject $sqlProperties -Name 'oneLakeTablesPath'
    if ($oneLakeTablesPath) { $Context.Evidence['oneLakeTablesPath'] = "$oneLakeTablesPath" }
    if ($workspaceCapacity -and $CapacityId -and $workspaceCapacity -ne $CapacityId) {
        return New-MlsCheckResult -Passed $false `
            -Observed "workspace '$WorkspaceName' is bound to capacity '$workspaceCapacity', expected '$CapacityId'" `
            -Detail 'L05 failure mode 5: a stray workspace of the same name bound to another capacity must not be adopted - treat as drift.' -Final
    }
    return New-MlsCheckResult -Passed $true `
        -Observed "workspace $workspaceId on capacity '$workspaceCapacity'; lakehouse $($Context.Evidence['lakehouseId'])"
}

function Get-LakehouseTableListFromSql {
    <# The table list as the SQL analytics endpoint reports it. TABLE_TYPE = 'BASE TABLE'
       and TABLE_SCHEMA = 'dbo' are not written from memory: read live on 2026-09-03 the
       endpoint returns the ten seeded tables as dbo BASE TABLEs plus exactly one sys VIEW
       (dm_db_external_tables_log_status), so an unfiltered catalog read would report
       permanent drift against a correct lakehouse. #>
    param(
        [Parameter(Mandatory)][string]$SqlEndpoint,
        [Parameter(Mandatory)][string]$LakehouseName,
        [AllowEmptyString()][AllowNull()][string]$SqlAccessToken
    )
    $query = @"
SELECT TABLE_NAME AS t
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE' AND TABLE_SCHEMA = 'dbo'
"@
    $rows = @(Invoke-MlsSqlQuery -ServerName $SqlEndpoint -DatabaseName $LakehouseName -Query $query -AccessToken $SqlAccessToken)
    return @($rows | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 't')" })
}

function Test-LakehouseTableList {
    <#
    .SYNOPSIS
        V5.2 - set equality with the ten manifest tables: a missing table fails and so
        does an extra one (drift). Over a route this identity has been shown to be able
        to read.

    .DESCRIPTION
        EMPTY IS NOT THE SAME AS MISSING, AND THE FABRIC ROUTE MAKES THEM LOOK IDENTICAL.

        /lakehouses/<id>/tables returns HTTP 200 with an EMPTY ARRAY - not 403 - to a
        caller without OneLake read. So a Viewer sees a lakehouse with no tables in it,
        and a lakehouse that genuinely has no tables looks exactly the same (F105).

        The previous version of this function KNEW that and still could not act on it. It
        recognised the shape "every expected table absent and nothing unexpected present",
        printed an honest sentence about what the endpoint does - and then returned a
        plain FAIL, with no -Final, so the estate's most-likely-correct state produced a
        red criterion that spent thirty minutes re-asking a permission question. On the
        2026-09-03 rebuild it ran 03:59:25 -> 04:29:33 to reach a verdict that was settled
        at minute zero (F169's shape, in L5).

        Two things were missing, and this is both of them.

        1. AN OBSERVABILITY PROBE. A heuristic over the answer cannot establish whether
           the answer means anything. Test-OneLakeReadable asks OneLake directly, and
           OneLake - unlike the Fabric route - answers 403 rather than []. That converts
           "this shape usually means denial" into an observation.

        2. A ROUTE THE LEAST-PRIVILEGED AUDITOR ACTUALLY HAS. Fabric's four workspace
           roles are Admin, Member, Contributor and Viewer, and mls-verifier holds Viewer
           because the Verifier is read-only by contract. Viewer can read the SQL
           analytics endpoint - V5.3 proves it every run - and cannot read OneLake. The
           deploy identity is Contributor and lists all ten by name in the same minutes.
           Same lakehouse, same endpoint, different role: on the 2026-09-03 rebuild the
           deploy job logged "10 reported by Fabric" at 03:58 and the Verifier read []
           from 03:59.

           So the fix is NOT to give the auditor OneLake read. Contributor is the lowest
           Fabric role that carries it, and Contributor can write - escalating the
           Verifier to make a criterion convenient would trade the architectural boundary
           for a table list. The fix is to read the list over the route Viewer has, and to
           SAY which route answered.

        Outcomes, in order:
          OneLake readable  -> the Fabric list is meaningful; an empty one is a REAL empty
                               lakehouse and fails as such.
          OneLake denied    -> the Fabric list is UNOBSERVABLE; fall back to the SQL
                               analytics catalog and record that that is what happened.
          neither           -> UNOBSERVABLE and -Final. Never "the tables are missing".
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Header,
        [Parameter(Mandatory)][string[]]$ExpectedTable,
        [Parameter(Mandatory)]$Context,
        [AllowEmptyString()][AllowNull()][string]$OneLakeToken,
        [AllowEmptyString()][AllowNull()][string]$SqlEndpoint,
        [AllowEmptyString()][AllowNull()][string]$SqlAccessToken,
        [Parameter(Mandatory)][string]$LakehouseName
    )
    if (-not $Context.Evidence.Contains('workspaceId') -or -not $Context.Evidence.Contains('lakehouseId')) {
        return New-MlsCheckResult -Passed $false -Observed 'UNOBSERVABLE: workspace/lakehouse ids unknown - V5.1 did not resolve them' -Final
    }

    $oneLake = Test-OneLakeReadable `
        -TablesPath $(if ($Context.Evidence.Contains('oneLakeTablesPath')) { "$($Context.Evidence['oneLakeTablesPath'])" } else { '' }) `
        -Token $OneLakeToken
    $Context.Evidence['oneLakeRead'] = $oneLake.Evidence

    if ($oneLake.Readable) {
        $uri = "$($script:FabricApiBaseUrl)/workspaces/$($Context.Evidence['workspaceId'])/lakehouses/$($Context.Evidence['lakehouseId'])/tables"
        $tables = @(Get-MlsCollection -Response (Invoke-MlsRest -Uri $uri -Header $Header) |
                ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'name')" })
        $comparison = Test-MlsSetEquality -Actual $tables -Expected $ExpectedTable
        if ($comparison.Equal) {
            return New-MlsCheckResult -Passed $true `
                -Observed "$($oneLake.Evidence) | Fabric /tables: $($tables.Count) tables: $(($tables | Sort-Object) -join ', ')"
        }
        return New-MlsCheckResult -Passed $false `
            -Observed "$($oneLake.Evidence) | Fabric /tables: missing [$($comparison.Missing -join ', ')]; extra [$($comparison.Extra -join ', ')]" `
            -Detail 'OneLake read is CONFIRMED for this identity, so this list is what the lakehouse holds rather than what the caller may see: a short list here is a real seeding failure or real drift. Table registration after Delta writes can lag the load by several minutes; the 30-minute window covers that.'
    }

    # The Fabric route cannot be believed. Fall back, or say nothing.
    if ([string]::IsNullOrWhiteSpace($SqlEndpoint)) {
        return New-MlsCheckResult -Passed $false `
            -Observed "UNOBSERVABLE: $($oneLake.Evidence) | and no SQL analytics endpoint was available to read the table list any other way" `
            -Detail "Neither route could answer, so this criterion reports that it could not look rather than that the tables are missing (F105). V5.1's lakehouse metadata carries properties.sqlEndpointProperties.connectionString; supply it with -SqlEndpoint / `$env:MLS_SQL_ENDPOINT when the metadata omits it. A permission state does not change by waiting, so this does not retry." -Final
    }
    $tables = Get-LakehouseTableListFromSql -SqlEndpoint $SqlEndpoint -LakehouseName $LakehouseName -SqlAccessToken $SqlAccessToken
    $comparison = Test-MlsSetEquality -Actual $tables -Expected $ExpectedTable
    $route = "$($oneLake.Evidence) | table list read from the SQL analytics endpoint instead: INFORMATION_SCHEMA.TABLES on $SqlEndpoint/$LakehouseName returned $($tables.Count) dbo BASE TABLEs"
    if ($comparison.Equal) {
        return New-MlsCheckResult -Passed $true -Observed "$route`: $(($tables | Sort-Object) -join ', ')"
    }
    return New-MlsCheckResult -Passed $false `
        -Observed "$route`: missing [$($comparison.Missing -join ', ')]; extra [$($comparison.Extra -join ', ')]" `
        -Detail 'Read over the SQL analytics endpoint because OneLake refused this identity. That route sees a Delta table only once the endpoint has synced it, which is the propagation the 30-minute window exists for; it is also a slightly weaker drift check than OneLake, because an unsynced EXTRA table would not appear here yet. If this stays short after the window, compare against the deploy job''s own "N reported by Fabric" line before concluding the seed failed.'
}

function Test-SeededRowCount {
    <# V5.3 - deterministic seed 20260822, so the counts are exact, with no tolerance band. #>
    param(
        [Parameter(Mandatory)][string[]]$ExpectedTable,
        [Parameter(Mandatory)][int]$ExpectedLaunchCount,
        [AllowNull()]$ExpectedCount,
        [AllowEmptyString()][string]$SqlEndpoint,
        [AllowEmptyString()][AllowNull()][string]$SqlAccessToken,
        [Parameter(Mandatory)][string]$LakehouseName
    )
    if ([string]::IsNullOrWhiteSpace($SqlEndpoint)) {
        return New-MlsCheckResult -Passed $false `
            -Observed 'no SQL analytics endpoint available' `
            -Detail "V5.1's lakehouse metadata carries properties.sqlEndpointProperties.connectionString; supply it with -SqlEndpoint / `$env:MLS_SQL_ENDPOINT when the metadata omits it. Reads on a PAUSED capacity fail - run V5.1-V5.3 inside the resumed window." -Final
    }
    $query = (@($ExpectedTable | ForEach-Object { "SELECT '$_' AS t, COUNT(*) AS n FROM $_" }) -join ' UNION ALL ')
    $rows = @(Invoke-MlsSqlQuery -ServerName $SqlEndpoint -DatabaseName $LakehouseName -Query $query -AccessToken $SqlAccessToken)
    $observed = [ordered]@{}
    foreach ($row in $rows) {
        $observed["$(Get-MlsProperty -InputObject $row -Name 't')"] = [int](Get-MlsProperty -InputObject $row -Name 'n')
    }
    $describe = (@($observed.Keys) | ForEach-Object { "$_=$($observed[$_])" }) -join ', '

    if (-not $observed.Contains('launches')) {
        return New-MlsCheckResult -Passed $false -Observed "the endpoint returned no row for 'launches' ($describe)"
    }
    if ($observed['launches'] -ne $ExpectedLaunchCount) {
        return New-MlsCheckResult -Passed $false `
            -Observed "launches=$($observed['launches']), expected exactly $ExpectedLaunchCount ($describe)" `
            -Detail 'No tolerance band: a deviation means non-determinism or a partial load. Remediation is wipe-and-reseed, never re-baselining the seed contract (L05 failure mode 3).' -Final
    }
    if ($null -eq $ExpectedCount) {
        return New-MlsCheckResult -Status 'SKIP' `
            -Observed "launches=$ExpectedLaunchCount verified; other nine tables unverified ($describe)" `
            -Detail "Track A's expected-counts fixture (data/generators/tests/expected_counts.json) is absent, so only the plan-pinned launches count could be checked. Pass -ExpectedCountPath to close this criterion; recording SKIP rather than passing on one table out of ten."
    }
    $mismatch = [System.Collections.Generic.List[string]]::new()
    foreach ($property in $ExpectedCount.PSObject.Properties) {
        if (-not $observed.Contains($property.Name)) {
            $mismatch.Add("$($property.Name) absent from the endpoint result")
            continue
        }
        if ([int]$property.Value -ne $observed[$property.Name]) {
            $mismatch.Add("$($property.Name)=$($observed[$property.Name]), expected $([int]$property.Value)")
        }
    }
    if ($mismatch.Count -gt 0) {
        return New-MlsCheckResult -Passed $false -Observed ($mismatch -join '; ') `
            -Detail 'Deterministic seed 20260822: any deviation is a partial load, a double-append, or generator drift - all hard failures.' -Final
    }
    return New-MlsCheckResult -Passed $true -Observed $describe
}

function Test-CapacityPaused {
    <# V5.4 - paid F2 must read Paused; the trial capacity exposes no pause control and
       bills $0, which the playbook records as the accepted equivalent. #>
    param(
        [Parameter(Mandatory)][string]$CapacityId,
        [Parameter(Mandatory)][hashtable]$Header
    )
    if ($CapacityId -like '/subscriptions/*') {
        $state = Invoke-MlsAz -AllowFailure -Raw -Argument @(
            'resource', 'show', '--ids', $CapacityId, '--query', 'properties.state', '--output', 'tsv'
        )
        $stateValue = "$state".Trim()
        if ($stateValue -eq 'Paused') {
            return New-MlsCheckResult -Passed $true -Observed 'properties.state = Paused'
        }
        return New-MlsCheckResult -Passed $false -Observed "properties.state = '$stateValue', expected 'Paused'" `
            -Detail 'A capacity left resumed is a cost anomaly: pause it immediately (a spend decrease needs no gate) and root-cause why the layer''s finally-pause step did not run (L05 failure mode 2).'
    }
    $capacities = @(Get-MlsCollection -Response (Invoke-MlsRest -Uri "$($script:FabricApiBaseUrl)/capacities" -Header $Header))
    $found = @($capacities | Where-Object { (Get-MlsProperty -InputObject $_ -Name 'id') -eq $CapacityId })
    if ($found.Count -eq 0) {
        return New-MlsCheckResult -Passed $false -Observed "capacity '$CapacityId' is not visible through GET /v1/capacities"
    }
    $sku = "$(Get-MlsProperty -InputObject $found[0] -Name 'sku')"
    $state = "$(Get-MlsProperty -InputObject $found[0] -Name 'state')"
    # TRIAL SKUs ARE THE FT* FAMILY, NOT THE TWO LITERALS THIS ONCE MATCHED (F114).
    #
    # The pattern was '^(Trial|FT1)$'. The live trial capacity reports **FTL4**, so it
    # matched neither, fell through to the paid branch, and reported
    #
    #   state=Active on paid SKU 'FTL4', expected 'Paused'
    #
    # calling a free trial capacity a PAID one and failing the criterion on a cost anomaly
    # that does not exist. Two SKU names written from memory, which is precisely what
    # CLAUDE.md's "a constant that names something in another system is verified against
    # that system" is about - and this one was never checked because the trial capacity
    # was not created until long after the check was written.
    #
    # Paid capacities are F<number> (F2, F64). Trial capacities are FT<something> - FT1
    # historically, FTL<n> now. The prefix is what distinguishes them, and matching on it
    # survives the next rename of the trial tier, which a literal list does not.
    if ($sku -match '^(Trial|FT)') {
        return New-MlsCheckResult -Passed $true -Observed "state=$state (trial SKU '$sku', `$0/hr)" `
            -Detail 'Trial phase equivalence per L05.md V5.4: trial capacities expose no pause control and bill $0. This criterion re-arms verbatim (Paused required) the moment G2 moves the workspace to paid F2.'
    }
    if ($state -eq 'Paused') {
        return New-MlsCheckResult -Passed $true -Observed "state=Paused (sku $sku)"
    }
    return New-MlsCheckResult -Passed $false -Observed "state=$state on paid SKU '$sku', expected 'Paused'" `
        -Detail 'Paid capacity left resumed - immediate cost anomaly (risk register item 4).'
}

function Invoke-Main {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is consumed inside the criterion scriptblocks; PSSA cannot see through scriptblock closures.')]
    param(
        [string]$FabricCapacityId,
        [string]$FabricToken,
        [string]$WorkspaceName = 'mls-operations',
        [string]$LakehouseName = 'mls_operations',
        [string[]]$ExpectedTable = @(),
        [int]$ExpectedLaunchCount = 1200,
        [string]$ExpectedCountPath,
        [string]$SqlEndpoint,
        [string]$SqlAccessToken,
        [string]$OneLakeToken,
        [string]$ReportRoot,
        [switch]$NoRetry,
        [string[]]$OnlyCriterion = @()
    )
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $capacityId = Resolve-MlsInput -Name 'FabricCapacityId' -Value $FabricCapacityId -EnvironmentVariable @('FABRIC_CAPACITY_ID') `
        -Hint 'V5.1 binds the workspace to this capacity and V5.4 reads its state; the audit cannot guess it.'
    $token = Get-VerifierFabricToken -Token $FabricToken
    $header = Get-FabricAuthHeader -Token $token

    $countPath = $ExpectedCountPath
    if ([string]::IsNullOrWhiteSpace($countPath)) {
        $countPath = [Environment]::GetEnvironmentVariable('MLS_EXPECTED_COUNTS')
    }
    if ([string]::IsNullOrWhiteSpace($countPath)) {
        $countPath = Join-Path -Path $repoRoot -ChildPath 'data' -AdditionalChildPath 'generators', 'tests', 'expected_counts.json'
    }
    $expectedCount = $null
    if (Test-Path -LiteralPath $countPath) {
        $expectedCount = Get-MlsJsonFile -Path $countPath -Purpose 'Track A expected row counts for seed 20260822'
    }

    $context = New-MlsAuditContext -Layer 5 -Title 'Fabric workspace, lakehouse, generators, seeding' `
        -ScriptName 'verification/layer-05-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry `
        -OnlyCriterion $OnlyCriterion
    Add-MlsPreflight -Context $context -Name 'Capacity' -Value $capacityId
    Add-MlsPreflight -Context $context -Name 'Fabric token' -Value 'present (value never logged)'
    Add-MlsPreflight -Context $context -Name 'Expected-counts fixture' -Value $countPath `
        -Status $(if ($null -ne $expectedCount) { 'OK' } else { 'ABSENT' })

    # -Control @(): existence/provisioning check for the workspace and lakehouse. No CUI
    # protection is asserted - it is a precondition for V5.2's inventory check.
    # L05: workspace/lakehouse reads, not the SQL endpoint sync
    Invoke-MlsCriterion -Context $context -Id 'V5.1' -Control @() `
        -Description 'Fabric REST: workspace + lakehouse exist' `
        -Command "GET $($script:FabricApiBaseUrl)/workspaces  # displayName eq '$WorkspaceName'`nGET $($script:FabricApiBaseUrl)/workspaces/<id>/lakehouses  # displayName eq '$LakehouseName'" `
        -Expected "workspace '$WorkspaceName' bound to the configured capacity; exactly one lakehouse '$LakehouseName'" `
        -RetryWindowMinutes 10 `
        -Test {
        Test-FabricWorkspaceAndLakehouse -Header $header -WorkspaceName $WorkspaceName `
            -LakehouseName $LakehouseName -CapacityId $capacityId -Context $context
    } | Out-Null

    # RESOLVED BEFORE V5.2, NOT AFTER IT. V5.2 needs the SQL analytics endpoint too now:
    # when OneLake refuses this identity, the catalog there is the only route to the table
    # list that a Viewer can actually read.
    $endpoint = $SqlEndpoint
    if ([string]::IsNullOrWhiteSpace($endpoint)) { $endpoint = [Environment]::GetEnvironmentVariable('MLS_SQL_ENDPOINT') }
    if ([string]::IsNullOrWhiteSpace($endpoint) -and $context.Evidence.Contains('sqlEndpoint')) {
        $endpoint = "$($context.Evidence['sqlEndpoint'])"
    }

    # The Fabric SQL analytics endpoint is Entra-only, exactly like the L6 Azure SQL server,
    # so V5.3 needs a bearer token. Explicit value, then the environment, then MlsAudit mints
    # one from the mls-verifier login. The value is never written to the report.
    $sqlToken = $SqlAccessToken
    if ([string]::IsNullOrWhiteSpace($sqlToken)) { $sqlToken = [Environment]::GetEnvironmentVariable('MLS_SQL_ACCESS_TOKEN') }

    Add-MlsPreflight -Context $context -Name 'SQL access token' `
        -Value $(if ($sqlToken) { 'supplied (value never logged)' } else { 'minted from the current az login at query time' })

    $oneLakeToken = Get-VerifierOneLakeToken -Token $OneLakeToken
    Add-MlsPreflight -Context $context -Name 'OneLake token' `
        -Value $(if ($oneLakeToken) { 'present (value never logged) - V5.2 probes OneLake read with it' } else { 'could not be minted; V5.2 will report what it therefore could not establish' }) `
        -Status $(if ($oneLakeToken) { 'OK' } else { 'ABSENT' })

    # L05: the SQL analytics endpoint syncs new Delta tables slowly
    Invoke-MlsCriterion -Context $context -Id 'V5.2' -Control @('3.4.1') `
        -Description 'Table list matches manifest' `
        -Command "GET <properties.oneLakeTablesPath>?resource=filesystem   # can this identity read OneLake at all?`nGET $($script:FabricApiBaseUrl)/workspaces/<id>/lakehouses/<id>/tables   # only believed when the probe above says yes`nSELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE' AND TABLE_SCHEMA = 'dbo'   # the route a Viewer has" `
        -Expected "exactly the 10 tables: $($ExpectedTable -join ', ') (set equality), read over a route this identity was first shown to be able to read" `
        -RetryWindowMinutes 30 `
        -Test {
        Test-LakehouseTableList -Header $header -ExpectedTable $ExpectedTable -Context $context `
            -OneLakeToken $oneLakeToken -SqlEndpoint $endpoint -SqlAccessToken $sqlToken -LakehouseName $LakehouseName
    } | Out-Null

    # -Control @(): deterministic seed row-count check over synthetic, fictional demo data
    # (CLAUDE.md: synthetic data only) - a data-integrity check, not a CUI protection
    # assertion.
    # L05: reads the sync V5.2 has already waited out
    Invoke-MlsCriterion -Context $context -Id 'V5.3' -Control @() `
        -Description 'SQL analytics endpoint returns expected row counts (launches = 1,200 +/- 0)' `
        -Command "SELECT 'launches' AS t, COUNT(*) AS n FROM launches UNION ALL ... (one arm per table, all 10) -- against the lakehouse SQL analytics endpoint as mls-verifier" `
        -Expected "launches = $ExpectedLaunchCount exactly; the other nine equal to Track A's committed fixture" `
        -RetryWindowMinutes 10 `
        -Test {
        Test-SeededRowCount -ExpectedTable $ExpectedTable -ExpectedLaunchCount $ExpectedLaunchCount `
            -ExpectedCount $expectedCount -SqlEndpoint $endpoint -SqlAccessToken $sqlToken -LakehouseName $LakehouseName
    } | Out-Null

    # -Control @(): idle-cost control (capacity paused when unused). Cost/FinOps, not CUI
    # protection.
    Invoke-MlsCriterion -Context $context -Id 'V5.4' -Control @() `
        -Description 'Capacity state == Paused after layer completes' `
        -Command "az resource show --ids $capacityId --query properties.state   # paid F2`nGET $($script:FabricApiBaseUrl)/capacities                       # trial phase" `
        -Expected 'paid F2: "Paused" exactly. Trial: state recorded as the accepted $0/hr equivalent' `
        -RetryWindowMinutes 5 -PollIntervalSeconds 300 `
        -Test { Test-CapacityPaused -CapacityId $capacityId -Header $header } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -FabricCapacityId $FabricCapacityId -FabricToken $FabricToken `
            -WorkspaceName $WorkspaceName -LakehouseName $LakehouseName -ExpectedTable $ExpectedTable `
            -ExpectedLaunchCount $ExpectedLaunchCount -ExpectedCountPath $ExpectedCountPath `
            -SqlEndpoint $SqlEndpoint -SqlAccessToken $SqlAccessToken -OneLakeToken $OneLakeToken `
            -ReportRoot $ReportRoot -NoRetry:$NoRetry -OnlyCriterion $OnlyCriterion
    }
    catch {
        Write-MlsStatus -Message "layer-05-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
