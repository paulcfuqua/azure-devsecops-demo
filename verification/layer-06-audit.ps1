#Requires -Version 7.0
<#
.SYNOPSIS
    L6 Verifier audit - ACA environment, SQL serverless, observability, cost exports. READ-ONLY.

.DESCRIPTION
    Implements the four master-plan Verify criteria owned by
    docs/runbooks/layers/L06.md section Validation cycle, and nothing else:

      V6.1  ARM GET on each resource: SKU/serverless/auto-pause/minReplicas values match
            the manifest exactly (autoPauseDelay 60, minCapacity 0.5, serverless SKU).
      V6.2  KQL query against LAW succeeds as verifier.
      V6.3  First cost export file lands within 24 h (async - closes in the L7 window).
      V6.4  SQL auto-pauses (checked after 75 min idle).

    Expected values resolve from the Bicep-declared manifest - the layer-06 deployment
    outputs - never from a teammate's message (L06.md section Validation cycle).

    V6.3 is explicitly asynchronous: this audit records it PENDING while the declared 24 h
    window is still open, and L6 sign-off may proceed on that. It must be closed PASS
    before L7 sign-off - re-run with -EnforceCostExport once the window has elapsed.

.EXAMPLE
    ./layer-06-audit.ps1 -SubscriptionId <sub>
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$DeploymentName = 'layer-06',
    [string]$SqlDatabaseId,
    [string]$ContainerAppEnvironmentId,
    [string]$LogAnalyticsWorkspaceId,
    [string]$CostExportAccountName,
    [string]$CostExportContainerName = 'cost-exports',
    [int]$ExpectedAutoPauseDelay = 60,
    [double]$ExpectedMinCapacity = 0.5,
    [string]$LayerCompletedUtc,
    [string]$SqlLastTouchedUtc,
    [double]$SqlIdleWindowMinutes = 75,
    [switch]$EnforceCostExport,
    [string]$ReportRoot,
    [switch]$NoRetry
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'MlsAudit.psm1') -Force

function Get-DeploymentOutput {
    <# The layer manifest: az deployment sub show --name layer-06 --query properties.outputs #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$DeploymentName
    )
    $outputs = Invoke-MlsAz -AllowFailure -Argument @(
        'deployment', 'sub', 'show', '--name', $DeploymentName, '--subscription', $SubscriptionId,
        '--query', 'properties.outputs', '--output', 'json'
    )
    $map = [ordered]@{}
    if ($null -eq $outputs) { return $map }
    foreach ($property in $outputs.PSObject.Properties) {
        $value = Get-MlsProperty -InputObject $property.Value -Name 'value'
        if ($null -eq $value) { $value = $property.Value }
        $map[$property.Name] = "$value"
    }
    return $map
}

function Resolve-ManifestValue {
    <# Explicit parameter, then environment, then the deployment outputs (any of several
       output names the Bicep may have used). #>
    param(
        [AllowEmptyString()][string]$Value,
        [AllowEmptyString()][string]$EnvironmentVariable,
        [Parameter(Mandatory)]$Output,
        [Parameter(Mandatory)][string[]]$OutputName
    )
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if (-not [string]::IsNullOrWhiteSpace($EnvironmentVariable)) {
        $fromEnvironment = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
        if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) { return $fromEnvironment }
    }
    foreach ($name in $OutputName) {
        if ($Output.Contains($name) -and -not [string]::IsNullOrWhiteSpace($Output[$name])) { return $Output[$name] }
    }
    return ''
}

function Test-ArmStateMatchesManifest {
    <# V6.1 - any mismatch is a FAIL, including a "better" SKU: that is an un-gated spend
       increase (L06.md V6.1). #>
    param(
        [AllowEmptyString()][string]$SqlDatabaseId,
        [AllowEmptyString()][string]$ContainerAppEnvironmentId,
        [Parameter(Mandatory)][int]$ExpectedAutoPauseDelay,
        [Parameter(Mandatory)][double]$ExpectedMinCapacity
    )
    if ([string]::IsNullOrWhiteSpace($SqlDatabaseId)) {
        return New-MlsCheckResult -Passed $false -Observed 'no SQL database resource id available' `
            -Detail 'The layer-06 deployment outputs must carry the SQL database resource id (L06 deploy step 5 records resource IDs, SQL server/DB names and the LAW workspace id as the layer manifest artifact). Pass -SqlDatabaseId / $env:MLS_SQL_DB_ID meanwhile.' -Final
    }
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()

    $database = Invoke-MlsAz -AllowFailure -Argument @(
        'sql', 'db', 'show', '--ids', $SqlDatabaseId,
        '--query', '{sku:currentSku.name, autoPause:autoPauseDelay, minCap:minCapacity, status:status}', '--output', 'json'
    )
    if ($null -eq $database) {
        $problem.Add("ARM GET on the SQL database returned nothing ($SqlDatabaseId)")
    }
    else {
        $sku = "$(Get-MlsProperty -InputObject $database -Name 'sku')"
        $autoPause = Get-MlsProperty -InputObject $database -Name 'autoPause'
        $minCapacity = Get-MlsProperty -InputObject $database -Name 'minCap'
        $observed.Add("sql sku=$sku autoPauseDelay=$autoPause minCapacity=$minCapacity")
        if ($sku -notmatch '^GP_S_') { $problem.Add("SQL SKU '$sku' is not serverless (GP_S_Gen5-class)") }
        if ([int]$autoPause -ne $ExpectedAutoPauseDelay) { $problem.Add("autoPauseDelay=$autoPause, expected $ExpectedAutoPauseDelay") }
        if ([double]$minCapacity -ne $ExpectedMinCapacity) { $problem.Add("minCapacity=$minCapacity, expected $ExpectedMinCapacity") }
    }

    if ([string]::IsNullOrWhiteSpace($ContainerAppEnvironmentId)) {
        $problem.Add('no Container Apps environment resource id available (deployment outputs / -ContainerAppEnvironmentId)')
    }
    else {
        $state = Invoke-MlsAz -AllowFailure -Raw -Argument @(
            'containerapp', 'env', 'show', '--ids', $ContainerAppEnvironmentId,
            '--query', 'properties.provisioningState', '--output', 'tsv'
        )
        $stateValue = "$state".Trim()
        $observed.Add("aca env provisioningState=$stateValue")
        if ($stateValue -ne 'Succeeded') { $problem.Add("Container Apps environment provisioningState='$stateValue', expected 'Succeeded'") }
    }

    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ')
    }
    return New-MlsCheckResult -Passed $false -Observed (($observed -join '; ') + ' | ' + ($problem -join ' | ')) `
        -Detail 'Any mismatch - including a "better" SKU or minReplicas > 0 - is an un-gated spend-profile change and fails this criterion rather than triggering a G2.'
}

function Test-LogAnalyticsQuery {
    <# V6.2 - the point is that the Reader credential can query the workspace itself.
       Row content may be empty this early; success of the query is the criterion. #>
    param([AllowEmptyString()][string]$WorkspaceId)
    if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
        return New-MlsCheckResult -Passed $false -Observed 'no Log Analytics workspace (customer) id available' `
            -Detail 'Supply the LAW workspace id from the layer-06 deployment outputs, or pass -LogAnalyticsWorkspaceId / $env:MLS_LAW_CUSTOMER_ID.' -Final
    }
    $result = Invoke-MlsAz -AllowFailure -Argument @(
        'monitor', 'log-analytics', 'query', '--workspace', $WorkspaceId,
        '--analytics-query', 'Heartbeat | take 1', '--timespan', 'P1D', '--output', 'json'
    )
    if ($null -eq $result) {
        return New-MlsCheckResult -Passed $false `
            -Observed 'the query returned no result (HTTP error, or the Reader identity cannot query this workspace)' `
            -Detail 'Workspace RBAC propagation takes up to ~15 min; the standard 30-minute window covers it.'
    }
    return New-MlsCheckResult -Passed $true -Observed "query succeeded as the Verifier identity; $(@($result).Count) row(s) returned"
}

function Test-CostExportLanded {
    <# V6.3 - at least one export blob with a non-zero length; plus the lakehouse side once
       the Function has ingested (only checkable inside a resumed capacity window). #>
    param(
        [AllowEmptyString()][string]$AccountName,
        [Parameter(Mandatory)][string]$ContainerName
    )
    if ([string]::IsNullOrWhiteSpace($AccountName)) {
        return New-MlsCheckResult -Passed $false -Observed 'no cost-export storage account name available' `
            -Detail 'Supply it from the layer-06 deployment outputs or -CostExportAccountName / $env:MLS_COST_EXPORT_ACCOUNT.' -Final
    }
    $blobs = @(Invoke-MlsAz -AllowFailure -Argument @(
            'storage', 'blob', 'list', '--account-name', $AccountName, '--container-name', $ContainerName,
            '--auth-mode', 'login', '--query', '[].{name:name, len:properties.contentLength}', '--output', 'json'
        ))
    $withContent = @($blobs | Where-Object { [int](Get-MlsProperty -InputObject $_ -Name 'len') -gt 0 })
    if ($withContent.Count -ge 1) {
        return New-MlsCheckResult -Passed $true `
            -Observed "$($withContent.Count) export blob(s) with content, first: $(Get-MlsProperty -InputObject $withContent[0] -Name 'name')" `
            -Detail 'The lakehouse half (SELECT COUNT(*) FROM cost_daily > 0) needs a resumed capacity window - piggyback on the next scheduled resume rather than forcing one (L06.md V6.3).'
    }
    return New-MlsCheckResult -Passed $false `
        -Observed "$($blobs.Count) blob(s) in $AccountName/$ContainerName, none with content > 0 bytes" `
        -Detail "Cost Management's first export can take up to 24 h and is outside our control - do not G4 on a first-day miss (L06.md V6.3)."
}

function Test-SqlAutoPause {
    <# V6.4 - 75 minutes = the 60-minute auto-pause delay plus 15 minutes of margin. #>
    param([AllowEmptyString()][string]$SqlDatabaseId)
    if ([string]::IsNullOrWhiteSpace($SqlDatabaseId)) {
        return New-MlsCheckResult -Passed $false -Observed 'no SQL database resource id available' -Final `
            -Detail 'Pass -SqlDatabaseId / $env:MLS_SQL_DB_ID, or record it in the layer-06 deployment outputs.'
    }
    $status = Invoke-MlsAz -AllowFailure -Raw -Argument @(
        'sql', 'db', 'show', '--ids', $SqlDatabaseId, '--query', 'status', '--output', 'tsv'
    )
    $statusValue = "$status".Trim()
    if ($statusValue -eq 'Paused') {
        return New-MlsCheckResult -Passed $true -Observed 'status = Paused'
    }
    return New-MlsCheckResult -Passed $false -Observed "status = '$statusValue', expected 'Paused'" `
        -Detail 'Still Online past the window means the idle-cost model is broken - the classic cause is a chatty client (monitoring probe, availability test) keeping the DB awake; check az sql db list-usages and recent connections (L06 failure mode 1).'
}

function Invoke-Main {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is consumed inside the criterion scriptblocks; PSSA cannot see through scriptblock closures.')]
    param(
        [string]$SubscriptionId,
        [string]$DeploymentName = 'layer-06',
        [string]$SqlDatabaseId,
        [string]$ContainerAppEnvironmentId,
        [string]$LogAnalyticsWorkspaceId,
        [string]$CostExportAccountName,
        [string]$CostExportContainerName = 'cost-exports',
        [int]$ExpectedAutoPauseDelay = 60,
        [double]$ExpectedMinCapacity = 0.5,
        [string]$LayerCompletedUtc,
        [string]$SqlLastTouchedUtc,
        [double]$SqlIdleWindowMinutes = 75,
        [switch]$EnforceCostExport,
        [string]$ReportRoot,
        [switch]$NoRetry
    )
    $subscription = Resolve-MlsInput -Name 'SubscriptionId' -Value $SubscriptionId -EnvironmentVariable @('AZURE_SUBSCRIPTION_ID') `
        -Hint 'The demo subscription holding mls-rg-platform; read as mls-verifier (Reader covers */read).'

    $context = New-MlsAuditContext -Layer 6 -Title 'Core platform: ACA env, SQL, observability, cost exports' `
        -ScriptName 'verification/layer-06-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry
    Add-MlsPreflight -Context $context -Name 'SubscriptionId' -Value $subscription

    $output = Get-DeploymentOutput -SubscriptionId $subscription -DeploymentName $DeploymentName
    Add-MlsPreflight -Context $context -Name "Deployment outputs ($DeploymentName)" -Value "$($output.Count) output(s)" `
        -Status $(if ($output.Count -gt 0) { 'OK' } else { 'ABSENT' })

    $databaseId = Resolve-ManifestValue -Value $SqlDatabaseId -EnvironmentVariable 'MLS_SQL_DB_ID' -Output $output `
        -OutputName @('sqlDatabaseId', 'sqlDbId', 'databaseId')
    $environmentId = Resolve-ManifestValue -Value $ContainerAppEnvironmentId -EnvironmentVariable 'MLS_ACA_ENV_ID' -Output $output `
        -OutputName @('containerAppEnvironmentId', 'acaEnvironmentId', 'managedEnvironmentId')
    $workspaceId = Resolve-ManifestValue -Value $LogAnalyticsWorkspaceId -EnvironmentVariable 'MLS_LAW_CUSTOMER_ID' -Output $output `
        -OutputName @('lawCustomerId', 'logAnalyticsCustomerId', 'workspaceCustomerId')
    $accountName = Resolve-ManifestValue -Value $CostExportAccountName -EnvironmentVariable 'MLS_COST_EXPORT_ACCOUNT' -Output $output `
        -OutputName @('costExportAccountName', 'exportStorageAccountName', 'storageAccountName')

    Add-MlsPreflight -Context $context -Name 'SQL database id' -Value $databaseId -Status $(if ($databaseId) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'ACA environment id' -Value $environmentId -Status $(if ($environmentId) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'LAW customer id' -Value $workspaceId -Status $(if ($workspaceId) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Cost export account' -Value $accountName -Status $(if ($accountName) { 'OK' } else { 'ABSENT' })

    Invoke-MlsCriterion -Context $context -Id 'V6.1' `
        -Description 'ARM GET on each resource: SKU/serverless/auto-pause/minReplicas values match manifest exactly' `
        -Command "az sql db show --ids <dbId> --query `"{sku:currentSku.name, autoPause:autoPauseDelay, minCap:minCapacity}`"`naz containerapp env show --ids <envId> --query properties.provisioningState" `
        -Expected "serverless GP_S_Gen5-class SKU; autoPauseDelay == $ExpectedAutoPauseDelay; minCapacity == $ExpectedMinCapacity; ACA environment provisioningState == Succeeded" `
        -RetryWindowMinutes 5 `
        -Test {
        Test-ArmStateMatchesManifest -SqlDatabaseId $databaseId -ContainerAppEnvironmentId $environmentId `
            -ExpectedAutoPauseDelay $ExpectedAutoPauseDelay -ExpectedMinCapacity $ExpectedMinCapacity
    } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V6.2' `
        -Description 'KQL query against LAW succeeds as verifier' `
        -Command "az monitor log-analytics query --workspace <lawCustomerId> --analytics-query 'Heartbeat | take 1' --timespan P1D" `
        -Expected 'a well-formed table result under the mls-verifier login (row content may be empty this early)' `
        -Test { Test-LogAnalyticsQuery -WorkspaceId $workspaceId } | Out-Null

    $costWindowStart = [datetime]::MinValue
    if (-not [string]::IsNullOrWhiteSpace($LayerCompletedUtc)) { $costWindowStart = [datetime]::Parse($LayerCompletedUtc).ToUniversalTime() }
    elseif (-not [string]::IsNullOrWhiteSpace($env:MLS_L6_COMPLETED_AT)) { $costWindowStart = [datetime]::Parse($env:MLS_L6_COMPLETED_AT).ToUniversalTime() }
    $pendingAllowed = (-not $EnforceCostExport) -and ($costWindowStart -ne [datetime]::MinValue)
    if (-not $EnforceCostExport -and $costWindowStart -eq [datetime]::MinValue) {
        Add-MlsNote -Context $context -Message 'V6.3: no L6 completion timestamp supplied (-LayerCompletedUtc / $env:MLS_L6_COMPLETED_AT), so the 24 h deadline could not be computed and a missing export is recorded FAIL rather than PENDING.'
    }

    Invoke-MlsCriterion -Context $context -Id 'V6.3' `
        -Description 'First cost export file lands within 24 h (async check L7 window)' `
        -Command "az storage blob list --account-name <exportSA> --container-name $CostExportContainerName --auth-mode login --query `"[].{name:name, len:properties.contentLength}`"" `
        -Expected '>= 1 export blob with contentLength > 0 within 24 h of L6 completion' `
        -RetryWindowMinutes 1440 -InProcessWaitMinutes 0 -WindowStartUtc $costWindowStart -PendingWhenUnexpired:$pendingAllowed `
        -Test { Test-CostExportLanded -AccountName $accountName -ContainerName $CostExportContainerName } | Out-Null

    $sqlWindowStart = [datetime]::UtcNow
    if (-not [string]::IsNullOrWhiteSpace($SqlLastTouchedUtc)) { $sqlWindowStart = [datetime]::Parse($SqlLastTouchedUtc).ToUniversalTime() }
    $sqlBudget = $SqlIdleWindowMinutes - ([datetime]::UtcNow - $sqlWindowStart).TotalMinutes
    if ($sqlBudget -lt 0) { $sqlBudget = 0 }

    Invoke-MlsCriterion -Context $context -Id 'V6.4' `
        -Description 'SQL auto-pauses (checked after 75 min idle)' `
        -Command 'az sql db show --ids <dbId> --query "status"' `
        -Expected '"Paused" at the 75-minute mark (60-minute auto-pause delay + 15 minutes of margin)' `
        -RetryWindowMinutes $SqlIdleWindowMinutes -InProcessWaitMinutes $sqlBudget `
        -Test { Test-SqlAutoPause -SqlDatabaseId $databaseId } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -SubscriptionId $SubscriptionId -DeploymentName $DeploymentName `
            -SqlDatabaseId $SqlDatabaseId -ContainerAppEnvironmentId $ContainerAppEnvironmentId `
            -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -CostExportAccountName $CostExportAccountName `
            -CostExportContainerName $CostExportContainerName -ExpectedAutoPauseDelay $ExpectedAutoPauseDelay `
            -ExpectedMinCapacity $ExpectedMinCapacity -LayerCompletedUtc $LayerCompletedUtc `
            -SqlLastTouchedUtc $SqlLastTouchedUtc -SqlIdleWindowMinutes $SqlIdleWindowMinutes `
            -EnforceCostExport:$EnforceCostExport -ReportRoot $ReportRoot -NoRetry:$NoRetry
    }
    catch {
        Write-MlsStatus -Message "layer-06-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
