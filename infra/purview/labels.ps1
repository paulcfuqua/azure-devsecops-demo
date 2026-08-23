#Requires -Version 7.0
<#
.SYNOPSIS
    L4 Purview sensitivity labels - Public / Internal / Confidential / Export-Controlled.

.DESCRIPTION
    Creates the four-label taxonomy via Security & Compliance PowerShell
    (ExchangeOnlineManagement module). The caller must ALREADY be connected:

        Connect-IPPSSession -UserPrincipalName <admin-upn>

    This script never authenticates on its own. Idempotent: existing labels are left
    alone (or updated in place when display name / tooltip drift), never duplicated.
    Labels persist across kill/rebuild cycles by design (spec F6, master plan L4).

.NOTES
    Gate: L4 runs only after G1 approval + layer unblock. Teardown of labels is
    G3-gated and lives elsewhere; this script only creates/updates.

.EXAMPLE
    Connect-IPPSSession -UserPrincipalName admin@contoso.onmicrosoft.com
    ./labels.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive apply script; console output is the product.')]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

function Get-LabelTaxonomy {
    <# The four-label MLS taxonomy, lowest to highest sensitivity. #>
    return @(
        [pscustomobject]@{
            Name        = 'Public'
            DisplayName = 'Public'
            Tooltip     = 'Approved for public release. Launch dates, vehicle names, published mission facts.'
        }
        [pscustomobject]@{
            Name        = 'Internal'
            DisplayName = 'Internal'
            Tooltip     = 'MLS internal business information. Default for day-to-day operational data.'
        }
        [pscustomobject]@{
            Name        = 'Confidential'
            DisplayName = 'Confidential'
            Tooltip     = 'Sensitive MLS business data: telemetry summaries, supplier pricing, incident findings.'
        }
        [pscustomobject]@{
            Name        = 'Export-Controlled'
            DisplayName = 'Export-Controlled'
            Tooltip     = 'Fictional demo analogue of export-controlled technical data. Strictest handling.'
        }
    )
}

function Test-IppSession {
    <# Throws unless the Security & Compliance cmdlets are available (Connect-IPPSSession done). #>
    $cmd = Get-Command -Name 'Get-Label' -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw 'Security & Compliance cmdlets not found. Install-Module ExchangeOnlineManagement -Scope CurrentUser, then run Connect-IPPSSession before this script.'
    }
    return $true
}

function Get-ExistingLabel {
    param([Parameter(Mandatory)][string]$Name)
    try {
        return Get-Label -Identity $Name -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Initialize-SensitivityLabel {
    <# Create-if-absent / update-on-drift a single sensitivity label. Returns outcome string. #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Tooltip
    )
    $existing = Get-ExistingLabel -Name $Name
    if ($existing) {
        $driftFields = @()
        if ($existing.DisplayName -ne $DisplayName) { $driftFields += 'DisplayName' }
        if ($existing.Tooltip -ne $Tooltip) { $driftFields += 'Tooltip' }
        if ($driftFields.Count -eq 0) {
            Write-Status "Label '$Name' already correct - skipping." -Color Green
            return 'Unchanged'
        }
        if ($PSCmdlet.ShouldProcess($Name, "Update label ($($driftFields -join ', '))")) {
            Set-Label -Identity $Name -DisplayName $DisplayName -Tooltip $Tooltip | Out-Null
            Write-Status "Updated label '$Name' ($($driftFields -join ', '))." -Color Green
            return 'Updated'
        }
        return 'WhatIf'
    }
    if ($PSCmdlet.ShouldProcess($Name, 'Create sensitivity label')) {
        New-Label -Name $Name -DisplayName $DisplayName -Tooltip $Tooltip | Out-Null
        Write-Status "Created label '$Name'." -Color Green
        return 'Created'
    }
    return 'WhatIf'
}

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Test-IppSession | Out-Null
    $outcomes = [ordered]@{}
    foreach ($label in Get-LabelTaxonomy) {
        $outcomes[$label.Name] = Initialize-SensitivityLabel -Name $label.Name `
            -DisplayName $label.DisplayName -Tooltip $label.Tooltip
    }
    Write-Status ("Labels: " + (($outcomes.Keys | ForEach-Object { "$_=$($outcomes[$_])" }) -join ' ')) -Color Cyan
    return [pscustomobject]$outcomes
}

if (-not $env:MLS_SKIP_MAIN) {
    Invoke-Main
}
