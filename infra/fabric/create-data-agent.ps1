#Requires -Version 7.0
<#
.SYNOPSIS
    L8 provisioning - the Fabric data agent over the `mls_operations` lakehouse.
    NOT part of the default trial-phase path: see CAPACITY below.

.DESCRIPTION
    Creates (idempotently) a Fabric data agent bound to the L5 lakehouse and publishes
    its staging configuration, so the Copilot Studio agent authored in
    infra/copilot-studio/ can consume it as a CONNECTED AGENT. Uses the wrappers in
    ./fabric-api.psm1; every REST call carries the caller-supplied bearer token and this
    script never authenticates by itself.

    Idempotent: an existing data agent with the same display name is reused, never
    recreated. -WhatIf issues GETs only and makes no writes.

.NOTES
    +-----------------------------------------------------------------------------+
    | CAPACITY - READ FIRST. This does not run on the trial.                       |
    +-----------------------------------------------------------------------------+
    Fabric data agents require a PAID F2-or-higher capacity (or P1+ with Fabric
    enabled). The Fabric 60-day TRIAL capacity explicitly does NOT support AI
    experiences, and the data agent is one of them.
        https://learn.microsoft.com/en-us/fabric/fundamentals/fabric-trial
        https://learn.microsoft.com/en-us/fabric/data-science/concept-data-agent

    The demo's trial-first strategy therefore cannot cover this path. The adopted
    position: **tools-only via MCP is the DEFAULT during the trial phase**, and the
    Fabric connected agent is the paid-F2 upgrade. Moving to paid F2 is a
    spend-profile increase and is G2-gated (CLAUDE.md gate G2; ~0.36 USD/hour while
    the capacity runs).

    This script fails fast rather than attempting creation when it can tell the
    target capacity is a trial SKU - both from the -CapacityId shape (the same
    /subscriptions/* heuristic layer-05-fabric.yml uses) and from the capacity's own
    `sku` read back from GET /v1/capacities. When it cannot determine the SKU it
    warns and proceeds; it never claims a capacity is fine that it could not check.

    +-----------------------------------------------------------------------------+
    | PREVIEW - and the fallback that goes with it                                 |
    +-----------------------------------------------------------------------------+
    The Fabric data agent ITEM is generally available. Two things this script
    depends on are NOT:

      * Data agent *configuration management* - including the staging/publish
        operation called below - is documented as "currently in Preview".
      * Consuming a Fabric data agent from Copilot Studio is in preview and is
        explicitly "only validated for Microsoft Teams. Other channels may also
        work but haven't been formally tested."
        https://learn.microsoft.com/en-us/fabric/data-science/data-agent-microsoft-copilot-studio

    Because the demo's answer surface is the control-tower app over Direct Line -
    NOT Teams - that second line is a live risk, not a theoretical one. Responses may
    also be sent outside Fabric's compliance boundary or geographic region.

    FALLBACK (amendment section 3, "New open risk"): if the Fabric data agent is
    unavailable on the capacity, unavailable in-region, or does not work over the
    Direct Line surface, the Copilot Studio agent stays exactly as authored and loses
    only this connected agent. NL->SQL then moves into the MCP tool server, which
    queries the lakehouse SQL analytics endpoint directly - a tools-only agent. That
    path is fully supported today and costs no rework of the agent, the workflow, or
    the Adaptive Card contract. Nothing else in L8 depends on this script succeeding,
    and layer-08-copilot-studio.yml runs this job independently of the agent import
    for exactly that reason.

    TERMINOLOGY: Copilot Studio attaches this under **Agents** (a connected agent
    reached through the Microsoft Fabric connector), NOT under Knowledge and NOT as a
    Tool. The amendment's phrase "knowledge source" is incorrect; Copilot Studio's own
    terminology is used throughout this repo.

    TENANT SETTINGS required before this can work (Admin portal, up to 1 hour to
    take effect):
      * "Users can use Copilot and other features powered by Azure OpenAI"
      * "Capacities can be designated as Fabric Copilot capacities"
      * the two "Data sent to Azure OpenAI can be processed/stored outside your
        capacity's geographic region..." settings, if the capacity region requires them

    PERMISSIONS: workspace CONTRIBUTOR role + Item.ReadWrite.All. Service principals
    and managed identities are supported for data agent create.

    Gate: L8 runs only after G1 approval + layer unblock. This script makes no
    capacity state changes (it neither resumes nor pauses).

.EXAMPLE
    $token = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
    ./create-data-agent.ps1 -Token $token -CapacityId $env:FABRIC_CAPACITY_ID -WhatIf

.EXAMPLE
    ./create-data-agent.ps1 -Token $token -CapacityId $env:FABRIC_CAPACITY_ID -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Bearer token for https://api.fabric.microsoft.com (OIDC-derived in CI).
    [Parameter(Mandatory)]
    [string]$Token,

    # Fabric capacity ID from config (FABRIC_CAPACITY_ID) - never hardcoded. Optional:
    # when supplied, a value that is not an ARM resource id (/subscriptions/...) is
    # taken as the trial capacity and the run stops before any write, matching the
    # heuristic layer-05-fabric.yml already uses. When omitted, the capacity is read
    # back from the workspace instead.
    [string]$CapacityId = '',

    # Proceed even when the capacity looks like a trial SKU. For the case where
    # detection is wrong and you know the capacity is paid F2+; it does not make a
    # trial capacity work.
    [switch]$SkipCapacityCheck,

    [string]$WorkspaceName = 'mls-operations',

    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')]
    [string]$LakehouseName = 'mls_operations',

    # Display name of the data agent item. Kept in step with the Copilot Studio
    # agent name in infra/copilot-studio/agent-definition.md.
    [string]$DataAgentName = 'mls-operations-data-agent',

    # Restrict the binding to these Delta tables. Empty (default) selects every
    # table the lakehouse currently reports - the L5 seed creates exactly ten.
    [string[]]$TableName = @(),

    # Skip the staging->published promotion. An unpublished data agent cannot be
    # consumed by Copilot Studio, so this is for diagnostics only.
    [switch]$SkipPublish,

    # Escape hatch: pass '' to emit a flat table element list instead of nesting the
    # tables under a lakehouse_tables.schema element (see New-FabricDataAgentDefinition).
    [AllowEmptyString()]
    [string]$SchemaName = 'dbo'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The natural-language framing the data agent applies to every question. This is
# the Fabric-side half of the system prompt; the Copilot Studio half lives in
# infra/copilot-studio/agent-definition.md and the two must stay consistent.
$script:AiInstructions = @'
You answer questions about Meridian Launch Systems flight operations from the
mls_operations lakehouse. The data is synthetic and deterministic (generator seed
20260822); never caveat it as an estimate when an exact answer is available.

Rules:
* Always aggregate in SQL. Never sample rows and count them yourself.
* When a question is about "day of week", derive it from the launch/scrub date
  column rather than any stored day name.
* Scrubs and launches are separate facts: a scrubbed attempt is not a launch.
* Return exact counts, and name the tables and columns you used.
* If a question cannot be answered from these tables, say so plainly instead of
  guessing at a schema.
'@

$script:DataSourceInstructions = @'
mls_operations holds Meridian Launch Systems launch operations as Delta tables:
launches, scrubs, telemetry, parts, suppliers and their supporting dimensions.
Query them through the lakehouse SQL analytics endpoint. Read-only.
'@

$script:PublishedDescription = @'
Natural-language question answering over the Meridian Launch Systems operations
lakehouse (mls_operations): launches, scrubs, telemetry, parts and suppliers.
Use for any question about launch cadence, scrub causes and rates, vehicle or pad
utilisation, supplier lead times, or part consumption over time.
'@

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive provisioning script; console output is the product.')]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

function Get-WorkspaceCapacityId {
    <# Strict-mode-safe read of a workspace's capacityId; $null when not reported. #>
    param($Workspace)
    if ($null -eq $Workspace) { return $null }
    $prop = $Workspace.PSObject.Properties['capacityId']
    if ($prop) { return $prop.Value }
    return $null
}

function Test-TrialCapacitySku {
    <#
    .SYNOPSIS
        Does this capacity SKU name denote a Fabric trial capacity?
    .DESCRIPTION
        Trial capacities surface as 'Trial' (and the historical 'FT1'). Paid Fabric
        capacities are F2, F4, F8 ... ; Premium is P1+. Matching is deliberately narrow:
        an unrecognised SKU returns $false so the run continues with a warning rather
        than blocking a legitimate paid capacity on a string this function has not seen.
    #>
    param([string]$Sku)
    if ([string]::IsNullOrWhiteSpace($Sku)) { return $false }
    return ($Sku -match '(?i)trial') -or ($Sku -match '(?i)^FT\d+$')
}

function Assert-PaidCapacity {
    <#
    .SYNOPSIS
        Stop before any write when the target is a trial capacity.
    .DESCRIPTION
        Fabric data agents are not supported on the trial capacity. Attempting creation
        there produces an opaque server-side failure well after the point where a human
        could have acted on it, so this fails first, with the decision spelled out.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        $Workspace,
        [string]$CapacityId = '',
        [switch]$SkipCapacityCheck
    )

    $trialMessage = @'
This Fabric capacity is a TRIAL capacity, and Fabric data agents are not supported on it.
The trial capacity does not support Fabric AI experiences at all.
  https://learn.microsoft.com/en-us/fabric/fundamentals/fabric-trial
  https://learn.microsoft.com/en-us/fabric/data-science/concept-data-agent

Nothing was created. This is the expected state during the trial phase, not a bug.

What to do:
  * DEFAULT (trial phase): run the copilot tools-only. The MCP tool server queries the
    lakehouse SQL analytics endpoint directly, so the Copilot Studio agent keeps its
    prompt, its Adaptive Card contract, its channel and its whole deploy pipeline - it
    simply has no connected Fabric agent. Nothing else in L8 depends on this script.
  * UPGRADE: move to a paid F2+ capacity, then re-run. That is a spend-profile increase
    and is G2-gated (~0.36 USD/hour while the capacity runs) - state the delta and wait
    for the human before switching FABRIC_CAPACITY_ID.
  * Override only if detection is wrong and the capacity really is paid F2+:
    -SkipCapacityCheck.
'@

    if ($SkipCapacityCheck) {
        Write-Status 'Capacity check skipped (-SkipCapacityCheck). A trial capacity will still fail server-side.' -Color Yellow
        return
    }

    # Signal 1 - offline, from configuration. A capacity id that is not an ARM resource
    # id is the trial capacity; this is the same heuristic layer-05-fabric.yml uses, and
    # it works under -WhatIf without a single REST call.
    if (-not [string]::IsNullOrWhiteSpace($CapacityId) -and $CapacityId -notlike '/subscriptions/*') {
        throw "$trialMessage`n(Detected from FABRIC_CAPACITY_ID '$CapacityId', which is not an ARM resource id.)"
    }

    # Signal 2 - authoritative, from the capacity itself.
    $resolvedCapacityId = if ($CapacityId) { $CapacityId } else { Get-WorkspaceCapacityId -Workspace $Workspace }
    if ([string]::IsNullOrWhiteSpace($resolvedCapacityId)) {
        Write-Status 'Could not determine the workspace capacity - proceeding unverified. If this is the trial capacity the create will fail server-side.' -Color Yellow
        return
    }

    $capacity = $null
    try {
        $capacity = Get-FabricCapacity -Token $Token -CapacityId $resolvedCapacityId
    }
    catch {
        Write-Status "Could not read capacities ($($_.Exception.Message)) - proceeding unverified." -Color Yellow
        return
    }
    if (-not $capacity) {
        Write-Status "Capacity $resolvedCapacityId is not visible to this identity - proceeding unverified." -Color Yellow
        return
    }

    $skuProp = $capacity.PSObject.Properties['sku']
    $sku = if ($skuProp) { "$($skuProp.Value)" } else { '' }
    if (Test-TrialCapacitySku -Sku $sku) {
        throw "$trialMessage`n(Detected from capacity SKU '$sku'.)"
    }

    Write-Status "Capacity SKU: $(if ($sku) { $sku } else { '(not reported)' }) - not a trial capacity." -Color Green
}

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$WorkspaceName,
        [Parameter(Mandatory)][string]$LakehouseName,
        [Parameter(Mandatory)][string]$DataAgentName,
        [string]$CapacityId = '',
        [switch]$SkipCapacityCheck,
        [string[]]$TableName = @(),
        [switch]$SkipPublish,
        [AllowEmptyString()][string]$SchemaName = 'dbo'
    )
    $empty = [pscustomobject]@{ Workspace = $null; Lakehouse = $null; DataAgent = $null; Tables = @(); Published = $false }

    # ---- workspace (must already exist - L5 owns creation) -------------------------
    $workspace = Get-FabricWorkspace -Token $Token -Name $WorkspaceName
    if (-not $workspace) {
        throw "Fabric workspace '$WorkspaceName' does not exist. L5 provisions it (infra/fabric/provision-workspace.ps1); L8 will not create it."
    }
    Write-Status "Workspace '$WorkspaceName' found (id $($workspace.id))." -Color Green

    # ---- capacity gate (before ANY write, and before -WhatIf reports a plan that
    #      could never run) -----------------------------------------------------------
    Assert-PaidCapacity -Token $Token -Workspace $workspace -CapacityId $CapacityId `
        -SkipCapacityCheck:$SkipCapacityCheck

    # ---- lakehouse (must already exist) --------------------------------------------
    $lakehouse = Get-FabricLakehouse -Token $Token -WorkspaceId $workspace.id -Name $LakehouseName
    if (-not $lakehouse) {
        throw "Lakehouse '$LakehouseName' does not exist in workspace '$WorkspaceName'. Run the L5 provision + seed first."
    }
    Write-Status "Lakehouse '$LakehouseName' found (id $($lakehouse.id))." -Color Green

    # ---- tables to bind -------------------------------------------------------------
    $tables = @(Get-FabricTable -Token $Token -WorkspaceId $workspace.id -LakehouseId $lakehouse.id)
    # The @() goes around the WHOLE if-expression. An if used as an expression writes its
    # branch to the pipeline, and assignment unrolls that - so the @() inside each branch
    # was undone on the way out, and $tableNames was $null for zero tables and a bare
    # string for one. .Count then threw, and an unseeded lakehouse reported "The property
    # 'Count' cannot be found on this object" instead of the actionable message below.
    # Fourth syntactic disguise of the same defect in this codebase (F49).
    $tableNames = @(if (@($TableName).Count -gt 0) { $TableName } else { $tables | ForEach-Object { $_.name } })
    if ($tableNames.Count -eq 0) {
        throw "Lakehouse '$LakehouseName' reports no tables. A data agent bound to nothing answers nothing - seed the lakehouse (L5) before running L8."
    }
    Write-Status "Binding $($tableNames.Count) table(s): $($tableNames -join ', ')" -Color Cyan

    # ---- data agent -----------------------------------------------------------------
    $dataAgent = Get-FabricDataAgent -Token $Token -WorkspaceId $workspace.id -Name $DataAgentName
    if ($dataAgent) {
        Write-Status "Data agent '$DataAgentName' already exists (id $($dataAgent.id)) - reusing." -Color Green
    }
    else {
        $definition = New-FabricDataAgentDefinition `
            -WorkspaceId $workspace.id `
            -LakehouseId $lakehouse.id `
            -LakehouseName $LakehouseName `
            -TableName $tableNames `
            -AiInstructions $script:AiInstructions `
            -DataSourceInstructions $script:DataSourceInstructions `
            -UserDescription "Meridian Launch Systems operations lakehouse ($LakehouseName)" `
            -SchemaName $SchemaName

        $dataAgent = New-FabricDataAgent -Token $Token -WorkspaceId $workspace.id `
            -Name $DataAgentName -Description $script:PublishedDescription `
            -Definition $definition -WhatIf:$WhatIfPreference

        if ($dataAgent) {
            Write-Status "Created data agent '$DataAgentName'." -Color Green
        }
        else {
            Write-Status "(-WhatIf) Would create data agent '$DataAgentName' bound to $($tableNames.Count) table(s) in '$LakehouseName', then publish it." -Color Yellow
            $empty.Workspace = $workspace
            $empty.Lakehouse = $lakehouse
            $empty.Tables = $tables
            return $empty
        }
    }

    # ---- publish (staging -> published; preview API) ---------------------------------
    $published = $false
    if ($SkipPublish) {
        Write-Status '-SkipPublish set: leaving the draft configuration unpublished. Copilot Studio cannot consume it in this state.' -Color Yellow
    }
    else {
        $result = Publish-FabricDataAgent -Token $Token -WorkspaceId $workspace.id `
            -DataAgentId $dataAgent.id -Description $script:PublishedDescription -WhatIf:$WhatIfPreference
        if ($result) {
            $published = $true
            Write-Status "Published data agent '$DataAgentName'." -Color Green
        }
        else {
            Write-Status "(-WhatIf) Would publish the staging configuration of data agent '$DataAgentName'." -Color Yellow
        }
    }

    return [pscustomobject]@{
        Workspace = $workspace
        Lakehouse = $lakehouse
        DataAgent = $dataAgent
        Tables    = $tables
        Published = $published
    }
}

if (-not $env:MLS_SKIP_MAIN) {
    Import-Module (Join-Path $PSScriptRoot 'fabric-api.psm1') -Force
    Invoke-Main -Token $Token -WorkspaceName $WorkspaceName -LakehouseName $LakehouseName `
        -DataAgentName $DataAgentName -CapacityId $CapacityId -SkipCapacityCheck:$SkipCapacityCheck `
        -TableName $TableName -SkipPublish:$SkipPublish -SchemaName $SchemaName
}
