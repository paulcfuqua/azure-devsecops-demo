#Requires -Version 7.0
<#
.SYNOPSIS
    L6 Verifier audit - ACA environment, SQL serverless, observability, cost exports. READ-ONLY.

.DESCRIPTION
    Implements the four master-plan Verify criteria owned by
    docs/runbooks/layers/L06.md section Validation cycle, plus one remediation-era
    addition that is NOT a master-plan criterion (so it is not in the 43-row
    traceability table in docs/runbooks/layers/README.md, which is scoped exactly to
    master-plan criteria -- see that file's header invariant):

      V6.1  ARM GET on each resource: SKU/serverless/auto-pause/minReplicas values match
            the manifest exactly (autoPauseDelay 60, minCapacity 0.5, serverless SKU).
      V6.2  KQL query against LAW succeeds as verifier.
      V6.3  First cost export file lands within 24 h (async - closes in the L7 window).
      V6.4  SQL auto-pauses (checked after 75 min idle).
      V6.5  SQL backup posture (short-term retention + backup storage redundancy)
            matches the template-pinned values (F16, Task 18 -- CP-9; not a
            master-plan criterion, see docs/runbooks/layers/L06.md § Validation cycle).

    Expected values resolve from the Bicep-declared manifest - the layer-06 deployment
    outputs - never from a teammate's message (L06.md section Validation cycle).

    V6.3 is explicitly asynchronous: this audit records it PENDING while the declared 24 h
    window is still open, and L6 sign-off may proceed on that. It must be closed PASS
    before L7 sign-off - re-run with -EnforceCostExport once the window has elapsed.

    V6.4 is asynchronous in the same sense and gets the same treatment, but only when the
    caller says when the database was last touched. L06.md schedules the query "75 minutes
    after the last deployment touch of the DB", and kill-rebuild.md section 5 lists
    "V6.4 SQL auto-pause (+75 min)" among the criteria EXCLUDED from the <60-minute rebuild
    clock. So a pipeline that runs this audit immediately after the layer deploys must be
    able to record V6.4 without either waiting out the window (which would put 75 minutes
    of sleep on the critical path the clock measures) or failing a database that simply has
    not been idle long enough yet. -SqlLastTouchedUtc plus -SqlPauseWaitMinutes 0 gives
    PENDING; the re-check run, later and without a last-touched time, evaluates once and
    decides. With no -SqlLastTouchedUtc the behaviour is unchanged: still Online is a FAIL.

.EXAMPLE
    ./layer-06-audit.ps1 -SubscriptionId <sub>

.EXAMPLE
    # Inline, straight after the layer deployed: V6.3 and V6.4 both record PENDING with
    # their deadlines, everything else gates the layer, and nothing sleeps.
    ./layer-06-audit.ps1 -SubscriptionId <sub> -LayerCompletedUtc <iso> `
        -SqlLastTouchedUtc <iso> -SqlPauseWaitMinutes 0

.EXAMPLE
    # The async re-check, >= 75 minutes later: single evaluation, no grace.
    ./layer-06-audit.ps1 -SubscriptionId <sub> -EnforceCostExport -SqlPauseWaitMinutes 0
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
    [int]$ExpectedBackupRetentionDays = 7,
    [string]$ExpectedBackupStorageRedundancy = 'Local',
    [string]$LayerCompletedUtc,
    [string]$SqlLastTouchedUtc,
    [double]$SqlIdleWindowMinutes = 75,
    [double]$SqlPauseWaitMinutes = -1,
    [switch]$EnforceCostExport,
    # V6.7's subjects. Supplied by the workflow from the L6 outputs; when absent
    # they are derived from the same naming rule the templates use, so a local run
    # needs no arguments and a rebranded estate (MLS_COMPANY_PREFIX) still checks
    # its own apps rather than someone else's.
    [string]$FunctionResourceGroupName,
    [string[]]$FunctionAppName = @(),
    [string]$ReportRoot,
    [switch]$NoRetry,
    # Run only these criteria (e.g. -OnlyCriterion V6.2). Everything else reports SKIP
    # naming the reason, and the run exits 3 - a DIAGNOSTIC, never a sign-off (P-10).
    [string[]]$OnlyCriterion = @()
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

function Test-FunctionAppsHaveCode {
    <# V6.7 - A FUNCTION APP WITH NO FUNCTIONS IS NOT A DEPLOYED LAYER (F119).

       Every zip publish to every Function App in this estate failed, from the day
       it was built, and L6 reported SUCCESS every time:

           InaccessibleStorageException: Failed to access storage account for
           deployment: BlobUploadFailedException: ... 403

       The deployment storage account never declared networkAcls, so the module
       applied its own secure default (Deny + AzureServices bypass) - and Flex
       Consumption's package upload is not covered by that bypass. The fix is a
       resource instance rule per site, in the template.

       WHY THIS CRITERION EXISTS RATHER THAN A LOUDER DEPLOY STEP. Both publish
       steps carry `continue-on-error: true`, deliberately and correctly: the
       verify job is `needs: [preflight, deploy]` and requires deploy to succeed,
       so a non-critical publish must not be able to starve the audit. That choice
       is asserted by cost-ingest.Tests.ps1 and it is the right one - the Verifier
       judging a layer is worth more than a deploy step vetoing it.

       What the flag cost was VISIBILITY, and visibility is this file's job. So the
       deploy step keeps its flag and the audit gains the ability to see what it
       hid. This is the estate's own rule applied to its own pipeline: assert the
       CAPABILITY - code is present and listable - not the artefact that usually
       accompanies it, which was "the publish step ran".

       OBSERVABILITY IS ESTABLISHED BEFORE ABSENCE IS REPORTED. The functions
       endpoint answers 403 to a caller without rights and an empty list to a
       caller with them and nothing deployed, and those must never be conflated -
       the entire absence-vs-denial class this repository keeps paying for. A
       non-success response is therefore UNOBSERVABLE, never "no functions". #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string[]]$FunctionAppName
    )
    $observed = [System.Collections.Generic.List[string]]::new()
    $problem = [System.Collections.Generic.List[string]]::new()
    $unobservable = [System.Collections.Generic.List[string]]::new()

    foreach ($name in $FunctionAppName) {
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" +
               "/providers/Microsoft.Web/sites/$name/functions?api-version=2023-12-01"
        $raw = Invoke-MlsAz -AllowFailure -Raw -Argument @('rest', '--method', 'get', '--url', $uri)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $unobservable.Add("$name (the functions endpoint returned nothing - this reads the same whether the app has no code or the caller may not look, so it is not reported as empty)")
            continue
        }
        $parsed = $null
        try { $parsed = $raw | ConvertFrom-Json } catch {
            $unobservable.Add("$name (the functions endpoint did not return JSON)")
            continue
        }
        $names = @()
        if ($null -ne $parsed -and $null -ne $parsed.value) {
            $names = @($parsed.value | ForEach-Object { $_.properties.name } | Where-Object { $_ })
        }
        if ($names.Count -eq 0) {
            $problem.Add("$name has NO functions deployed - its package publish failed and the layer reported success anyway (F119)")
            $observed.Add("$name=0")
        }
        else {
            $observed.Add("$name=$($names.Count) ($($names -join ', '))")
        }
    }

    if ($unobservable.Count -gt 0) {
        return New-MlsCheckResult -Passed $false -Observed (($observed + $unobservable) -join '; ') `
            -Detail 'UNOBSERVABLE, not absent: the ARM functions endpoint answers the same way to a caller who may not read it as to an app with nothing deployed. Establish that mls-verifier can read Microsoft.Web/sites/functions before treating an empty list as evidence.'
    }
    if ($problem.Count -gt 0) {
        # The problem text goes in OBSERVED, not only Detail: the report's summary
        # line is what a reader scans, and "app=0" without the sentence beside it
        # is a number nobody will act on.
        return New-MlsCheckResult -Passed $false -Observed (($observed -join '; ') + ' | ' + ($problem -join ' | ')) `
            -Detail 'A Function App with no functions is a layer that did not deliver. Check the "Publish the ... Function package" step: it carries continue-on-error, so its failure does not fail the job. F119 was a 403 from the deployment storage firewall - the account needs a resourceAccessRules entry naming each site.'
    }
    return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ')
}

function Test-KeyVaultReferencesResolve {
    <# V6.8 - A KEY VAULT REFERENCE THAT RESOLVES TO NOTHING LOOKS EXACTLY LIKE ONE
       THAT WORKS (F122).

       The directline Function's DIRECTLINE_SECRET was a correct, well-formed
       reference to a real secret, the role assignment granting it was in place, the
       identity existed, the deploy was green and V6.1-V6.7 all passed. The Function
       received an empty string, because a `@Microsoft.KeyVault(...)` setting is
       resolved with the site's SYSTEM-assigned identity unless the site sets
       `keyVaultReferenceIdentity`, and this site has only a user-assigned one:

           status: MSINotEnabled
           details: Reference was not able to be resolved because site Managed
                    Identity not enabled.

       WHAT MADE IT INVISIBLE, and why this criterion reads a different endpoint than
       a person would. `az functionapp config appsettings list` prints the reference
       text back verbatim whether or not it resolves - the artefact is perfect in
       every listing. Worse, the downstream symptom was a Function reporting "channel
       not configured", which is a state this estate deliberately supports and ships
       as the honest default before the agent is published. So the one visible
       signal was indistinguishable from correct behaviour. Only
       /config/configreferences/appsettings carries the resolution status. Assert the
       CAPABILITY - the secret actually arrives - not the artefact, which was "the
       setting is present and points somewhere real".

       This endpoint returns names and statuses, never secret values, which is
       precisely why a Reader-authenticated Verifier can and should be the one asking.

       OBSERVABILITY BEFORE ABSENCE. An empty list means "this site has no Key Vault
       references" to a caller who may look, and it is also what a caller who may not
       look could receive. A non-success response is UNOBSERVABLE. An empty list is
       reported as such rather than silently passing, because a reference that was
       expected and is simply GONE would otherwise read as a clean pass. #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string[]]$FunctionAppName
    )
    $observed = [System.Collections.Generic.List[string]]::new()
    $problem = [System.Collections.Generic.List[string]]::new()
    $unobservable = [System.Collections.Generic.List[string]]::new()

    foreach ($name in $FunctionAppName) {
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" +
               "/providers/Microsoft.Web/sites/$name/config/configreferences/appsettings?api-version=2022-09-01"
        $raw = Invoke-MlsAz -AllowFailure -Raw -Argument @('rest', '--method', 'get', '--url', $uri)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $unobservable.Add("$name (the configreferences endpoint returned nothing - this reads the same whether the site has no Key Vault references or the caller may not look, so it is not reported as clean)")
            continue
        }
        $parsed = $null
        try { $parsed = $raw | ConvertFrom-Json } catch {
            $unobservable.Add("$name (the configreferences endpoint did not return JSON)")
            continue
        }
        $references = @()
        if ($null -ne $parsed -and $null -ne $parsed.value) { $references = @($parsed.value) }
        if ($references.Count -eq 0) {
            $observed.Add("$name has no Key Vault references")
            continue
        }
        foreach ($reference in $references) {
            $status = ''
            if ($null -ne $reference.properties -and $null -ne $reference.properties.status) {
                $status = [string]$reference.properties.status
            }
            $observed.Add("$name/$($reference.name)=$status")
            if ($status -ne 'Resolved') {
                $details = ''
                if ($null -ne $reference.properties -and $null -ne $reference.properties.details) {
                    $details = [string]$reference.properties.details
                }
                $problem.Add("$name/$($reference.name) is $status - $details")
            }
        }
    }

    if ($unobservable.Count -gt 0) {
        return New-MlsCheckResult -Passed $false -Observed (($observed + $unobservable) -join '; ') `
            -Detail 'UNOBSERVABLE, not clean: the configreferences endpoint answers the same way to a caller who may not read it as to a site with no Key Vault references. Establish that mls-verifier can read Microsoft.Web/sites/config before treating an empty list as evidence.'
    }
    if ($problem.Count -gt 0) {
        return New-MlsCheckResult -Passed $false -Observed (($observed -join '; ') + ' | ' + ($problem -join ' | ')) `
            -Detail 'An unresolved Key Vault reference delivers an EMPTY value to the app, which usually surfaces as a feature quietly reporting itself unconfigured rather than as an error. MSINotEnabled means the site has no system-assigned identity and never named a user-assigned one: set keyVaultAccessIdentityResourceId on the site (F122). Forbidden/NotFound mean the reference resolves to a secret the identity cannot read or that does not exist.'
    }
    return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ')
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
        # `print 1`, NOT `Heartbeat | take 1`.
        #
        # This criterion asserts the Verifier can REACH the workspace - its own comment says
        # it passes on "query succeeded as the verifier". Heartbeat is an agent table, filled
        # by Azure Monitor Agent on virtual machines, and this estate has none: Container
        # Apps, Functions and SQL only. The table returns [] forever, and V6.2 failed against
        # a workspace holding 5,424 rows across six tables it could read perfectly well
        # (F86).
        #
        # `print 1` needs no table, no ingestion and no agent. It succeeds exactly when the
        # identity can execute a query and fails exactly when it cannot, which is the
        # question being asked. Whether audit records EXIST is V7.3's job, and it uses a
        # table this estate actually writes.
        '--analytics-query', 'print 1', '--timespan', 'P1D', '--output', 'json'
    )
    if ($null -eq $result) {
        # ESTABLISH THAT YOU COULD OBSERVE BEFORE REPORTING WHAT YOU SAW (F182).
        #
        # This used to return one sentence offering two readings - "HTTP error, OR the
        # Reader identity cannot query this workspace" - and committing to neither. One
        # reading is a broken credential and the other a missing role assignment, and a
        # reader cannot act on the union. It is F102/F103/F105's disease in the component
        # built to catch it: an audit that could not see, reporting absence.
        #
        # The register's leading hypothesis was an expired federated assertion. The code
        # rules that out: Invoke-MlsAz THROWS on AADSTS700024 even under -AllowFailure
        # precisely so it can never be swallowed, so an expired assertion arrives as
        # "check threw", never as "no result". Whatever this is, it is not that.
        #
        # So ask the question the criterion could not: can this identity mint a Log
        # Analytics token AT THIS MOMENT? No token means reachability is unobservable and
        # there is no verdict to give. A token means the identity authenticates perfectly
        # well, and a failing query is then a real finding about workspace RBAC - which is
        # a different fix, made by a different person.
        #
        # Probed only on the failure path: an extra token call on every pass would spend
        # the very assertion lifetime this is reasoning about.
        $token = Invoke-MlsAz -AllowFailure -Argument @(
            'account', 'get-access-token', '--resource', 'https://api.loganalytics.io', '--output', 'json'
        )
        if ($null -eq $token) {
            return New-MlsCheckResult -Status SKIP `
                -Observed 'the query returned nothing AND no Log Analytics token could be minted for this identity, so query reachability is unobservable - this is NOT evidence about the workspace or its role assignments' `
                -Detail 'Establish a working login for the Verifier identity and re-run. A criterion that cannot authenticate has learned nothing about the control it audits, so it reports SKIP rather than a verdict (F105).'
        }
        return New-MlsCheckResult -Passed $false `
            -Observed 'a Log Analytics token WAS obtained for this identity, so authentication is working; the query itself still returned no result' `
            -Detail 'The credential is not the problem. Look at workspace RBAC for the Verifier identity - it needs a role granting query rights on this workspace. Propagation takes up to ~15 min, which the retry window covers.'
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

function Test-SqlBackupPosture {
    <# V6.5 (F16, Task 18 - CP-9; not a master-plan criterion - see this script's
       .DESCRIPTION). requestedBackupStorageRedundancy is a top-level property on the
       database resource (`az sql db show`); retentionDays lives on the child
       backupShortTermRetentionPolicies/default resource, which `az sql db show` does
       not surface - a plain `az resource show --ids <dbId>/backupShortTermRetentionPolicies/default`
       reaches it without needing the dedicated `az sql db str-policy show` command's
       separate --resource-group/--server/--database argument shape. #>
    param(
        [AllowEmptyString()][string]$SqlDatabaseId,
        [Parameter(Mandatory)][int]$ExpectedRetentionDays,
        [Parameter(Mandatory)][string]$ExpectedStorageRedundancy
    )
    if ([string]::IsNullOrWhiteSpace($SqlDatabaseId)) {
        return New-MlsCheckResult -Passed $false -Observed 'no SQL database resource id available' -Final `
            -Detail 'Pass -SqlDatabaseId / $env:MLS_SQL_DB_ID, or record it in the layer-06 deployment outputs.'
    }
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()

    $redundancy = Invoke-MlsAz -AllowFailure -Raw -Argument @(
        'sql', 'db', 'show', '--ids', $SqlDatabaseId, '--query', 'requestedBackupStorageRedundancy', '--output', 'tsv'
    )
    $redundancyValue = "$redundancy".Trim()
    $observed.Add("requestedBackupStorageRedundancy='$redundancyValue'")
    if ($redundancyValue -ne $ExpectedStorageRedundancy) {
        $problem.Add("requestedBackupStorageRedundancy='$redundancyValue', expected '$ExpectedStorageRedundancy'")
    }

    $policy = Invoke-MlsAz -AllowFailure -Argument @(
        'resource', 'show', '--ids', "$SqlDatabaseId/backupShortTermRetentionPolicies/default",
        '--query', '{retentionDays:properties.retentionDays}', '--output', 'json'
    )
    if ($null -eq $policy) {
        $problem.Add('ARM GET on the short-term backup retention policy returned nothing')
    }
    else {
        $retentionDays = Get-MlsProperty -InputObject $policy -Name 'retentionDays'
        $observed.Add("retentionDays=$retentionDays")
        if ([int]$retentionDays -ne $ExpectedRetentionDays) {
            $problem.Add("retentionDays=$retentionDays, expected $ExpectedRetentionDays")
        }
    }

    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ')
    }
    return New-MlsCheckResult -Passed $false -Observed (($observed -join '; ') + ' | ' + ($problem -join ' | ')) `
        -Detail 'Backup posture (F16/CP-9) is pinned by the template; any drift from the expected retention window or storage redundancy tier is a FAIL rather than a silent inherited default.'
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
        [int]$ExpectedBackupRetentionDays = 7,
        [string]$ExpectedBackupStorageRedundancy = 'Local',
        [string]$LayerCompletedUtc,
        [string]$SqlLastTouchedUtc,
        [double]$SqlIdleWindowMinutes = 75,
        [double]$SqlPauseWaitMinutes = -1,
        [switch]$EnforceCostExport,
        [string]$FunctionResourceGroupName,
        [string[]]$FunctionAppName = @(),
        [string]$ReportRoot,
        [switch]$NoRetry,
        [string[]]$OnlyCriterion = @()
    )
    # Derived, not hardcoded: 'mls' and 'demo' are DEFAULTS in naming.bicep that a
    # deployment overrides with MLS_COMPANY_PREFIX / MLS_ENV_SEGMENT. Reading the
    # same variables here keeps this criterion pointed at the estate that was
    # actually deployed - CLAUDE.md's rule that a constant naming something in
    # another system is resolved, not written from memory.
    $prefix = if ($env:MLS_COMPANY_PREFIX) { $env:MLS_COMPANY_PREFIX } else { 'mls' }
    $envSeg = if ($env:MLS_ENV_SEGMENT) { $env:MLS_ENV_SEGMENT } else { 'demo' }
    $functionResourceGroupName = if ($FunctionResourceGroupName) { $FunctionResourceGroupName } else { "$prefix-rg-ops" }
    $FunctionAppNames = if ($FunctionAppName.Count -gt 0) {
        $FunctionAppName
    }
    else {
        @("$prefix-cost-ingest-$envSeg-func", "$prefix-directline-$envSeg-func")
    }
    $subscription = Resolve-MlsInput -Name 'SubscriptionId' -Value $SubscriptionId -EnvironmentVariable @('AZURE_SUBSCRIPTION_ID') `
        -Hint 'The demo subscription holding mls-rg-platform; read as mls-verifier (Reader covers */read).'

    $context = New-MlsAuditContext -Layer 6 -Title 'Core platform: ACA env, SQL, observability, cost exports' `
        -ScriptName 'verification/layer-06-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry `
        -OnlyCriterion $OnlyCriterion
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

    Invoke-MlsCriterion -Context $context -Id 'V6.1' -Control @('3.4.1') `
        -Description 'ARM GET on each resource: SKU/serverless/auto-pause/minReplicas values match manifest exactly' `
        -Command "az sql db show --ids <dbId> --query `"{sku:currentSku.name, autoPause:autoPauseDelay, minCap:minCapacity}`"`naz containerapp env show --ids <envId> --query properties.provisioningState" `
        -Expected "serverless GP_S_Gen5-class SKU; autoPauseDelay == $ExpectedAutoPauseDelay; minCapacity == $ExpectedMinCapacity; ACA environment provisioningState == Succeeded" `
        -RetryWindowMinutes 5 `
        -Test {
        Test-ArmStateMatchesManifest -SqlDatabaseId $databaseId -ContainerAppEnvironmentId $environmentId `
            -ExpectedAutoPauseDelay $ExpectedAutoPauseDelay -ExpectedMinCapacity $ExpectedMinCapacity
    } | Out-Null

    # -Control @(): Test-LogAnalyticsQuery passes on "query succeeded as the
    # Verifier identity; 0 row(s) returned", and the -Expected text below says so
    # outright. That demonstrates the Reader identity can reach the workspace, not
    # that audit records were created or retained, which is what 3.3.1 asks for.
    # V7.3 carries 3.3.1 instead, because it proves an actual record was captured.
    # L06: workspace RBAC propagation
    Invoke-MlsCriterion -Context $context -Id 'V6.2' -Control @() `
        -Description 'KQL query against LAW succeeds as verifier' `
        -Command "az monitor log-analytics query --workspace <lawCustomerId> --analytics-query 'print 1' --timespan P1D" `
        -Expected 'a well-formed result under the mls-verifier login - this asserts query REACHABILITY, not that any table holds data' `
        -RetryWindowMinutes 15 `
        -Test { Test-LogAnalyticsQuery -WorkspaceId $workspaceId } | Out-Null

    $costWindowStart = [datetime]::MinValue
    if (-not [string]::IsNullOrWhiteSpace($LayerCompletedUtc)) { $costWindowStart = [datetime]::Parse($LayerCompletedUtc).ToUniversalTime() }
    elseif (-not [string]::IsNullOrWhiteSpace($env:MLS_L6_COMPLETED_AT)) { $costWindowStart = [datetime]::Parse($env:MLS_L6_COMPLETED_AT).ToUniversalTime() }
    $pendingAllowed = (-not $EnforceCostExport) -and ($costWindowStart -ne [datetime]::MinValue)
    if (-not $EnforceCostExport -and $costWindowStart -eq [datetime]::MinValue) {
        Add-MlsNote -Context $context -Message 'V6.3: no L6 completion timestamp supplied (-LayerCompletedUtc / $env:MLS_L6_COMPLETED_AT), so the 24 h deadline could not be computed and a missing export is recorded FAIL rather than PENDING.'
    }

    # -Control @(): cost-export landing is a FinOps/cost-visibility check, not CUI
    # protection.
    Invoke-MlsCriterion -Context $context -Id 'V6.3' -Control @() `
        -Description 'First cost export file lands within 24 h (async check L7 window)' `
        -Command "az storage blob list --account-name <exportSA> --container-name $CostExportContainerName --auth-mode login --query `"[].{name:name, len:properties.contentLength}`"" `
        -Expected '>= 1 export blob with contentLength > 0 within 24 h of L6 completion' `
        -RetryWindowMinutes 1440 -InProcessWaitMinutes 0 -WindowStartUtc $costWindowStart -PendingWhenUnexpired:$pendingAllowed `
        -Test { Test-CostExportLanded -AccountName $accountName -ContainerName $CostExportContainerName } | Out-Null

    # The idle window opens at the last deployment touch of the database (the seed), which
    # only the caller knows. Supplied: the deadline is computable, so "not paused yet" is
    # PENDING while the window is open and FAIL once it has elapsed - V6.3's treatment.
    # Not supplied: unchanged historical behaviour, an Online database is a FAIL.
    $sqlWindowStart = [datetime]::UtcNow
    $sqlWindowKnown = -not [string]::IsNullOrWhiteSpace($SqlLastTouchedUtc)
    if ($sqlWindowKnown) { $sqlWindowStart = [datetime]::Parse($SqlLastTouchedUtc).ToUniversalTime() }
    $sqlBudget = $SqlIdleWindowMinutes - ([datetime]::UtcNow - $sqlWindowStart).TotalMinutes
    if ($sqlBudget -lt 0) { $sqlBudget = 0 }
    # A ceiling on how long THIS run may sleep, independent of the declared window.
    # 0 turns the criterion into a single evaluation, which is what a pipeline running
    # inline needs and what a scheduled re-check wants for the opposite reason.
    if ($SqlPauseWaitMinutes -ge 0 -and $SqlPauseWaitMinutes -lt $sqlBudget) { $sqlBudget = $SqlPauseWaitMinutes }
    if (-not $sqlWindowKnown) {
        Add-MlsNote -Context $context -Message 'V6.4: no last-touched timestamp supplied (-SqlLastTouchedUtc / the L6 deploy''s post-seed time), so the 75-minute idle deadline could not be computed and a database that is still Online is recorded FAIL rather than PENDING. That is correct for a re-check run made after the window; for an inline run straight after the deploy, pass the timestamp.'
    }

    # -Control @(): idle-cost control (auto-pause). Cost/FinOps, not CUI protection.
    Invoke-MlsCriterion -Context $context -Id 'V6.4' -Control @() `
        -Description 'SQL auto-pauses (checked after 75 min idle)' `
        -Command 'az sql db show --ids <dbId> --query "status"' `
        -Expected '"Paused" at the 75-minute mark (60-minute auto-pause delay + 15 minutes of margin)' `
        -RetryWindowMinutes $SqlIdleWindowMinutes -InProcessWaitMinutes $sqlBudget `
        -WindowStartUtc $sqlWindowStart -PendingWhenUnexpired:$sqlWindowKnown `
        -Test { Test-SqlAutoPause -SqlDatabaseId $databaseId } | Out-Null

    # V6.5 (F16, Task 18 - CP-9) - not a master-plan criterion (see .DESCRIPTION); ARM
    # GET is read-your-writes after deployment success, same retry shape as V6.1.
    # -Control @(): this criterion checks retentionDays and
    # requestedBackupStorageRedundancy, which are DURABILITY and AVAILABILITY
    # properties. The nearest 800-171 requirement, 3.8.9, is a CONFIDENTIALITY
    # requirement - protect the confidentiality of backup CUI - which this criterion
    # never touches: it makes no encryption or TDE assertion at all. That, not the
    # framework's shape, is why it maps to nothing.
    # (An earlier revision of this comment said CP-9 "is not one of the 110 ... so it
    # cannot map into this" catalog. That was wrong: 3.8.9's own
    # mappings.nist-800-53r5 carries CP-9, so an 800-53 view already reaches it
    # through the catalog. The rejection stands on the confidentiality argument.)
    # The original note, retained because it is still true of this
    # catalog. It is also not 3.8.9 (protect the CONFIDENTIALITY of backup CUI): retention
    # days and storage-redundancy tier are durability/availability properties, not a
    # confidentiality control.
    Invoke-MlsCriterion -Context $context -Id 'V6.5' -Control @() `
        -Description 'SQL backup posture (short-term retention + backup storage redundancy) matches the template-pinned values' `
        -Command "az sql db show --ids <dbId> --query requestedBackupStorageRedundancy`naz resource show --ids <dbId>/backupShortTermRetentionPolicies/default --query properties.retentionDays" `
        -Expected "requestedBackupStorageRedundancy == $ExpectedBackupStorageRedundancy; short-term retentionDays == $ExpectedBackupRetentionDays" `
        -RetryWindowMinutes 5 `
        -Test { Test-SqlBackupPosture -SqlDatabaseId $databaseId -ExpectedRetentionDays $ExpectedBackupRetentionDays -ExpectedStorageRedundancy $ExpectedBackupStorageRedundancy } | Out-Null

    # V6.7 - the criterion that would have caught F119 on the day the estate was
    # built. A SHORT window on purpose: the answer is settled the moment the
    # publish step returns, so there is nothing to wait for. Per the working
    # agreement, a criterion that needs longer states the number and what it is
    # waiting on; this one needs none and says so.
    Invoke-MlsCriterion -Context $context -Id 'V6.7' -Control @() `
        -Description 'Every Function App the layer deploys actually has functions deployed to it' `
        -Command "az rest --method get --url https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Web/sites/<app>/functions?api-version=2023-12-01" `
        -Expected 'each Function App reports at least one function' `
        -RetryWindowMinutes 2 `
        -Test {
            Test-FunctionAppsHaveCode -SubscriptionId $SubscriptionId `
                -ResourceGroupName $functionResourceGroupName `
                -FunctionAppName $FunctionAppNames
        } | Out-Null

    # V6.8 - F122. SHORT window, and the reason is worth stating because it is not
    # the obvious one: Key Vault references are resolved at site start-up and the
    # status endpoint reflects the LAST resolution attempt, so a site that has not
    # restarted since the setting changed reports the old answer for a while. Two
    # minutes covers the restart the deploy itself triggers. It deliberately does not
    # cover secret-permission propagation - if a fresh role assignment is the reason
    # this fails, that is a real finding about deploy ordering, not something to wait
    # out.
    Invoke-MlsCriterion -Context $context -Id 'V6.8' -Control @() `
        -Description 'Every Key Vault reference in every Function App actually resolves - the secret arrives, rather than the setting merely being present' `
        -Command "az rest --method get --url https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Web/sites/<app>/config/configreferences/appsettings?api-version=2022-09-01" `
        -Expected 'every reference reports status == Resolved' `
        -RetryWindowMinutes 2 `
        -Test {
            Test-KeyVaultReferencesResolve -SubscriptionId $SubscriptionId `
                -ResourceGroupName $functionResourceGroupName `
                -FunctionAppName $FunctionAppNames
        } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -SubscriptionId $SubscriptionId -DeploymentName $DeploymentName `
            -SqlDatabaseId $SqlDatabaseId -ContainerAppEnvironmentId $ContainerAppEnvironmentId `
            -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -CostExportAccountName $CostExportAccountName `
            -CostExportContainerName $CostExportContainerName -ExpectedAutoPauseDelay $ExpectedAutoPauseDelay `
            -ExpectedMinCapacity $ExpectedMinCapacity -ExpectedBackupRetentionDays $ExpectedBackupRetentionDays `
            -ExpectedBackupStorageRedundancy $ExpectedBackupStorageRedundancy -LayerCompletedUtc $LayerCompletedUtc `
            -SqlLastTouchedUtc $SqlLastTouchedUtc -SqlIdleWindowMinutes $SqlIdleWindowMinutes `
            -SqlPauseWaitMinutes $SqlPauseWaitMinutes `
            -EnforceCostExport:$EnforceCostExport -ReportRoot $ReportRoot -NoRetry:$NoRetry `
            -FunctionResourceGroupName $FunctionResourceGroupName -FunctionAppName $FunctionAppName `
            -OnlyCriterion $OnlyCriterion
    }
    catch {
        Write-MlsStatus -Message "layer-06-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
