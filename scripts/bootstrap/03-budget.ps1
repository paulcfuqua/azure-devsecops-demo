#Requires -Version 7.0
<#
.SYNOPSIS
    G0 bootstrap step 3 - $75/month Cost Management budget with 50/80/100% email alerts.

.DESCRIPTION
    Creates (or updates) a subscription-scope Cost Management budget via `az rest`
    against Microsoft.Consumption/budgets. Alert notifications fire at 50%, 80% and
    100% of actual spend to the given email. Backstop behind gate G4's cost-anomaly
    trigger (docs/runbooks/g0-bootstrap.md, step C6).

    Idempotent: if the budget already exists with the desired amount, thresholds and
    contact email, the script no-ops; otherwise it PUTs the desired state (update, not
    duplicate - the budget name is the identity).

.NOTES
    Gate: G0 (human bootstrap). Agents author this file; they never execute it.

.EXAMPLE
    ./03-budget.ps1 -SubscriptionId <sub> -Email you@example.com -WhatIf
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
    [int]$Amount = 75
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BudgetApiVersion = '2023-05-01'
$script:AlertThresholds = @(50, 80, 100)

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
        [Parameter(Mandatory)][string]$Email
    )
    $monthStart = [datetime]::new([datetime]::UtcNow.Year, [datetime]::UtcNow.Month, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $notifications = [ordered]@{}
    foreach ($threshold in $script:AlertThresholds) {
        $notifications["Actual_GreaterThan_${threshold}_Percent"] = [ordered]@{
            enabled       = $true
            operator      = 'GreaterThan'
            threshold     = $threshold
            thresholdType = 'Actual'
            contactEmails = @($Email)
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

function Test-BudgetMatchesDesired {
    <# True when the existing budget already has the desired amount, thresholds and email. #>
    param(
        $Existing,
        [Parameter(Mandatory)][int]$Amount,
        [Parameter(Mandatory)][string]$Email
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
    }
    return $true
}

function Set-Budget {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$BudgetName,
        [Parameter(Mandatory)][int]$Amount,
        [Parameter(Mandatory)][string]$Email
    )
    $url = Get-BudgetUrl -SubscriptionId $SubscriptionId -BudgetName $BudgetName
    $body = Get-DesiredBudgetBody -Amount $Amount -Email $Email
    $payload = New-TempJsonFile -InputObject $body -WhatIf:$false -Confirm:$false
    try {
        return Invoke-AzMutation -Target $BudgetName -Action "Create/update `$$Amount monthly budget (alerts at $($script:AlertThresholds -join '/')% -> $Email)" -Arguments @(
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
        [Parameter(Mandatory)][int]$Amount
    )
    $existing = Get-Budget -SubscriptionId $SubscriptionId -BudgetName $BudgetName
    if (Test-BudgetMatchesDesired -Existing $existing -Amount $Amount -Email $Email) {
        Write-Status "Budget '$BudgetName' already matches desired state (`$$Amount/month, alerts 50/80/100% -> $Email) - no action." -Color Green
        return $existing
    }
    if ($existing) {
        Write-Status "Budget '$BudgetName' exists but drifts from desired state - updating in place." -Color Yellow
    }
    $result = Set-Budget -SubscriptionId $SubscriptionId -BudgetName $BudgetName -Amount $Amount -Email $Email
    if ($result) {
        Write-Status "Budget '$BudgetName' set: `$$Amount/month with alerts at 50/80/100% to $Email." -Color Green
    }
    else {
        Write-Status "(-WhatIf) Would set budget '$BudgetName': `$$Amount/month, alerts at 50/80/100% to $Email." -Color Yellow
    }
    return $result
}

if (-not $env:MLS_SKIP_MAIN) {
    Invoke-Main -SubscriptionId $SubscriptionId -Email $Email -BudgetName $BudgetName -Amount $Amount
}
