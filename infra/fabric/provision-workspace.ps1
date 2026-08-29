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

    Verifier access (FIXED 2026-08-26, F21 —
    compliance/findings/2026-08-26-prepublication-review.md#f21): this note used to
    claim "at L5 the mls-verifier service principal is granted the workspace VIEWER
    role on mls-operations... that grant happens in the L5 deploy path, not in this
    script." It did not happen anywhere: fabric-api.psm1 had no role-assignment
    function at all until Task 12 added one (Get-/Add-FabricWorkspaceRoleAssignment),
    and layer-05-fabric.yml's "Azure login (OIDC, mls-verifier — Reader + workspace
    Viewer)" step name was a LABEL, not a grant — it called nothing that assigns a
    Fabric role. verification/layer-05-audit.ps1:57 authenticates its Fabric calls as
    mls-verifier on the assumption that grant exists, so the L5 Verifier audit 403s
    without it. -VerifierPrincipalId below closes that gap the same way
    -DataApiPrincipalId (F13, Task 12) closes the data-api one — reusing
    Add-FabricWorkspaceRoleAssignment for a second, unrelated principal — and
    layer-05-fabric.yml's deploy job now resolves mls-verifier's service-principal
    object ID (via `az ad sp show --id $AZURE_VERIFIER_CLIENT_ID`, since only the
    app/client ID is configured anywhere) and passes it through. Granted role is
    always Viewer — read-only, matching mls-verifier's Reader-everywhere posture; a
    wider role would itself be a finding.

    Write access (F19, 2026-08-28): -CostIngestPrincipalId is the one grant this
    script makes that is NOT Viewer. The cost-ingest Function writes cost_daily
    into OneLake, and Viewer cannot write; Contributor is the lowest of Fabric's
    four workspace roles that can. The full argument - what Member and Admin would
    add, and why no narrower Fabric scope exists to use instead - is at the grant
    table in Invoke-Main.

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
    [string]$LakehouseName = 'mls_operations',

    # F13 (Task 12): object ID of the data-api user-assigned identity
    # (infra/bicep/apps/main.bicep's dataApiIdentity.outputs.principalId). Empty by
    # default so calling this script at L5 - before L7 creates that identity - is
    # unchanged. WIRED as of F24: layer-07-apps.yml's post-deploy step resolves the
    # identity's principal id and passes it here, after L7 has created it. Until
    # then this parameter had no caller at all, which was F24 itself - the
    # capability existed and the invocation did not.
    [string]$DataApiPrincipalId = '',

    # F21: object ID of the mls-verifier service principal (layer-05-fabric.yml's
    # deploy job resolves this from AZURE_VERIFIER_CLIENT_ID via `az ad sp show`,
    # since only the app/client ID is configured anywhere - Fabric role assignments
    # need the SP's object ID). Empty by default, same no-op-until-wired shape as
    # -DataApiPrincipalId above, so calling this script with no verifier configured
    # (G0 incomplete, or a fork that never set AZURE_VERIFIER_CLIENT_ID) is unchanged.
    [string]$VerifierPrincipalId = '',

    # F19: object ID of the cost-ingest Function's user-assigned identity
    # (infra/bicep/platform/main.bicep's costIngestIdentity, created at L6). Empty
    # by default, same no-op-until-passed shape as the two above. Wired by
    # layer-07-apps.yml's post-deploy step - see that workflow for why an
    # L6-created identity gets its Fabric grant from the L7 workflow.
    #
    # THIS IS THE ONE PRINCIPAL HERE THAT DOES NOT GET Viewer. The reason is in
    # Invoke-Main's grant table below; read it before changing this.
    [string]$CostIngestPrincipalId = ''
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
        [Parameter(Mandatory)][string]$LakehouseName,
        [string]$DataApiPrincipalId = '',
        [string]$VerifierPrincipalId = '',
        [string]$CostIngestPrincipalId = ''
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

    # ---- workspace role grants (F13 data-api; F21 mls-verifier; F19 cost-ingest) ---
    # Each entry is empty by default (see the -DataApiPrincipalId /
    # -VerifierPrincipalId / -CostIngestPrincipalId parameter headers) so this is a
    # no-op until a caller passes a principal. All three are wired now, from the
    # layer at which each principal actually exists:
    #   * VerifierPrincipalId   - layer-05-fabric.yml's deploy job (F21), because the
    #     L5 Verifier audit depends on it.
    #   * DataApiPrincipalId    - layer-07-apps.yml's post-deploy step (F24). It cannot
    #     be passed at L5: L5 runs before L7 creates the data-api identity, which is
    #     why this parameter sat with no caller at all until F24 - the same ordering
    #     problem F20 describes for the SQL grant.
    #   * CostIngestPrincipalId - layer-07-apps.yml as well (F19), even though that
    #     identity is created at L6. L5 and L6 run in PARALLEL in infra-up.yml, so L6
    #     cannot assume the workspace exists, and calling this create-if-absent script
    #     from there would race L5 to create it. L7 is the first point in the graph at
    #     which the identity and the workspace both exist.
    # A caller that passes none still gets the workspace and lakehouse, unchanged.
    #
    # ROLE IS PER-ENTRY, NOT A CONSTANT - and exactly one entry is not Viewer.
    #
    #   data-api and mls-verifier READ. Viewer is the least role that permits a read,
    #   and is what they get; anything wider would itself be a finding.
    #
    #   cost-ingest WRITES. It creates and replaces Files/cost_daily/month=YYYY-MM/
    #   in OneLake every time an export lands (apps/cost-ingest/src/lakehouse.ts), so
    #   Viewer is not merely tight for it, it is non-functional: Viewer is read-only
    #   and the PUT would 403. Fabric offers exactly four workspace roles - Admin,
    #   Member, Contributor, Viewer - and CONTRIBUTOR is the lowest of them that can
    #   write workspace data. The two above it add permissions this Function has no
    #   use for: Member can share the workspace and re-grant access to other
    #   principals, and Admin can additionally delete the workspace and manage every
    #   role assignment in it, including its own. Fabric exposes no data-plane role
    #   narrower than the workspace - there is no per-lakehouse or per-folder OneLake
    #   role a service principal can hold - so Contributor is the floor here, not a
    #   compromise. It is the broadest grant any workload identity holds in this
    #   estate; the argument is written where the grant is made so a reviewer meets
    #   it rather than having to reconstruct it.
    foreach ($grant in @(
            [pscustomobject]@{ Label = 'data-api identity'; PrincipalId = $DataApiPrincipalId; Role = 'Viewer' }
            [pscustomobject]@{ Label = 'mls-verifier'; PrincipalId = $VerifierPrincipalId; Role = 'Viewer' }
            [pscustomobject]@{ Label = 'cost-ingest identity'; PrincipalId = $CostIngestPrincipalId; Role = 'Contributor' }
        )) {
        if ([string]::IsNullOrWhiteSpace($grant.PrincipalId)) { continue }
        $existing = Get-FabricWorkspaceRoleAssignment -Token $Token -WorkspaceId $workspace.id -PrincipalId $grant.PrincipalId
        if ($existing -and $existing.role -eq $grant.Role) {
            Write-Status "$($grant.Label) already holds workspace role '$($grant.Role)' - reusing." -Color Green
            continue
        }
        if ($PSCmdlet.ShouldProcess($grant.PrincipalId, "Grant Fabric workspace role '$($grant.Role)' in workspace '$WorkspaceName'")) {
            Add-FabricWorkspaceRoleAssignment -Token $Token -WorkspaceId $workspace.id `
                -PrincipalId $grant.PrincipalId -PrincipalType ServicePrincipal -Role $grant.Role -Confirm:$false | Out-Null
            Write-Status "Granted $($grant.Label) workspace role '$($grant.Role)' on '$WorkspaceName'." -Color Green
        }
    }

    return [pscustomobject]@{ Workspace = $workspace; Lakehouse = $lakehouse; Tables = $tables }
}

if (-not $env:MLS_SKIP_MAIN) {
    Import-Module (Join-Path $PSScriptRoot 'fabric-api.psm1') -Force
    Invoke-Main -Token $Token -CapacityId $CapacityId -WorkspaceName $WorkspaceName -LakehouseName $LakehouseName `
        -DataApiPrincipalId $DataApiPrincipalId -VerifierPrincipalId $VerifierPrincipalId `
        -CostIngestPrincipalId $CostIngestPrincipalId
}
