#Requires -Version 7.0
<#
.SYNOPSIS
    L4 Purview sensitivity labels - <prefix>-public / -internal / -confidential / -export-controlled.

.DESCRIPTION
    Creates the four-label taxonomy AND publishes the label policy that scopes it to
    the demo groups, via Security & Compliance PowerShell (ExchangeOnlineManagement
    module).

    EVERY LABEL NAME IS PREFIXED with the estate's company prefix, read from
    infra/bicep/naming.bicep (F32). These are tenant-level objects in the
    adopter's own Microsoft Purview: an unprefixed `Confidential` is not a create, it
    is a silent rewrite of whatever `Confidential` that tenant already had.

    The caller must ALREADY be connected:

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

function Get-CompanyPrefix {
    <#
    .SYNOPSIS
        Reads `defaultCompanyPrefix` out of infra/bicep/naming.bicep.
    .DESCRIPTION
        Same single source of truth, parsed the same way, as scripts/down.ps1's
        Get-CompanyPrefix, infra/policy/teardown.ps1's Get-ManagementGroupName and the
        .github/actions/naming composite action. CLAUDE.md forbids hardcoding the
        company prefix anywhere but naming.bicep, and F32 is exactly
        what happens when a tenant-level object is NOT prefixed: this script used to
        create labels called literally `Public`, `Internal`, `Confidential` and
        `Export-Controlled`, the three most common sensitivity-label names in
        existence. Against an adopter's existing Microsoft Purview taxonomy that is not
        a create - it is a silent in-place rewrite of their production `Confidential`
        label (and teardown.ps1 then deleted it).

        Refuses rather than guessing: a label name this script is not sure about is
        the whole defect.
    #>
    param([string]$Path = (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'bicep', 'naming.bicep'))
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cannot resolve the label-name prefix: '$Path' does not exist. Names come from infra/bicep/naming.bicep and nowhere else (CLAUDE.md, 'Naming and tagging'). Run this script from a clone of the repository."
    }
    $content = Get-Content -LiteralPath $Path -Raw
    $match = [regex]::Match($content, "var\s+defaultCompanyPrefix\s*=\s*'([^']+)'")
    if (-not $match.Success) {
        throw "Could not parse 'defaultCompanyPrefix' out of '$Path'. Creating sensitivity labels under a guessed prefix could collide with the tenant's own taxonomy; refusing."
    }
    return $match.Groups[1].Value
}

function Get-LabelTaxonomy {
    <#
        The four-label demo taxonomy, lowest to highest sensitivity, EVERY NAME
        PREFIXED with the estate's company prefix.

        The prefix is not cosmetic. These labels are tenant-level objects in an
        adopter's own Microsoft Purview, not resources in a disposable resource group:
        an unprefixed `Confidential` collides with the label a real organisation most
        likely already has, and this script's update-on-drift path would then rewrite
        that label's tooltip with demo text - in CI, under -Confirm:$false, with no
        prompt. Name and DisplayName are deliberately the same string so that both
        Get-Label -Identity (which matches Name) and verification/layer-04-audit.ps1
        (which matches DisplayName) address exactly the objects this script created.
    #>
    param([Parameter(Mandatory)][string]$Prefix)
    return @(
        [pscustomobject]@{
            Name        = "$Prefix-public"
            DisplayName = "$Prefix-public"
            Tooltip     = 'Approved for public release. Launch dates, vehicle names, published mission facts.'
        }
        [pscustomobject]@{
            Name        = "$Prefix-internal"
            DisplayName = "$Prefix-internal"
            Tooltip     = 'MLS internal business information. Default for day-to-day operational data.'
        }
        [pscustomobject]@{
            Name        = "$Prefix-confidential"
            DisplayName = "$Prefix-confidential"
            Tooltip     = 'Sensitive MLS business data: telemetry summaries, supplier pricing, incident findings.'
        }
        [pscustomobject]@{
            Name        = "$Prefix-export-controlled"
            DisplayName = "$Prefix-export-controlled"
            Tooltip     = 'Fictional demo analogue of export-controlled technical data. Strictest handling.'
        }
    )
}

function Get-LabelPolicyName {
    <# The single published policy name. Not Azure-resource-named (<prefix>-<app|role>-<env>-<type>
       does not apply - this is a tenant-level S&C object, same as the labels themselves,
       which are also named without that pattern) but prefixed for the same reason they
       are: it is created in the adopter's tenant, alongside whatever is already there. #>
    param([Parameter(Mandatory)][string]$Prefix)
    return "$Prefix-demo-label-policy"
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
    <#
        Create-if-absent / update-on-drift a single sensitivity label. Returns outcome
        string.

        ConfirmImpact is 'High' HERE, on the function that actually calls
        ShouldProcess - ConfirmImpact does not propagate from a caller to a callee, so
        declaring it on Invoke-Main alone would never trigger the default
        $ConfirmPreference of 'High' (the same lesson teardown.ps1's Remove-* wrappers
        record). Writing to a tenant-level sensitivity label is a high-impact operation
        in an adopter's own Purview, and an interactive operator should be asked.
        .github/workflows/layer-04-purview.yml still passes -Confirm:$false because a
        CI run cannot answer a prompt; the control that protects an adopter's existing
        taxonomy in that path is Get-LabelTaxonomy's prefix, not this decorator.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
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
    $prefix = Get-CompanyPrefix
    $outcomes = [ordered]@{}
    $taxonomy = Get-LabelTaxonomy -Prefix $prefix
    foreach ($label in $taxonomy) {
        $outcomes[$label.Name] = Initialize-SensitivityLabel -Name $label.Name `
            -DisplayName $label.DisplayName -Tooltip $label.Tooltip
    }
    $outcomes['LabelPolicy'] = Initialize-LabelPolicy -Name (Get-LabelPolicyName -Prefix $prefix) `
        -LabelName $taxonomy.Name -ExchangeLocation (Get-LabelPolicyScope)
    Write-Status ("Labels: " + (($outcomes.Keys | ForEach-Object { "$_=$($outcomes[$_])" }) -join ' ')) -Color Cyan
    return [pscustomobject]$outcomes
}

if (-not $env:MLS_SKIP_MAIN) {
    Invoke-Main
}
