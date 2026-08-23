#Requires -Version 7.0
<#
.SYNOPSIS
    L5 provisioning - Fabric workspace `mls-operations` + lakehouse, idempotently.

.DESCRIPTION
    Ensures the demo workspace exists on the given capacity, ensures the lakehouse
    exists inside it, and lists the lakehouse tables (the seed step and the L5 audit
    consume that list). Uses the wrappers in ./fabric-api.psm1; every REST call
    carries the caller-supplied bearer token.

    -CapacityId is REQUIRED and comes from configuration (GitHub environment variable
    FABRIC_CAPACITY_ID) - trial capacity today, paid F2 later, never hardcoded here.

.NOTES
    Gate: L5 runs only after G1 approval + layer unblock; resuming a paused paid
    capacity is G2 each time (this script does not resume capacities).

    Verifier access: at L5 the `mls-verifier` service principal is granted the
    workspace VIEWER role on `mls-operations` (workspace role assignment, read-only)
    so the Verifier can audit workspace/lakehouse/table state without deployer
    credentials. That grant happens in the L5 deploy path, not in this script.

.EXAMPLE
    $token = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
    ./provision-workspace.ps1 -Token $token -CapacityId $env:FABRIC_CAPACITY_ID -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Bearer token for https://api.fabric.microsoft.com (OIDC-derived in CI).
    [Parameter(Mandatory)]
    [string]$Token,

    # Fabric capacity ID from config (FABRIC_CAPACITY_ID) - never hardcoded.
    [Parameter(Mandatory)]
    [string]$CapacityId,

    [string]$WorkspaceName = 'mls-operations',

    # Lakehouse names allow letters, digits and underscores only.
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')]
    [string]$LakehouseName = 'mls_operations'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive provisioning script; console output is the product.')]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$CapacityId,
        [Parameter(Mandatory)][string]$WorkspaceName,
        [Parameter(Mandatory)][string]$LakehouseName
    )
    # ---- workspace -----------------------------------------------------------------
    $workspace = Get-FabricWorkspace -Token $Token -Name $WorkspaceName
    if ($workspace) {
        Write-Status "Workspace '$WorkspaceName' already exists (id $($workspace.id)) - reusing." -Color Green
    }
    else {
        $workspace = New-FabricWorkspace -Token $Token -Name $WorkspaceName -CapacityId $CapacityId `
            -Description 'MLS operations data platform (L5)' -WhatIf:$WhatIfPreference
        if ($workspace) {
            Write-Status "Created workspace '$WorkspaceName' on capacity $CapacityId." -Color Green
        }
        else {
            Write-Status "(-WhatIf) Would create workspace '$WorkspaceName' on capacity $CapacityId, then lakehouse '$LakehouseName'." -Color Yellow
            return [pscustomobject]@{ Workspace = $null; Lakehouse = $null; Tables = @() }
        }
    }

    # ---- lakehouse -----------------------------------------------------------------
    $lakehouse = Get-FabricLakehouse -Token $Token -WorkspaceId $workspace.id -Name $LakehouseName
    if ($lakehouse) {
        Write-Status "Lakehouse '$LakehouseName' already exists (id $($lakehouse.id)) - reusing." -Color Green
    }
    else {
        $lakehouse = New-FabricLakehouse -Token $Token -WorkspaceId $workspace.id -Name $LakehouseName `
            -Description 'MLS operations lakehouse - 10 Delta tables seeded by data/generators' -WhatIf:$WhatIfPreference
        if ($lakehouse) {
            Write-Status "Created lakehouse '$LakehouseName'." -Color Green
        }
        else {
            Write-Status "(-WhatIf) Would create lakehouse '$LakehouseName' in workspace '$WorkspaceName'." -Color Yellow
            return [pscustomobject]@{ Workspace = $workspace; Lakehouse = $null; Tables = @() }
        }
    }

    # ---- tables (read-only; seeding is a separate step) ----------------------------
    $tables = @(Get-FabricTable -Token $Token -WorkspaceId $workspace.id -LakehouseId $lakehouse.id)
    if ($tables.Count -gt 0) {
        Write-Status "Lakehouse tables ($($tables.Count)): $(($tables | ForEach-Object { $_.name }) -join ', ')" -Color Cyan
    }
    else {
        Write-Status 'Lakehouse has no tables yet - run the generator seed step next (L5).' -Color Yellow
    }
    return [pscustomobject]@{ Workspace = $workspace; Lakehouse = $lakehouse; Tables = $tables }
}

if (-not $env:MLS_SKIP_MAIN) {
    Import-Module (Join-Path $PSScriptRoot 'fabric-api.psm1') -Force
    Invoke-Main -Token $Token -CapacityId $CapacityId -WorkspaceName $WorkspaceName -LakehouseName $LakehouseName
}
