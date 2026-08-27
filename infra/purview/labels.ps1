#Requires -Version 7.0
<#
.SYNOPSIS
    L4 Purview sensitivity labels - Public / Internal / Confidential / Export-Controlled.

.DESCRIPTION
    Creates the four-label taxonomy AND publishes the label policy that scopes it to
    the demo groups, via Security & Compliance PowerShell (ExchangeOnlineManagement
    module). The caller must ALREADY be connected:

        Connect-IPPSSession -UserPrincipalName <admin-upn>

    This script never authenticates on its own. Idempotent: existing labels and the
    label policy are left alone (or updated in place on drift), never duplicated.
    Labels and the policy persist across kill/rebuild cycles by design (spec F6,
    master plan L4). A label with no published policy cannot be applied to any
    content and enforces nothing (F18) - the policy publish step is what turns the
    taxonomy into a control.

    Auto-labeling for the `mls-operations` Fabric lakehouse is documented only, in
    `infra/purview/auto-label-design.md`; this script has no apply path for it (see
    that file and docs/runbooks/layers/L04.md Deploy procedure step 2 for why).

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

function Get-LabelPolicyName {
    <# The single published policy name. Not Azure-resource-named (mls-<app|role>-<env>-<type>
       does not apply - this is a tenant-level S&C object, same as the labels themselves,
       which are also named without that pattern). #>
    return 'mls-demo-label-policy'
}

function Get-LabelPolicyScope {
    <#
        The demo groups the label policy is published to. Source of truth:
        infra/entra/manifest.json groups[].displayName (all four - every demo user
        belongs to at least one). Kept as a literal list here, same as
        Get-LabelTaxonomy's literal label names, rather than reading the manifest file
        at runtime: labels.ps1 has no dependency on L3's manifest today and a read-only
        script inspecting another layer's input file is a bigger coupling than one
        four-item list kept in sync by hand.
    #>
    return @('mls-flight-operations', 'mls-security-team', 'mls-finance', 'mls-executives')
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

function Get-ExistingLabelPolicy {
    param([Parameter(Mandatory)][string]$Name)
    try {
        return Get-LabelPolicy -Identity $Name -ErrorAction Stop
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

function Initialize-LabelPolicy {
    <#
        Create-if-absent / update-on-drift the single policy publishing the four
        labels to the demo group scope. Same shape as Initialize-SensitivityLabel:
        read current state, no-op when it already matches, update in place on drift,
        create when absent, every mutation gated by -WhatIf. Returns outcome string.

        A label with no published policy is a directory object nobody can apply and
        that triggers no protection action - this is the step F18 exists to add.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$LabelName,
        [Parameter(Mandatory)][string[]]$ExchangeLocation
    )
    $existing = Get-ExistingLabelPolicy -Name $Name
    if ($existing) {
        $currentLabels = @($existing.Labels)
        $currentLocations = @($existing.ExchangeLocation)
        $labelsToAdd = @($LabelName | Where-Object { $currentLabels -notcontains $_ })
        $labelsToRemove = @($currentLabels | Where-Object { $LabelName -notcontains $_ })
        $locationsToAdd = @($ExchangeLocation | Where-Object { $currentLocations -notcontains $_ })
        $locationsToRemove = @($currentLocations | Where-Object { $ExchangeLocation -notcontains $_ })
        $driftFields = @()
        if ($labelsToAdd.Count -gt 0 -or $labelsToRemove.Count -gt 0) { $driftFields += 'Labels' }
        if ($locationsToAdd.Count -gt 0 -or $locationsToRemove.Count -gt 0) { $driftFields += 'ExchangeLocation' }
        if ($driftFields.Count -eq 0) {
            Write-Status "Label policy '$Name' already correct - skipping." -Color Green
            return 'Unchanged'
        }
        if ($PSCmdlet.ShouldProcess($Name, "Update label policy ($($driftFields -join ', '))")) {
            $setParams = @{ Identity = $Name }
            if ($labelsToAdd.Count -gt 0) { $setParams['AddLabel'] = $labelsToAdd }
            if ($labelsToRemove.Count -gt 0) { $setParams['RemoveLabel'] = $labelsToRemove }
            if ($locationsToAdd.Count -gt 0) { $setParams['AddExchangeLocation'] = $locationsToAdd }
            if ($locationsToRemove.Count -gt 0) { $setParams['RemoveExchangeLocation'] = $locationsToRemove }
            Set-LabelPolicy @setParams | Out-Null
            Write-Status "Updated label policy '$Name' ($($driftFields -join ', '))." -Color Green
            return 'Updated'
        }
        return 'WhatIf'
    }
    if ($PSCmdlet.ShouldProcess($Name, 'Publish label policy')) {
        New-LabelPolicy -Name $Name -Labels $LabelName -ExchangeLocation $ExchangeLocation | Out-Null
        Write-Status "Published label policy '$Name' scoped to: $($ExchangeLocation -join ', ')." -Color Green
        return 'Created'
    }
    return 'WhatIf'
}

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Test-IppSession | Out-Null
    $outcomes = [ordered]@{}
    $taxonomy = Get-LabelTaxonomy
    foreach ($label in $taxonomy) {
        $outcomes[$label.Name] = Initialize-SensitivityLabel -Name $label.Name `
            -DisplayName $label.DisplayName -Tooltip $label.Tooltip
    }
    $outcomes['LabelPolicy'] = Initialize-LabelPolicy -Name (Get-LabelPolicyName) `
        -LabelName $taxonomy.Name -ExchangeLocation (Get-LabelPolicyScope)
    Write-Status ("Labels: " + (($outcomes.Keys | ForEach-Object { "$_=$($outcomes[$_])" }) -join ' ')) -Color Cyan
    return [pscustomobject]$outcomes
}

if (-not $env:MLS_SKIP_MAIN) {
    Invoke-Main
}
