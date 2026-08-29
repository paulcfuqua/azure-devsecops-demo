#Requires -Version 7.0
<#
.SYNOPSIS
    G0 bootstrap step 2 - Fabric capacity (human-run).

.DESCRIPTION
    -Mode Trial (default): prints the manual, portal-only steps to start the Fabric
    60-day trial capacity. Nothing is executed - the trial cannot be scripted.

    -Mode F2: creates a *paused* F2 capacity via `az rest` against the ARM
    Microsoft.Fabric provider, then suspends it immediately so it accrues no compute
    charges until a deploy resumes it. Idempotent: an existing capacity is reused and
    ensured Paused, never duplicated.

.NOTES
    *** GATE G2 *** -Mode F2 is a spend-profile increase (~$0.36/hr while resumed,
    ~$260/mo if left running). Do NOT run -Mode F2 without explicit G2 approval from the
    human sponsor (state cost delta + duration first). Trial mode is $0 and gate-free.

    Gate: G0 (human bootstrap). Agents author this file; they never execute it.

.EXAMPLE
    ./02-fabric-capacity.ps1                    # prints trial instructions
.EXAMPLE
    ./02-fabric-capacity.ps1 -Mode F2 -SubscriptionId <sub> -AdminUpn you@tenant -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Trial', 'F2')]
    [string]$Mode = 'Trial',

    # Required for -Mode F2.
    [ValidatePattern('^$|^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId = '',

    [string]$ResourceGroup = 'mls-rg-platform',

    # Fabric capacity names: lowercase letters and digits only.
    [ValidatePattern('^[a-z][a-z0-9]{2,62}$')]
    [string]$CapacityName = 'mlsfabricdemo',

    [string]$Location = 'eastus',

    # Value of the policy-enforced `owner` tag. Neutral fallback on purpose: this is a
    # public reference repo, and a hardcoded personal handle would tag every downstream
    # user's capacity with the original author's identity.
    [string]$Owner = '',

    # Capacity administrator UPN(s); required for -Mode F2.
    [string[]]$AdminUpn = @(),

    [string]$DeployerAppName = 'mls-github-deployer'
)

Set-StrictMode -Version Latest

$script:OwnerTag = if (-not [string]::IsNullOrWhiteSpace($Owner)) { $Owner }
elseif (-not [string]::IsNullOrWhiteSpace($env:MLS_OWNER)) { $env:MLS_OWNER }
else { 'mls-demo' }
$ErrorActionPreference = 'Stop'

$script:FabricApiVersion = '2023-11-01'

# --- plumbing (same contract as 01-root-oidc.ps1) --------------------------------------

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive bootstrap script; console output is the product.')]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $raw = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
    $text = ($raw | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

function Invoke-AzMutation {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    if ($PSCmdlet.ShouldProcess($Target, $Action)) {
        return Invoke-AzCli -Arguments $Arguments
    }
    return $null
}

function New-TempJsonFile {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$InputObject)
    $path = Join-Path ([IO.Path]::GetTempPath()) ("mls-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    if ($PSCmdlet.ShouldProcess($path, 'Write temporary JSON payload')) {
        # -InputObject (not pipeline) so single-element arrays stay JSON arrays.
        ConvertTo-Json -InputObject $InputObject -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
    }
    return $path
}

# --- trial mode ------------------------------------------------------------------------

function Show-TrialInstruction {
    param(
        [Parameter(Mandatory)][string]$DeployerAppName
    )
    Write-Status "`n== Fabric trial capacity - manual steps (portal-only, ~5 minutes, `$0) ==" -Color Cyan
    Write-Status @"

  1. Sign in to https://app.fabric.microsoft.com as the tenant admin user.
  2. Admin portal (gear icon -> Admin portal) -> Tenant settings:
       enable  "Users can try Microsoft Fabric"  (Help and support settings).
  3. Top-right account manager -> "Start trial" -> confirm. This creates the 60-day
     trial capacity assigned to your user.
  4. Admin portal -> Tenant settings -> Developer settings:
       enable  "Service principals can use Fabric APIs".
  5. Admin portal -> Capacity settings -> Trial -> your trial capacity ->
       Capacity administrators: add "$DeployerAppName".
  6. Record the capacity ID (Capacity settings -> your capacity -> Capacity ID) as the
     GitHub environment variable FABRIC_CAPACITY_ID. It is a config variable everywhere
     downstream (infra/fabric/provision-workspace.ps1 takes it as -CapacityId); moving
     to paid F2 later is one variable change + gate G2.

  NOTE: trial capacities have NO pause/suspend control - that is expected and costs
  `$0. Layer audits that check "capacity state == Paused" record
  'Active (trial, `$0/hr)' as the accepted Paused-equivalent while on the trial.

  None of these steps can be scripted; the Fabric trial and the SP-API toggle are
  portal-only (spec F2). Re-run this script with -Mode F2 only after G2 approval.
"@
}

# --- F2 mode ---------------------------------------------------------------------------

function Get-FabricCapacity {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$CapacityName
    )
    $url = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Fabric/capacities/$CapacityName" +
        "?api-version=$($script:FabricApiVersion)"
    return Invoke-AzCli -Arguments @('rest', '--method', 'get', '--url', $url) -AllowFailure
}

function New-FabricCapacityResource {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$CapacityName,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string[]]$AdminUpn
    )
    $url = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Fabric/capacities/$CapacityName" +
        "?api-version=$($script:FabricApiVersion)"
    $body = [ordered]@{
        location   = $Location
        sku        = [ordered]@{ name = 'F2'; tier = 'Fabric' }
        properties = [ordered]@{
            administration = [ordered]@{ members = @($AdminUpn) }
        }
        tags       = [ordered]@{
            env                = 'demo'
            app                = 'fabric'
            costCenter         = 'demo'
            owner              = $script:OwnerTag
            dataClassification = 'internal'
            managedBy          = 'iac'
        }
    }
    $payload = New-TempJsonFile -InputObject $body -WhatIf:$false -Confirm:$false
    try {
        return Invoke-AzMutation -Target $CapacityName -Action 'Create F2 Fabric capacity (G2-gated spend)' -Arguments @(
            'rest', '--method', 'put', '--url', $url, '--body', "@$payload"
        )
    }
    finally { Remove-Item -LiteralPath $payload -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false }
}

function Suspend-FabricCapacityResource {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$CapacityName
    )
    $url = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Fabric/capacities/$CapacityName/suspend" +
        "?api-version=$($script:FabricApiVersion)"
    return Invoke-AzMutation -Target $CapacityName -Action 'Suspend (pause) Fabric capacity' -Arguments @(
        'rest', '--method', 'post', '--url', $url
    )
}

# --- main ------------------------------------------------------------------------------

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Mode,
        [AllowEmptyString()][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$CapacityName,
        [Parameter(Mandatory)][string]$Location,
        [AllowEmptyCollection()][string[]]$AdminUpn,
        [Parameter(Mandatory)][string]$DeployerAppName
    )
    if ($Mode -eq 'Trial') {
        Show-TrialInstruction -DeployerAppName $DeployerAppName
        return [pscustomobject]@{ Mode = 'Trial'; Capacity = $null }
    }

    # ---- F2 (G2-gated) --------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        throw '-SubscriptionId is required for -Mode F2.'
    }
    if (@($AdminUpn).Count -eq 0) {
        throw '-AdminUpn is required for -Mode F2 (at least one capacity administrator UPN).'
    }
    Write-Status 'Mode F2: this creates billable capacity. Confirm G2 approval is on record before proceeding.' -Color Yellow

    $capacity = Get-FabricCapacity -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -CapacityName $CapacityName
    if ($capacity) {
        Write-Status "Fabric capacity '$CapacityName' already exists (state: $($capacity.properties.state)) - reusing." -Color Green
    }
    else {
        $capacity = New-FabricCapacityResource -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
            -CapacityName $CapacityName -Location $Location -AdminUpn $AdminUpn
        if ($capacity) { Write-Status "Created F2 capacity '$CapacityName'." -Color Green }
    }

    if ($capacity) {
        if ($capacity.properties.state -eq 'Paused') {
            Write-Status "Capacity '$CapacityName' is already Paused - no action." -Color Green
        }
        elseif ($WhatIfPreference) {
            Write-Status "(-WhatIf) Would suspend (pause) capacity '$CapacityName'." -Color Yellow
        }
        else {
            Suspend-FabricCapacityResource -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -CapacityName $CapacityName | Out-Null
            Write-Status "Capacity '$CapacityName' suspended (paused) - no compute charges until resumed (each resume is G2)." -Color Green
        }
        Write-Status "Record its capacity ID as GitHub environment variable FABRIC_CAPACITY_ID." -Color Cyan
    }
    else {
        Write-Status "(-WhatIf) Would create F2 capacity '$CapacityName' in $ResourceGroup/$Location and immediately suspend it." -Color Yellow
    }
    return [pscustomobject]@{ Mode = 'F2'; Capacity = $capacity }
}

if (-not $env:MLS_SKIP_MAIN) {
    Invoke-Main -Mode $Mode -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
        -CapacityName $CapacityName -Location $Location -AdminUpn $AdminUpn -DeployerAppName $DeployerAppName
}
