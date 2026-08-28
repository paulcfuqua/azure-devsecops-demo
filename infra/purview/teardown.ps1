#Requires -Version 7.0
<#
.SYNOPSIS
    L4 Purview layer - G3 full-tenant teardown (F23). Removes the published label
    policy first, then the four sensitivity labels.

.DESCRIPTION
    The teardown half of infra/purview/labels.ps1's triplet (CLAUDE.md: "Every
    layer ships a deploy path, a teardown script, a verification audit script. A
    layer without all three is not done."). docs/runbooks/kill-rebuild.md section 7
    step 1 and docs/runbooks/layers/L04.md's Teardown section both name this exact
    path; before this file existed an operator following that numbered procedure
    hit file-not-found (spec F23).

    Order is the reverse of creation and is NOT interchangeable: a label still
    scoped by a published policy cannot be deleted, so Remove-LabelPolicy runs
    before any Remove-Label call. Uses the same Security & Compliance PowerShell
    surface labels.ps1 does (Get-Label, Get-LabelPolicy, Remove-Label,
    Remove-LabelPolicy) rather than inventing a new access pattern. The caller must
    already be connected:

        Connect-IPPSSession -UserPrincipalName <admin-upn>

.NOTES
    *** GATE G3 *** Full-tenant teardown: per-occurrence human approval with stated
    scope (docs/runbooks/kill-rebuild.md section 7). Recreated labels get NEW GUIDs
    - verification/reports/label-guids.json must be re-baselined in the PR that
    records the G3 approval. The standard kill/rebuild cycle never calls this
    script; labels persist across every ordinary cycle by design (spec F6).

    Never callable from CI: refuses to run when $env:GITHUB_ACTIONS -eq 'true'
    unless -AllowAutomation is passed explicitly. No workflow in this repo passes it.

    Authoring this script is permitted under CLAUDE.md hard rule 1 ("Authoring code
    is always allowed; executing deployments is not"). It has never been run against
    a live tenant - verified only by the mocked Pester suite in
    infra/purview/tests/teardown.Tests.ps1, zero cloud calls.

.EXAMPLE
    Connect-IPPSSession -UserPrincipalName admin@contoso.onmicrosoft.com
    ./teardown.ps1 -WhatIf

.EXAMPLE
    ./teardown.ps1 -Confirm:$false
    # G3 approval already on record: removes the label policy, then the four labels.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    # Opt-out of the CI refusal below. No workflow in this repo ever passes this.
    [switch]$AllowAutomation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive teardown script; console output is the product.')]
    param(
        # AllowEmptyString: the G3 banner prints blank spacer lines via
        # Write-Status '', which a bare Mandatory string parameter rejects.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    Write-Host $Message -ForegroundColor $Color
}

function Assert-NotAutomated {
    <# G3 teardown must never run unattended in CI; -AllowAutomation is the only opt-out. #>
    param([switch]$AllowAutomation)
    if ($env:GITHUB_ACTIONS -eq 'true' -and -not $AllowAutomation) {
        throw 'Refusing to run: $env:GITHUB_ACTIONS is ''true'' and -AllowAutomation was not passed. This is a G3 full-tenant teardown script (docs/runbooks/kill-rebuild.md section 7) and must never execute unattended in CI - no workflow in this repo passes -AllowAutomation.'
    }
}

function Write-G3Banner {
    <# Printed before any destructive call: the gate, the exact scope, the irreversible consequence. #>
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Consequence
    )
    Write-Status ''
    Write-Status '================ GATE G3: full-tenant Purview teardown ================' -Color Red
    Write-Status 'Per-occurrence human approval, stated scope (docs/runbooks/kill-rebuild.md section 7).' -Color Red
    Write-Status "Scope: $Scope" -Color Red
    Write-Status "Irreversible consequence: $Consequence" -Color Red
    Write-Status '=========================================================================' -Color Red
    Write-Status ''
}

function Get-LabelTaxonomy {
    <# The four-label MLS taxonomy, lowest to highest sensitivity - same literal
       list labels.ps1 defines, so this teardown removes exactly what that script
       creates and nothing else. #>
    return @('Public', 'Internal', 'Confidential', 'Export-Controlled')
}

function Get-LabelPolicyName {
    <# The single published policy name labels.ps1 publishes. #>
    return 'mls-demo-label-policy'
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

function Remove-SensitivityLabel {
    <#
    .SYNOPSIS
        Delete-if-present a single sensitivity label. Returns @{ Name; Existed }.
    .DESCRIPTION
        Existed tells the caller whether a delete was attempted; whether it was a
        real delete or a -WhatIf dry run is read from $WhatIfPreference at the
        Invoke-Main call site, the same reason apply-entra's teardown counterpart
        does - Remove-Label returns nothing useful to tell a real delete from a
        ShouldProcess decline.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name)
    $existing = Get-ExistingLabel -Name $Name
    if (-not $existing) {
        Write-Status "Label '$Name' already absent - nothing to delete." -Color DarkGray
        return @{ Name = $Name; Existed = $false }
    }
    if ($PSCmdlet.ShouldProcess($Name, 'Delete sensitivity label')) {
        Remove-Label -Identity $Name | Out-Null
        return @{ Name = $Name; Existed = $true }
    }
    return @{ Name = $Name; Existed = $true }
}

function Remove-PublishedLabelPolicy {
    <# Delete-if-present the label policy. Returns @{ Name; Existed }. Same shape as
       Remove-SensitivityLabel. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name)
    $existing = Get-ExistingLabelPolicy -Name $Name
    if (-not $existing) {
        Write-Status "Label policy '$Name' already absent - nothing to delete." -Color DarkGray
        return @{ Name = $Name; Existed = $false }
    }
    if ($PSCmdlet.ShouldProcess($Name, 'Delete label policy')) {
        Remove-LabelPolicy -Identity $Name | Out-Null
        return @{ Name = $Name; Existed = $true }
    }
    return @{ Name = $Name; Existed = $true }
}

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [switch]$AllowAutomation
    )
    Assert-NotAutomated -AllowAutomation:$AllowAutomation
    Test-IppSession | Out-Null

    $policyName = Get-LabelPolicyName
    $taxonomy = Get-LabelTaxonomy

    Write-G3Banner `
        -Scope "label policy '$policyName' and the four-label taxonomy ($($taxonomy -join ', '))." `
        -Consequence 'Recreated labels get NEW GUIDs - verification/reports/label-guids.json must be re-baselined in the PR that records this G3 approval.'

    $outcomes = [ordered]@{}

    # ---- policy first: a label still scoped by a published policy cannot be deleted ----
    $policyResult = Remove-PublishedLabelPolicy -Name $policyName
    if (-not $policyResult.Existed) { $outcomes['LabelPolicy'] = 'NotFound' }
    elseif ($WhatIfPreference) { $outcomes['LabelPolicy'] = 'WhatIf' }
    else {
        $outcomes['LabelPolicy'] = 'Deleted'
        Write-Status "Deleted label policy '$policyName'." -Color Green
    }

    # ---- then the four labels -----------------------------------------------------------
    foreach ($name in $taxonomy) {
        $result = Remove-SensitivityLabel -Name $name
        if (-not $result.Existed) { $outcomes[$name] = 'NotFound' }
        elseif ($WhatIfPreference) { $outcomes[$name] = 'WhatIf' }
        else {
            $outcomes[$name] = 'Deleted'
            Write-Status "Deleted label '$name'." -Color Green
        }
    }

    Write-Status ("Done: " + (($outcomes.Keys | ForEach-Object { "$_=$($outcomes[$_])" }) -join ' ')) -Color Cyan
    return [pscustomobject]$outcomes
}

if (-not $env:MLS_SKIP_MAIN) {
    Invoke-Main -AllowAutomation:$AllowAutomation
}
