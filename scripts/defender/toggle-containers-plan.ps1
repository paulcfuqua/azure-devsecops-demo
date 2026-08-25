#Requires -Version 7.0
<#
.SYNOPSIS
    Toggle the subscription-scope Microsoft Defender for Cloud `Containers` plan on or off.

.DESCRIPTION
    L9's only billable action. `docs/runbooks/layers/L09.md` V9.5 requires an
    enable -> assert -> disable round-trip, because a plan that was never enabled proves
    nothing: the Activity Log must show the paired Standard-then-Free writes.

    Idempotent by design. The desired tier is read first (`az security pricing show`) and
    the write is skipped when the plan is already in the requested state, so replaying the
    layer costs nothing and leaves no spurious Activity Log entry. That matters twice over:
    V9.5 counts pricings write events, and a script that wrote unconditionally would
    manufacture its own evidence.

    ARM has no "Off" for a Defender plan - it has pricing tiers. `Standard` is the plan
    switched on and `Free` is the plan switched off; that is what the portal shows as
    On/Off, and what V9.5 means by "leaving state Off". Foundational CSPM stays on and is
    free (spec F10); this script never touches it.

    -------------------------------------------------------------------------------------
    GATE G2 - SPEND INCREASE. READ BEFORE RUNNING WITH -Enable.
    -------------------------------------------------------------------------------------
      * Cost delta: ~USD 0.29 per day, prorated (Defender for Containers bills per hour of
        protected workload; the demo's estate is a handful of scale-to-zero container apps,
        which is roughly USD 9/month -> ~USD 0.29/day). Enabling for the minutes a V9.5
        round-trip takes costs cents, but the RUN RATE is what the gate is about, not the
        invoice.
      * Duration: minutes. The plan must be back to `Free` before the demo cycle closes.
      * Every -Enable is a FRESH G2. Approval is filed by the Orchestrator before the
        workflow runs (L09.md Preconditions); this script states the delta, it does not
        grant the gate.
      * -Disable is a spend DECREASE and needs no gate, ever. If V9.5 finds the tier still
        `Standard`, run `-Disable` immediately and root-cause afterwards (L09.md Rollback).
      * Leaving this plan enabled after a demo is failure mode 2 in the L9 playbook: a cost
        leak whose only backstop is the 50% budget alert.
    -------------------------------------------------------------------------------------

.PARAMETER Enable
    Set the plan to `Standard` (portal: On). G2-gated - see above.

.PARAMETER Disable
    Set the plan to `Free` (portal: Off). Always allowed.

.PARAMETER SubscriptionId
    Subscription whose plan is toggled. Defaults to $env:AZURE_SUBSCRIPTION_ID, then to the
    subscription the current `az` login is set to. Passed explicitly to `az` either way, so
    the target is never implicit in a CI log.

.NOTES
    Gate: G2 on each enable. Agents author this file; the workflow executes it under a
    filed gate. `.github/workflows/layer-09-devsecops.yml` runs the round-trip and disables
    in an `always()` step, so an enable is never left behind by a failing job.

.EXAMPLE
    ./toggle-containers-plan.ps1 -Enable -SubscriptionId <sub> -WhatIf

.EXAMPLE
    ./toggle-containers-plan.ps1 -Disable
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, ParameterSetName = 'Enable')]
    [switch]$Enable,

    [Parameter(Mandatory, ParameterSetName = 'Disable')]
    [switch]$Disable,

    [string]$SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string]$PlanName = 'Containers'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ARM's representation of the plan's On/Off states.
$script:EnabledTier = 'Standard'
$script:DisabledTier = 'Free'

# The stated G2 delta, in one place so the header, the banner and the summary agree.
$script:DailyCostDeltaUsd = '0.29'

# --- plumbing (same contract as scripts/bootstrap/03-budget.ps1) ------------------------

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Operator-facing toggle script; the console banner and state report are the product, exactly as in scripts/bootstrap/03-budget.ps1.')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
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

# --- building blocks --------------------------------------------------------------------

function Resolve-SubscriptionId {
    <# Explicit value, then the environment, then the current az login. Never implicit. #>
    param([AllowEmptyString()][AllowNull()][string]$SubscriptionId)
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) { return $SubscriptionId }
    $fromEnvironment = [Environment]::GetEnvironmentVariable('AZURE_SUBSCRIPTION_ID')
    if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) { return $fromEnvironment }
    $account = Invoke-AzCli -Arguments @('account', 'show', '--output', 'json') -AllowFailure
    $id = if ($account) { $account.id } else { $null }
    if ([string]::IsNullOrWhiteSpace($id)) {
        throw "Could not determine which subscription to toggle the Defender plan on. Pass -SubscriptionId, set `$env:AZURE_SUBSCRIPTION_ID, or run az login."
    }
    return "$id"
}

function Get-DefenderPlanTier {
    <# Current pricing tier, or '' when the plan has never been configured. #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$PlanName
    )
    $pricing = Invoke-AzCli -AllowFailure -Arguments @(
        'security', 'pricing', 'show', '--name', $PlanName,
        '--subscription', $SubscriptionId, '--output', 'json'
    )
    if ($null -eq $pricing) { return '' }
    $properties = $pricing.PSObject.Properties
    if ($properties.Name -contains 'pricingTier') { return "$($pricing.pricingTier)" }
    if ($properties.Name -contains 'properties' -and $pricing.properties) {
        return "$($pricing.properties.pricingTier)"
    }
    return ''
}

function Write-CostBanner {
    <#
    .SYNOPSIS
        The G2 banner. Printed on every run, not only on the write, so an operator who
        no-ops an already-enabled plan still sees the run rate they are carrying.
    #>
    param(
        [Parameter(Mandatory)][string]$DesiredTier,
        [Parameter(Mandatory)][string]$PlanName,
        [Parameter(Mandatory)][string]$SubscriptionId
    )
    $rule = '=' * 78
    if ($DesiredTier -eq $script:EnabledTier) {
        Write-Status $rule -Color Yellow
        Write-Status "GATE G2 - SPEND INCREASE: enabling Defender for Cloud '$PlanName'." -Color Yellow
        Write-Status "  subscription : $SubscriptionId" -Color Yellow
        Write-Status "  cost delta   : ~USD $($script:DailyCostDeltaUsd)/day, prorated (billed per protected-workload hour)" -Color Yellow
        Write-Status "  duration     : minutes - the V9.5 enable -> assert -> disable round-trip" -Color Yellow
        Write-Status "  YOU MUST LEAVE THIS PLAN 'Off' (tier '$($script:DisabledTier)') AFTER THE DEMO." -Color Yellow
        Write-Status "  Disabling is a spend decrease and needs no gate: re-run with -Disable." -Color Yellow
        Write-Status "  A plan left enabled is L09 failure mode 2 - a cost leak backstopped only" -Color Yellow
        Write-Status "  by the 50% budget alert." -Color Yellow
        Write-Status $rule -Color Yellow
        return
    }
    Write-Status $rule -Color Green
    Write-Status "Disabling Defender for Cloud '$PlanName' (tier '$($script:DisabledTier)' = portal Off)." -Color Green
    Write-Status "  subscription : $SubscriptionId" -Color Green
    Write-Status "  cost delta   : -USD $($script:DailyCostDeltaUsd)/day - a spend DECREASE, so no gate applies." -Color Green
    Write-Status "  This is the state every demo cycle must close in (L09.md V9.5)." -Color Green
    Write-Status $rule -Color Green
}

function Set-DefenderPlanTier {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$PlanName,
        [Parameter(Mandatory)][string]$Tier
    )
    $action = if ($Tier -eq $script:EnabledTier) {
        "Enable Defender plan (tier $Tier) - G2 spend increase, ~USD $($script:DailyCostDeltaUsd)/day"
    }
    else {
        "Disable Defender plan (tier $Tier) - spend decrease, no gate"
    }
    if (-not $PSCmdlet.ShouldProcess("$PlanName on subscription $SubscriptionId", $action)) {
        return $null
    }
    return Invoke-AzCli -Arguments @(
        'security', 'pricing', 'create', '--name', $PlanName, '--tier', $Tier,
        '--subscription', $SubscriptionId, '--output', 'json'
    )
}

# --- main -------------------------------------------------------------------------------

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('Standard', 'Free')][string]$DesiredTier,
        [Parameter(Mandatory)][string]$PlanName,
        [AllowEmptyString()][AllowNull()][string]$SubscriptionId
    )
    $subscription = Resolve-SubscriptionId -SubscriptionId $SubscriptionId
    Write-CostBanner -DesiredTier $DesiredTier -PlanName $PlanName -SubscriptionId $subscription

    $current = Get-DefenderPlanTier -SubscriptionId $subscription -PlanName $PlanName
    $describeCurrent = if ([string]::IsNullOrWhiteSpace($current)) { '(not configured)' } else { $current }

    if ($current -eq $DesiredTier) {
        Write-Status "Defender '$PlanName' is already at tier '$DesiredTier' - no write issued." -Color Green
        return [pscustomobject]@{
            Plan      = $PlanName
            Requested = $DesiredTier
            Previous  = $current
            Tier      = $current
            Changed   = $false
            WhatIf    = $false
        }
    }

    Write-Status "Defender '$PlanName': $describeCurrent -> $DesiredTier." -Color Cyan
    $result = Set-DefenderPlanTier -SubscriptionId $subscription -PlanName $PlanName -Tier $DesiredTier

    if ($null -eq $result) {
        # ShouldProcess said no: -WhatIf, or an operator answering no at a -Confirm prompt.
        Write-Status "(-WhatIf) Would set Defender '$PlanName' from $describeCurrent to '$DesiredTier'." -Color Yellow
        return [pscustomobject]@{
            Plan      = $PlanName
            Requested = $DesiredTier
            Previous  = $current
            Tier      = $current
            Changed   = $false
            WhatIf    = $true
        }
    }

    # Read back rather than trust the write: V9.5 asserts observed state, and so does this.
    $observed = Get-DefenderPlanTier -SubscriptionId $subscription -PlanName $PlanName
    if ($observed -ne $DesiredTier) {
        throw "Defender '$PlanName' still reads tier '$observed' after requesting '$DesiredTier'. Do not assume the write landed - re-run, and if this is an enable that half-applied, run -Disable immediately (a spend decrease needs no gate)."
    }
    Write-Status "Defender '$PlanName' is now at tier '$observed'." -Color Green
    if ($DesiredTier -eq $script:EnabledTier) {
        Write-Status "REMINDER: this subscription is now accruing ~USD $($script:DailyCostDeltaUsd)/day. Run -Disable before the demo cycle closes." -Color Yellow
    }
    return [pscustomobject]@{
        Plan      = $PlanName
        Requested = $DesiredTier
        Previous  = $current
        Tier      = $observed
        Changed   = $true
        WhatIf    = $false
    }
}

if (-not $env:MLS_SKIP_MAIN) {
    # Parameter sets already make exactly one of these mandatory; both are named here so the
    # intent is readable rather than implied by an else.
    $tier = if ($Enable) { $script:EnabledTier } elseif ($Disable) { $script:DisabledTier } else { '' }
    if ([string]::IsNullOrWhiteSpace($tier)) {
        throw 'Specify exactly one of -Enable (G2 spend increase) or -Disable (always allowed).'
    }
    Invoke-Main -DesiredTier $tier -PlanName $PlanName -SubscriptionId $SubscriptionId
}
