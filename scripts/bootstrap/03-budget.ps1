#Requires -Version 7.0
<#
.SYNOPSIS
    G0 bootstrap step 3 - $75/month Cost Management budget with 50/80/100% actual and
    50/80% forecasted email alerts.

.DESCRIPTION
    Creates (or updates) a subscription-scope Cost Management budget via `az rest`
    against Microsoft.Consumption/budgets. Alert notifications fire at 50%, 80% and
    100% of actual spend, AND at 50% and 80% of forecasted spend, all to the given
    email. Backstop behind gate G4's cost-anomaly trigger (docs/runbooks/g0-bootstrap.md,
    step C6).

    F15 (compliance/findings/2026-08-26-prepublication-review.md#f15, Task 17): actual-
    cost notifications alone are not enough backstop for a flood against a wallet-facing
    endpoint. Cost Management's actual-cost data lags 8-24 hours behind real spend, which
    is longer than it takes to exhaust a $200 credit; forecasted-spend notifications use a
    same-day usage projection and fire well inside that window. The two notification sets
    are additive - forecasted thresholds supplement the actual ones, they do not replace
    them, since actual spend is still the ground truth once it lands.

    Idempotent: if the budget already exists with the desired amount, thresholds,
    contact email and action group, the script no-ops; otherwise it PUTs the desired
    state (update, not duplicate - the budget name is the identity).

    F17 (compliance/findings/2026-08-26-prepublication-review.md#f17, Task 19):
    -ActionGroupResourceId adds platform/main.bicep's security action group
    (alertActionGroup) to every notification's contactGroups, alongside contactEmails
    - additive, never a replacement - so cost and security alerting share one
    page-out path. Optional and empty by default because this script runs at G0,
    which precedes L6 on every infra-up.yml pass: the action group does not exist
    yet the first time a sponsor runs this. Re-run (idempotent) with
    -ActionGroupResourceId once L6 has deployed to add it as a supplementary
    contact.

.NOTES
    Gate: G0 (human bootstrap). Agents author this file; they never execute it.

.EXAMPLE
    ./03-budget.ps1 -SubscriptionId <sub> -Email you@example.com -WhatIf

.EXAMPLE
    # After L6 has deployed: share the security action group's page-out path.
    ./03-budget.ps1 -SubscriptionId <sub> -Email you@example.com `
        -ActionGroupResourceId /subscriptions/<sub>/resourceGroups/mls-rg-platform/providers/Microsoft.Insights/actionGroups/mls-obs-demo-ag
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$Email,

    [string]$BudgetName = 'mls-monthly-budget',

    [ValidateRange(1, 100000)]
    [int]$Amount = 75,

    # F17 (Task 19): empty by default - see .DESCRIPTION for why G0 cannot assume
    # this resource exists yet.
    [string]$ActionGroupResourceId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BudgetApiVersion = '2023-05-01'
$script:AlertThresholds = @(50, 80, 100)
# F15: Forecasted alerts close the 8-24h lag on Actual-only notifications (see the
# script's .DESCRIPTION). 100% is deliberately excluded here - forecast at 100% is
# noisy (it fires the moment the month's *projected* total first crosses the budget,
# often early in the month) and the Actual 100% threshold above already covers the
# "it happened" case.
$script:ForecastThresholds = @(50, 80)

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

# --- building blocks -------------------------------------------------------------------

function Get-BudgetUrl {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$BudgetName
    )
    return "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/budgets/$BudgetName" +
        "?api-version=$($script:BudgetApiVersion)"
}

function Get-Budget {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$BudgetName
    )
    $url = Get-BudgetUrl -SubscriptionId $SubscriptionId -BudgetName $BudgetName
    return Invoke-AzCli -Arguments @('rest', '--method', 'get', '--url', $url) -AllowFailure
}

function Get-DesiredBudgetBody {
    param(
        [Parameter(Mandatory)][int]$Amount,
        [Parameter(Mandatory)][string]$Email,
        [string]$ActionGroupResourceId = ''
    )
    $monthStart = [datetime]::new([datetime]::UtcNow.Year, [datetime]::UtcNow.Month, 1, 0, 0, 0, [DateTimeKind]::Utc)
    # F17 (Task 19): contactGroups is additive alongside contactEmails, never a
    # replacement - empty when no action group id is supplied (the common G0 case,
    # before L6 has deployed one; see this script's .DESCRIPTION).
    $contactGroups = if ($ActionGroupResourceId) { @($ActionGroupResourceId) } else { @() }
    $notifications = [ordered]@{}
    foreach ($threshold in $script:AlertThresholds) {
        $notifications["Actual_GreaterThan_${threshold}_Percent"] = [ordered]@{
            enabled       = $true
            operator      = 'GreaterThan'
            threshold     = $threshold
            thresholdType = 'Actual'
            contactEmails = @($Email)
            contactGroups = $contactGroups
        }
    }
    foreach ($threshold in $script:ForecastThresholds) {
        # F15: additive to, never a replacement for, the Actual notifications above -
        # Actual data lags 8-24h, Forecasted does not, and both sets stay enabled.
        $notifications["Forecasted_GreaterThan_${threshold}_Percent"] = [ordered]@{
            enabled       = $true
            operator      = 'GreaterThan'
            threshold     = $threshold
            thresholdType = 'Forecasted'
            contactEmails = @($Email)
            contactGroups = $contactGroups
        }
    }
    return [ordered]@{
        properties = [ordered]@{
            category      = 'Cost'
            amount        = $Amount
            timeGrain     = 'Monthly'
            timePeriod    = [ordered]@{
                startDate = $monthStart.ToString('yyyy-MM-ddTHH:mm:ssZ')
                endDate   = $monthStart.AddYears(5).ToString('yyyy-MM-ddTHH:mm:ssZ')
            }
            notifications = $notifications
        }
    }
}

function Test-NotificationContactGroupsMatchDesired {
    <# F17 (Task 19): contactGroups is authoritative on every run, same as
       contactEmails elsewhere in this function - no "preserve whatever is already
       there" merge semantics, consistent with how this script treats every other
       field. Running without -ActionGroupResourceId after previously supplying one
       is therefore a real, visible drift (triggers a PUT that removes it), not a
       silent no-op - deliberate, not an oversight. #>
    param($Note, [AllowEmptyString()][string]$ActionGroupResourceId)
    $existingGroups = @()
    if ($Note.PSObject.Properties.Name -contains 'contactGroups' -and $Note.contactGroups) {
        $existingGroups = @($Note.contactGroups)
    }
    if ($ActionGroupResourceId) { return ($existingGroups -contains $ActionGroupResourceId) }
    return ($existingGroups.Count -eq 0)
}

function Test-BudgetMatchesDesired {
    <# True when the existing budget already has the desired amount, thresholds,
       email and action-group wiring (F17, Task 19). #>
    param(
        $Existing,
        [Parameter(Mandatory)][int]$Amount,
        [Parameter(Mandatory)][string]$Email,
        [string]$ActionGroupResourceId = ''
    )
    if (-not $Existing) { return $false }
    $props = $Existing.properties
    if (-not $props) { return $false }
    if ([int]$props.amount -ne $Amount) { return $false }
    if ($props.timeGrain -ne 'Monthly') { return $false }
    $notificationNames = @()
    if ($props.PSObject.Properties.Name -contains 'notifications' -and $props.notifications) {
        $notificationNames = @($props.notifications.PSObject.Properties.Name)
    }
    foreach ($threshold in $script:AlertThresholds) {
        $name = "Actual_GreaterThan_${threshold}_Percent"
        if ($notificationNames -notcontains $name) { return $false }
        $note = $props.notifications.$name
        if (-not $note.enabled) { return $false }
        if ([int]$note.threshold -ne $threshold) { return $false }
        if (@($note.contactEmails) -notcontains $Email) { return $false }
        if (-not (Test-NotificationContactGroupsMatchDesired -Note $note -ActionGroupResourceId $ActionGroupResourceId)) { return $false }
    }
    foreach ($threshold in $script:ForecastThresholds) {
        $name = "Forecasted_GreaterThan_${threshold}_Percent"
        if ($notificationNames -notcontains $name) { return $false }
        $note = $props.notifications.$name
        if (-not $note.enabled) { return $false }
        if ([int]$note.threshold -ne $threshold) { return $false }
        if (@($note.contactEmails) -notcontains $Email) { return $false }
        if (-not (Test-NotificationContactGroupsMatchDesired -Note $note -ActionGroupResourceId $ActionGroupResourceId)) { return $false }
    }
    return $true
}

function Set-Budget {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$BudgetName,
        [Parameter(Mandatory)][int]$Amount,
        [Parameter(Mandatory)][string]$Email,
        [string]$ActionGroupResourceId = ''
    )
    $url = Get-BudgetUrl -SubscriptionId $SubscriptionId -BudgetName $BudgetName
    $body = Get-DesiredBudgetBody -Amount $Amount -Email $Email -ActionGroupResourceId $ActionGroupResourceId
    $payload = New-TempJsonFile -InputObject $body -WhatIf:$false -Confirm:$false
    $actionGroupSuffix = if ($ActionGroupResourceId) { "; action group $ActionGroupResourceId" } else { '' }
    try {
        return Invoke-AzMutation -Target $BudgetName -Action "Create/update `$$Amount monthly budget (actual alerts at $($script:AlertThresholds -join '/')%, forecast alerts at $($script:ForecastThresholds -join '/')% -> $Email$actionGroupSuffix)" -Arguments @(
            'rest', '--method', 'put', '--url', $url, '--body', "@$payload"
        )
    }
    finally { Remove-Item -LiteralPath $payload -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false }
}

# --- main ------------------------------------------------------------------------------

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$BudgetName,
        [Parameter(Mandatory)][int]$Amount,
        [string]$ActionGroupResourceId = ''
    )
    $existing = Get-Budget -SubscriptionId $SubscriptionId -BudgetName $BudgetName
    $actionGroupSuffix = if ($ActionGroupResourceId) { " + security action group $ActionGroupResourceId" } else { '' }
    if (Test-BudgetMatchesDesired -Existing $existing -Amount $Amount -Email $Email -ActionGroupResourceId $ActionGroupResourceId) {
        Write-Status "Budget '$BudgetName' already matches desired state (`$$Amount/month, actual alerts 50/80/100% + forecast alerts 50/80% -> $Email$actionGroupSuffix) - no action." -Color Green
        return $existing
    }
    if ($existing) {
        Write-Status "Budget '$BudgetName' exists but drifts from desired state - updating in place." -Color Yellow
    }
    $result = Set-Budget -SubscriptionId $SubscriptionId -BudgetName $BudgetName -Amount $Amount -Email $Email -ActionGroupResourceId $ActionGroupResourceId
    if ($result) {
        Write-Status "Budget '$BudgetName' set: `$$Amount/month with actual alerts at 50/80/100% and forecast alerts at 50/80% to $Email$actionGroupSuffix." -Color Green
    }
    else {
        Write-Status "(-WhatIf) Would set budget '$BudgetName': `$$Amount/month, actual alerts at 50/80/100% and forecast alerts at 50/80% to $Email$actionGroupSuffix." -Color Yellow
    }
    return $result
}

if (-not $env:MLS_SKIP_MAIN) {
    Invoke-Main -SubscriptionId $SubscriptionId -Email $Email -BudgetName $BudgetName -Amount $Amount `
        -ActionGroupResourceId $ActionGroupResourceId
}
