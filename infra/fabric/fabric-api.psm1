#Requires -Version 7.0
<#
.SYNOPSIS
    Thin Microsoft Fabric REST API wrappers (L5 data platform).

.DESCRIPTION
    Service-principal-first wrappers over https://api.fabric.microsoft.com/v1.
    Every function takes an explicit bearer -Token (from GitHub OIDC ->
    `az account get-access-token --resource https://api.fabric.microsoft.com` in CI, or
    the human's token locally); the module never authenticates by itself and never
    stores credentials. Requires the tenant toggle "Service principals can use Fabric
    APIs" for SP tokens (spec F2 - portal-only, see 02-fabric-capacity.ps1).

    Capacity IDs are always parameters - never hardcoded (trial capacity today, paid
    F2 later is one variable change + gate G2).
#>

Set-StrictMode -Version Latest

$script:FabricApiBaseUrl = 'https://api.fabric.microsoft.com/v1'

function Invoke-FabricApi {
    <#
    .SYNOPSIS
        Single choke point for every Fabric REST call (mocked in tests).
    .PARAMETER Token
        Bearer access token for https://api.fabric.microsoft.com.
    .PARAMETER Path
        Path relative to /v1, e.g. 'workspaces' or 'workspaces/<id>/lakehouses'.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        $Body = $null
    )
    $uri = "$($script:FabricApiBaseUrl)/$Path"
    $headers = @{ Authorization = "Bearer $Token" }
    if ($null -ne $Body) {
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers `
            -Body ($Body | ConvertTo-Json -Depth 10) -ContentType 'application/json'
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

function Get-CollectionValue {
    <# Normalize a Fabric collection response ({value:[...]} or {data:[...]}) to an array. #>
    param($Response)
    if ($null -eq $Response) { return @() }
    if ($Response -is [System.Collections.IDictionary]) {
        foreach ($key in @('value', 'data')) {
            if ($Response.Contains($key)) { return @($Response[$key]) }
        }
        return @($Response)
    }
    foreach ($key in @('value', 'data')) {
        $prop = $Response.PSObject.Properties[$key]
        if ($prop) { return @($prop.Value) }
    }
    return @($Response)
}

function Get-FabricWorkspace {
    <#
    .SYNOPSIS
        Workspace by display name, or $null when absent.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Name
    )
    $response = Invoke-FabricApi -Token $Token -Method GET -Path 'workspaces'
    $found = @(Get-CollectionValue -Response $response | Where-Object { $_ -and $_.displayName -eq $Name })
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

function New-FabricWorkspace {
    <#
    .SYNOPSIS
        Create a workspace on the given capacity. CapacityId is a required parameter by
        design - it always comes from configuration, never a hardcoded value.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$CapacityId,
        [string]$Description = ''
    )
    if ($PSCmdlet.ShouldProcess($Name, "Create Fabric workspace on capacity $CapacityId")) {
        $body = [ordered]@{
            displayName = $Name
            capacityId  = $CapacityId
        }
        if ($Description) { $body['description'] = $Description }
        return Invoke-FabricApi -Token $Token -Method POST -Path 'workspaces' -Body $body
    }
    return $null
}

function Get-FabricLakehouse {
    <#
    .SYNOPSIS
        Lakehouse by display name within a workspace, or $null when absent.
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$Name
    )
    $response = Invoke-FabricApi -Token $Token -Method GET -Path "workspaces/$WorkspaceId/lakehouses"
    $found = @(Get-CollectionValue -Response $response | Where-Object { $_ -and $_.displayName -eq $Name })
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

function New-FabricLakehouse {
    <#
    .SYNOPSIS
        Create a lakehouse in a workspace.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$Name,
        [string]$Description = ''
    )
    if ($PSCmdlet.ShouldProcess($Name, "Create lakehouse in workspace $WorkspaceId")) {
        $body = [ordered]@{ displayName = $Name }
        if ($Description) { $body['description'] = $Description }
        return Invoke-FabricApi -Token $Token -Method POST -Path "workspaces/$WorkspaceId/lakehouses" -Body $body
    }
    return $null
}

function Get-FabricTable {
    <#
    .SYNOPSIS
        List the Delta tables of a lakehouse (the L5 audit compares this to the manifest).
    #>
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$LakehouseId
    )
    $response = Invoke-FabricApi -Token $Token -Method GET -Path "workspaces/$WorkspaceId/lakehouses/$LakehouseId/tables"
    return @(Get-CollectionValue -Response $response)
}

Export-ModuleMember -Function @(
    'Invoke-FabricApi',
    'Get-FabricWorkspace',
    'New-FabricWorkspace',
    'Get-FabricLakehouse',
    'New-FabricLakehouse',
    'Get-FabricTable'
)
