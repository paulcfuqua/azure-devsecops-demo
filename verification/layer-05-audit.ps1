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
    if ($workspaceCapacity -and $CapacityId -and $workspaceCapacity -ne $CapacityId) {
        return New-MlsCheckResult -Passed $false `
            -Observed "workspace '$WorkspaceName' is bound to capacity '$workspaceCapacity', expected '$CapacityId'" `
            -Detail 'L05 failure mode 5: a stray workspace of the same name bound to another capacity must not be adopted - treat as drift.' -Final
    }
    return New-MlsCheckResult -Passed $true `
        -Observed "workspace $workspaceId on capacity '$workspaceCapacity'; lakehouse $($Context.Evidence['lakehouseId'])"
}

function Test-LakehouseTableList {
    <# V5.2 - set equality with the ten manifest tables: a missing table fails and so does
       an extra one (drift). #>
    param(
        [Parameter(Mandatory)][hashtable]$Header,
        [Parameter(Mandatory)][string[]]$ExpectedTable,
        [Parameter(Mandatory)]$Context
    )
    if (-not $Context.Evidence.Contains('workspaceId') -or -not $Context.Evidence.Contains('lakehouseId')) {
        return New-MlsCheckResult -Passed $false -Observed 'workspace/lakehouse ids unknown - V5.1 did not resolve them' -Final
    }
    $uri = "$($script:FabricApiBaseUrl)/workspaces/$($Context.Evidence['workspaceId'])/lakehouses/$($Context.Evidence['lakehouseId'])/tables"
    $tables = @(Get-MlsCollection -Response (Invoke-MlsRest -Uri $uri -Header $Header) |
            ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'name')" })
    $comparison = Test-MlsSetEquality -Actual $tables -Expected $ExpectedTable
    if ($comparison.Equal) {
        return New-MlsCheckResult -Passed $true -Observed "$($tables.Count) tables: $(($tables | Sort-Object) -join ', ')"
    }
    return New-MlsCheckResult -Passed $false `
        -Observed "missing [$($comparison.Missing -join ', ')]; extra [$($comparison.Extra -join ', ')]" `
        -Detail 'Table registration after Delta writes can lag the load by several minutes; the 30-minute window covers that.'
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
    if ($sku -match '^(Trial|FT1)$') {
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

    # L05: the SQL analytics endpoint syncs new Delta tables slowly
    Invoke-MlsCriterion -Context $context -Id 'V5.2' -Control @('3.4.1') `
        -Description 'Table list matches manifest' `
        -Command "GET $($script:FabricApiBaseUrl)/workspaces/<id>/lakehouses/<id>/tables" `
        -Expected "exactly the 10 tables: $($ExpectedTable -join ', ') (set equality)" `
        -RetryWindowMinutes 30 `
        -Test { Test-LakehouseTableList -Header $header -ExpectedTable $ExpectedTable -Context $context } | Out-Null

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
            -SqlEndpoint $SqlEndpoint -SqlAccessToken $SqlAccessToken -ReportRoot $ReportRoot -NoRetry:$NoRetry `
            -OnlyCriterion $OnlyCriterion
    }
    catch {
        Write-MlsStatus -Message "layer-05-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
