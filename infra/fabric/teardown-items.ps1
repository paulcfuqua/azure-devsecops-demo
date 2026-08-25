#Requires -Version 7.0
<#
.SYNOPSIS
    Standard kill/rebuild teardown - delete every ITEM inside the Fabric workspace
    `mls-operations`, leaving the workspace shell and its role assignments intact.

.DESCRIPTION
    Step 1 of `down.ps1` / `.github/workflows/infra-down.yml`
    (docs/runbooks/kill-rebuild.md section 2). Lists the workspace's items and deletes
    them:

        GET    /v1/workspaces/{workspaceId}/items                     (List Items)
        DELETE /v1/workspaces/{workspaceId}/lakehouses/{lakehouseId}  (Delete Lakehouse)
        DELETE /v1/workspaces/{workspaceId}/items/{itemId}            (Delete Item)

    Listing generically rather than per type is the point: the contract in
    kill-rebuild.md is "every item", not "the item types L5 and L8 happen to create
    today", so a notebook or a pipeline some future layer adds dies on the same cycle
    without anyone remembering to extend this script.

    Deleting is generic too - with one deliberate exception. Delete Item's service
    principal support is documented as conditional: "When the item type in the call is
    supported. Check the corresponding API for the item type you're calling."
    (https://learn.microsoft.com/en-us/rest/api/fabric/core/items/delete-item), whereas
    Delete Lakehouse states service principal support flatly
    (https://learn.microsoft.com/en-us/rest/api/fabric/lakehouse/items/delete-lakehouse).
    The lakehouse is the one item this teardown absolutely must remove, and this script
    runs as a service principal, so it uses the typed call for lakehouses and the
    generic one for everything else. -TypedDeletePath carries that mapping.

    SOFT DELETE is Delete Item's documented default, and hard deletion additionally
    requires the workspace ADMIN role. The deployer SP has it, but a teardown that
    fails on a permission it does not strictly need is worse than one that leaves a
    recoverable tombstone, so -HardDelete is opt-in rather than the default. Soft
    deleted items still count against the workspace item cap; if a rebuild ever hits
    that cap, this switch is the fix.

    +-------------------------------------------------------------------------------+
    | THE LINE THIS SCRIPT NEVER CROSSES                                             |
    +-------------------------------------------------------------------------------+
    kill-rebuild.md section 1 puts the workspace SHELL and its role assignments in the
    "persists every cycle (G3 to touch)" column, because `mls-verifier`'s Viewer grant
    has to survive - the Verifier audits the rebuilt lakehouse with it, and re-granting
    a tenant-level role assignment costs 15-45 minutes of propagation the <60-minute
    rebuild clock does not have.

    Structurally, therefore, this script:
      * never issues DELETE /v1/workspaces/{workspaceId}          (that is G3),
      * never touches /v1/workspaces/{workspaceId}/roleAssignments (any verb),
      * never touches the capacity, Entra, Purview labels or anything outside this one
        workspace.
    Its whole surface is the two item calls above. Pester asserts each of those
    prohibitions directly, because "we would never do that" is not a control.

    DERIVED ITEMS. Creating a lakehouse also provisions a SQL analytics endpoint, which
    shows up as its own item in the listing. Deleting the lakehouse takes it with them:
    "Deleting a lakehouse removes the lakehouse item, all its data, the associated SQL
    analytics endpoint, and the semantic model."
    (https://learn.microsoft.com/en-us/fabric/data-engineering/create-lakehouse)
    Whether a SQL analytics endpoint can be deleted on its own is not documented either
    way, so this script does not try - it skips the type and lets the cascade do it.

    Note what is NOT in the skip list: SemanticModel. Default semantic models stopped
    being created with new lakehouses on 2025-09-05, and pre-existing ones were
    decoupled into independent items
    (https://learn.microsoft.com/en-us/fabric/data-engineering/lakehouse-overview).
    An independent semantic model is a normal workspace item and must die with the rest,
    so skipping it would strand it in a workspace the runbook promises is empty.

    ORDER. Non-lakehouse items first, lakehouses last. This is not tidiness: "You can't
    delete a lakehouse that's referenced by other items"
    (https://learn.microsoft.com/en-us/fabric/data-engineering/create-lakehouse), and at
    L8 the Fabric data agent is exactly such a reference. Deleting in the other order
    fails on the lakehouse and leaves the workspace half torn down.

    IDEMPOTENT. An absent workspace, an already-empty workspace and an item that
    disappears between the list and the delete (404) are all no-ops, not errors -
    `down.ps1` is safe to re-run at any time, from any state.

    GATE CLASS: gate-free. Workspace items are demo resources and CLAUDE.md hard rule 2
    makes RG-scoped/demo teardown gate-free by design. Deleting the workspace itself or
    the capacity is G3 and lives in a different script.

.EXAMPLE
    $token = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
    ./teardown-items.ps1 -Token $token -WhatIf

.EXAMPLE
    ./teardown-items.ps1 -Token $token -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Bearer token for https://api.fabric.microsoft.com (OIDC-derived in CI).
    [Parameter(Mandatory)]
    [string]$Token,

    [string]$WorkspaceName = 'mls-operations',

    # Item types owned by another item and removed by its cascade. See DERIVED ITEMS.
    [string[]]$SkipItemType = @('SQLEndpoint'),

    # Item types deleted in the final pass, after everything that might reference them.
    [string[]]$DeleteLastItemType = @('Lakehouse'),

    # Item types with their own typed delete operation, used in preference to the
    # generic one because the generic one's service-principal support is conditional.
    # Key = item type as it appears in the listing; value = path segment under the
    # workspace.
    [hashtable]$TypedDeletePath = @{ Lakehouse = 'lakehouses' },

    # Purge instead of tombstoning. Requires the workspace ADMIN role; off by default so
    # a missing role cannot fail an otherwise clean teardown. See SOFT DELETE above.
    [switch]$HardDelete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Operator-facing teardown script; console output is the product and is captured in the infra-down run log.')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

function Get-TeardownValue {
    <# Strict-mode-safe property read from a hashtable or a PSObject. #>
    param($InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-TeardownCollection {
    <#
    .SYNOPSIS
        Normalize a Fabric collection response ({value:[...]} or {data:[...]}) to an array.
    .DESCRIPTION
        Key PRESENCE is tested, not the value: a PowerShell function returning @()
        emits nothing, so `$collection = Get-TeardownValue ...` on an empty page would
        read as $null, fall through, and hand the response envelope back as though it
        were a workspace item. That turns an already-empty workspace into a delete
        against an item with no id.
    #>
    param($Response)
    if ($null -eq $Response) { return @() }
    foreach ($key in @('value', 'data')) {
        if ($Response -is [System.Collections.IDictionary]) {
            if ($Response.Contains($key)) { return @($Response[$key]) }
        }
        elseif ($Response.PSObject.Properties[$key]) {
            return @($Response.PSObject.Properties[$key].Value)
        }
    }
    return @($Response)
}

function Test-NotFoundError {
    <#
    .SYNOPSIS
        Is this error a 404 - i.e. the item is already gone?
    .DESCRIPTION
        A teardown racing itself (or re-run after a partial failure) will find items in
        the listing that a previous pass already deleted. That is success, not failure.
        Anything that is not a 404 is re-thrown untouched.
    #>
    param([Parameter(Mandatory)]$ErrorRecord)
    $exception = Get-TeardownValue -InputObject $ErrorRecord -Name 'Exception'
    $response = Get-TeardownValue -InputObject $exception -Name 'Response'
    $status = Get-TeardownValue -InputObject $response -Name 'StatusCode'
    if ($null -ne $status -and ([int]$status) -eq 404) { return $true }
    return ("$ErrorRecord" -match '(?i)\b404\b|ItemNotFound|WorkspaceNotFound')
}

function Get-FabricWorkspaceItem {
    <#
    .SYNOPSIS
        Every item in a workspace, following continuation tokens to the end.
    .DESCRIPTION
        Paging matters even for a demo workspace: a listing truncated at the page
        boundary would leave items behind and the teardown would report success.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$WorkspaceId
    )
    $items = @()
    $path = "workspaces/$WorkspaceId/items"
    while ($true) {
        $response = Invoke-FabricApi -Token $Token -Method GET -Path $path
        $items += @(Get-TeardownCollection -Response $response)
        $continuation = Get-TeardownValue -InputObject $response -Name 'continuationToken'
        if ([string]::IsNullOrWhiteSpace("$continuation")) { break }
        $path = "workspaces/$WorkspaceId/items?continuationToken=$([uri]::EscapeDataString("$continuation"))"
    }
    return @($items)
}

function Get-ItemDeletePath {
    <#
    .SYNOPSIS
        REST path for deleting one item: the typed operation when the type has one,
        otherwise the generic item endpoint. Pure function.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$ItemId,
        [AllowEmptyString()][string]$ItemType = '',
        [hashtable]$TypedDeletePath = @{},
        [switch]$HardDelete
    )
    $segment = $null
    foreach ($key in $TypedDeletePath.Keys) {
        if ($key -ieq $ItemType) { $segment = $TypedDeletePath[$key]; break }
    }
    if ($segment) {
        # The typed operations have no hardDelete query parameter; deleting a lakehouse
        # is already a full removal of the item and its data.
        return "workspaces/$WorkspaceId/$segment/$ItemId"
    }
    $path = "workspaces/$WorkspaceId/items/$ItemId"
    if ($HardDelete) { $path = "$($path)?hardDelete=true" }
    return $path
}

function Remove-FabricWorkspaceItem {
    <#
    .SYNOPSIS
        Delete one workspace item. 404 is treated as already-deleted.
    .OUTPUTS
        System.String - one of 'Deleted', 'NotFound' or 'WhatIf'. The caller tallies
        these rather than inferring an outcome from whether anything was thrown, so that
        "already gone" stays distinguishable from "deleted just now" in the run summary.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$ItemId,
        [string]$DisplayName = '',
        [string]$ItemType = '',
        [hashtable]$TypedDeletePath = @{},
        [switch]$HardDelete
    )
    $label = if ($DisplayName) { "$DisplayName ($ItemType)" } else { "$ItemId ($ItemType)" }
    if (-not $PSCmdlet.ShouldProcess($label, "Delete workspace item in $WorkspaceId")) {
        return 'WhatIf'
    }
    $path = Get-ItemDeletePath -WorkspaceId $WorkspaceId -ItemId $ItemId -ItemType $ItemType `
        -TypedDeletePath $TypedDeletePath -HardDelete:$HardDelete
    try {
        Invoke-FabricApi -Token $Token -Method DELETE -Path $path | Out-Null
        Write-Status "  deleted $label" -Color Gray
        return 'Deleted'
    }
    catch {
        if (Test-NotFoundError -ErrorRecord $_) {
            Write-Status "  already gone: $label" -Color DarkGray
            return 'NotFound'
        }
        throw
    }
}

function Get-ItemDeletionOrder {
    <#
    .SYNOPSIS
        Split a listing into (delete now, delete last, skip). Pure function.
    .DESCRIPTION
        Kept free of REST so the ordering contract - data agents before lakehouses,
        derived items never - is unit-testable without a workspace.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure classifier: partitions an in-memory list and deletes nothing. The deletes happen in Remove-FabricWorkspaceItem, which gates on ShouldProcess.')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Item,
        [string[]]$SkipItemType = @(),
        [string[]]$DeleteLastItemType = @()
    )
    $skip = @()
    $last = @()
    $first = @()
    # $entry, deliberately not $item: PowerShell variable names are case-insensitive, so
    # `foreach ($item in $Item)` would rebind the [object[]] parameter on every iteration
    # and re-coerce each element into a one-element array, leaving every `type` lookup
    # empty and every item silently classified as "delete now".
    foreach ($entry in $Item) {
        $type = "$(Get-TeardownValue -InputObject $entry -Name 'type')"
        if ($SkipItemType -contains $type) { $skip += $entry; continue }
        if ($DeleteLastItemType -contains $type) { $last += $entry; continue }
        $first += $entry
    }
    return [pscustomobject]@{ First = @($first); Last = @($last); Skipped = @($skip) }
}

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$WorkspaceName,
        [string[]]$SkipItemType = @(),
        [string[]]$DeleteLastItemType = @(),
        [hashtable]$TypedDeletePath = @{},
        [switch]$HardDelete
    )
    $empty = [pscustomobject]@{
        Workspace = $null
        Deleted   = @()
        Skipped   = @()
        NotFound  = @()
        Remaining = @()
    }

    # ---- workspace (shell survives; we only ever look it up) -------------------------
    $workspace = Get-FabricWorkspace -Token $Token -Name $WorkspaceName
    if (-not $workspace) {
        # Not an error: infra-down runs unconditionally and may execute before L5 has
        # ever created the workspace, or after a G3 deletion.
        Write-Status "Workspace '$WorkspaceName' does not exist - nothing to tear down." -Color Yellow
        return $empty
    }
    $workspaceId = "$(Get-TeardownValue -InputObject $workspace -Name 'id')"
    Write-Status "Workspace '$WorkspaceName' (id $workspaceId) - deleting its items; the workspace shell and its role assignments stay." -Color Cyan

    # ---- list ------------------------------------------------------------------------
    $items = @(Get-FabricWorkspaceItem -Token $Token -WorkspaceId $workspaceId)
    if ($items.Count -eq 0) {
        Write-Status 'Workspace holds no items - already torn down.' -Color Green
        $empty.Workspace = $workspace
        return $empty
    }

    $plan = Get-ItemDeletionOrder -Item $items -SkipItemType $SkipItemType -DeleteLastItemType $DeleteLastItemType
    Write-Status "$($items.Count) item(s): $($plan.First.Count) to delete, $($plan.Last.Count) deferred to the final pass, $($plan.Skipped.Count) derived (removed with their parent)." -Color Cyan
    foreach ($item in $plan.Skipped) {
        Write-Status "  skipping $(Get-TeardownValue -InputObject $item -Name 'displayName') ($(Get-TeardownValue -InputObject $item -Name 'type')) - owned by another item" -Color DarkGray
    }

    # ---- delete: everything else first, lakehouses last -------------------------------
    $deleted = @()
    $notFound = @()
    foreach ($item in @($plan.First) + @($plan.Last)) {
        $outcome = Remove-FabricWorkspaceItem -Token $Token -WorkspaceId $workspaceId `
            -ItemId "$(Get-TeardownValue -InputObject $item -Name 'id')" `
            -DisplayName "$(Get-TeardownValue -InputObject $item -Name 'displayName')" `
            -ItemType "$(Get-TeardownValue -InputObject $item -Name 'type')" `
            -TypedDeletePath $TypedDeletePath -HardDelete:$HardDelete `
            -WhatIf:$WhatIfPreference
        switch ($outcome) {
            'Deleted' { $deleted += $item }
            'NotFound' { $notFound += $item }
            default { }
        }
    }

    if ($WhatIfPreference) {
        Write-Status "(-WhatIf) Would delete $($plan.First.Count + $plan.Last.Count) item(s) from '$WorkspaceName'. The workspace and its role assignments would be left alone." -Color Yellow
        return [pscustomobject]@{
            Workspace = $workspace
            Deleted   = @()
            Skipped   = @($plan.Skipped)
            NotFound  = @()
            Remaining = @($items)
        }
    }

    # ---- verify (the down-state audit checks this too: kill-rebuild.md section 3) -----
    $remaining = @(Get-FabricWorkspaceItem -Token $Token -WorkspaceId $workspaceId)
    $stubborn = @($remaining | Where-Object { $SkipItemType -notcontains "$(Get-TeardownValue -InputObject $_ -Name 'type')" })
    if ($stubborn.Count -gt 0) {
        $names = ($stubborn | ForEach-Object { "$(Get-TeardownValue -InputObject $_ -Name 'displayName') ($(Get-TeardownValue -InputObject $_ -Name 'type'))" }) -join ', '
        throw "Deleted $($deleted.Count) item(s) but workspace '$WorkspaceName' still reports: $names. Teardown is INCOMPLETE - re-running infra-down is safe and idempotent."
    }
    Write-Status "Workspace '$WorkspaceName' emptied: $($deleted.Count) item(s) deleted, $($notFound.Count) already gone. Shell and role assignments intact." -Color Green

    return [pscustomobject]@{
        Workspace = $workspace
        Deleted   = @($deleted)
        Skipped   = @($plan.Skipped)
        NotFound  = @($notFound)
        Remaining = @($remaining)
    }
}

if (-not $env:MLS_SKIP_MAIN) {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'fabric-api.psm1') -Force
    Invoke-Main -Token $Token -WorkspaceName $WorkspaceName `
        -SkipItemType $SkipItemType -DeleteLastItemType $DeleteLastItemType `
        -TypedDeletePath $TypedDeletePath -HardDelete:$HardDelete
}
