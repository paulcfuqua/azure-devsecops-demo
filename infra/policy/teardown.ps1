#Requires -Version 7.0
<#
.SYNOPSIS
    L2 landing zone - G3 full-tenant teardown (F23). Removes the tag/location policy
    assignments, the NIST 800-53 R5 initiative assignment, moves the demo subscription
    back to the tenant root, then deletes management group `mls`.

.DESCRIPTION
    L2 has no apply SCRIPT at all - it deploys infra/bicep/landing-zone/main.bicep at
    targetScope = 'managementGroup' via `az deployment mg create`
    (.github/workflows/layer-02-landing-zone.yml). This teardown is therefore new
    ground, not a mirror of an existing PowerShell apply script, but it follows the
    repo's own `az` CLI convention exactly - the same Invoke-AzCli /
    Invoke-AzMutation shape scripts/bootstrap/02-fabric-capacity.ps1 already uses,
    checking $LASTEXITCODE explicitly after every `az` call
    ($PSNativeCommandUseErrorActionPreference defaults to $false in pwsh, so a
    failed `az` invocation does not throw on its own).

    docs/runbooks/kill-rebuild.md section 7 step 4 and
    docs/runbooks/layers/L02.md's Teardown section both name this exact path; before
    this file existed an operator following that numbered procedure hit
    file-not-found (spec F23).

    Order matters and is NOT interchangeable: a management group with a child
    subscription will not delete, so the subscription is moved back to the tenant
    root before the management group delete is attempted, and the policy/NIST
    assignments are removed before that (tidiness, and so a half-finished replay
    never leaves an assignment pointing at a management group that no longer
    exists). The management group NAME is resolved from infra/bicep/naming.bicep
    (managementGroupName(prefix) => prefix) exactly the way scripts/down.ps1's
    Get-CompanyPrefix already does - CLAUDE.md: "Company name and prefix are set
    once in infra/bicep/naming.bicep - do not hardcode 'mls' elsewhere."

.NOTES
    *** GATE G3 *** Full-tenant teardown: per-occurrence human approval with stated
    scope (docs/runbooks/kill-rebuild.md section 7). The standard kill/rebuild cycle
    never calls this script; the management group and its assignments persist
    across every ordinary cycle by design (spec F6) and `up.ps1` replays L2 as an
    idempotent no-op.

    Never callable from CI: refuses to run when $env:GITHUB_ACTIONS -eq 'true'
    unless -AllowAutomation is passed explicitly. No workflow in this repo passes it.

    Authoring this script is permitted under CLAUDE.md hard rule 1 ("Authoring code
    is always allowed; executing deployments is not"). It has never been run against
    a live tenant - verified only by the mocked Pester suite in
    infra/policy/tests/teardown.Tests.ps1, zero cloud calls.

.EXAMPLE
    ./teardown.ps1 -SubscriptionId <sub> -WhatIf

.EXAMPLE
    ./teardown.ps1 -SubscriptionId <sub> -Confirm:$false
    # G3 approval already on record: removes every policy assignment, the NIST
    # assignment, moves the subscription back to tenant root, then deletes MG `mls`.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    # Path to naming.bicep - the single source of the management group name
    # (CLAUDE.md). Overridable only so tests can point at a fixture.
    [string]$NamingFile = (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'bicep/naming.bicep'),

    # Demo subscription ID. Falls back to $env:AZURE_SUBSCRIPTION_ID (the same
    # variable every layer workflow already reads); empty skips the subscription
    # move and the NIST assignment delete, matching main.bicep's own
    # `if (!empty(demoSubscriptionId))` conditionals.
    [string]$SubscriptionId = '',

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
    Write-Status '================ GATE G3: full-tenant landing-zone teardown ================' -Color Red
    Write-Status 'Per-occurrence human approval, stated scope (docs/runbooks/kill-rebuild.md section 7).' -Color Red
    Write-Status "Scope: $Scope" -Color Red
    Write-Status "Irreversible consequence: $Consequence" -Color Red
    Write-Status '==============================================================================' -Color Red
    Write-Status ''
}

# --- az CLI plumbing (same contract as scripts/bootstrap/02-fabric-capacity.ps1) --------

function Invoke-AzCli {
    <# Single choke point for every `az` call (mocked in tests). Checks
       $LASTEXITCODE explicitly - pwsh does not throw on a failed native command by
       default ($PSNativeCommandUseErrorActionPreference is $false). #>
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
    <# Every mutating `az` call flows through here so -WhatIf gates all writes. #>
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

# --- naming (single source: infra/bicep/naming.bicep) -----------------------------------

function Get-ManagementGroupName {
    <#
    .SYNOPSIS
        Management group name, i.e. the company prefix - naming.bicep's
        managementGroupName(prefix) => prefix. Parsed the same way
        scripts/down.ps1's Get-CompanyPrefix already parses naming.bicep, so the
        name this script deletes can never drift from what L2 actually created.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cannot resolve the management group name: '$Path' does not exist. Names come from infra/bicep/naming.bicep and nowhere else (CLAUDE.md)."
    }
    $content = Get-Content -LiteralPath $Path -Raw
    $match = [regex]::Match($content, "var\s+defaultCompanyPrefix\s*=\s*'([^']+)'")
    if (-not $match.Success) {
        throw "Could not parse 'defaultCompanyPrefix' out of '$Path'."
    }
    return $match.Groups[1].Value
}

# --- spec data (the fixed assignment names infra/bicep/landing-zone/main.bicep creates) --

function Get-TagPolicyAssignmentName {
    <# Every tag-governance and allowed-locations assignment name main.bicep creates
       at management-group scope. Hardcoded here the same way labels.ps1 hardcodes
       its label taxonomy - this IS the spec, not a discovery query, because a
       teardown that instead lists-and-deletes-everything-at-scope risks sweeping an
       assignment this repo never created. #>
    return @(
        'require-env', 'require-app', 'require-costcenter', 'require-owner', 'require-dataclass',
        'require-managedby',
        'inherit-env', 'inherit-app', 'inherit-costcenter', 'inherit-owner', 'inherit-dataclass', 'inherit-managedby',
        'allowed-locations', 'allowed-locations-rg'
    )
}

function Get-NistAssignmentName {
    <# The NIST SP 800-53 R5 initiative assignment name main.bicep creates. #>
    return 'nist-800-53-r5'
}

function Get-SubscriptionScope {
    <# main.bicep's own comment on the nist80053r5 module is explicit: "Assigned at
       SUBSCRIPTION scope per the master plan... The AVM pattern module fans out to
       subscription scope via subscriptionId" - unlike the 14 tag/location
       assignments above, which stay at management-group scope. #>
    param([Parameter(Mandatory)][string]$SubscriptionId)
    return "/subscriptions/$SubscriptionId"
}

# --- delete-if-present -------------------------------------------------------------------

function Get-ExistingPolicyAssignment {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Scope)
    return Invoke-AzCli -AllowFailure -Arguments @('policy', 'assignment', 'show', '--name', $Name, '--scope', $Scope)
}

function Remove-PolicyAssignment {
    <#
    .SYNOPSIS
        Delete-if-present one policy assignment. Returns @{ Name; Existed }.
    .DESCRIPTION
        Existed tells the caller whether a delete was attempted; whether it was a
        real delete or a -WhatIf dry run is read from $WhatIfPreference at the
        Invoke-Main call site - `az policy assignment delete` prints nothing on
        success, the same ambiguity apply-entra's DELETE calls have.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Scope)
    $existing = Get-ExistingPolicyAssignment -Name $Name -Scope $Scope
    if (-not $existing) {
        Write-Status "Policy assignment '$Name' already absent - nothing to delete." -Color DarkGray
        return @{ Name = $Name; Existed = $false }
    }
    Invoke-AzMutation -Target $Name -Action 'Delete policy assignment' -Arguments @(
        'policy', 'assignment', 'delete', '--name', $Name, '--scope', $Scope
    ) | Out-Null
    return @{ Name = $Name; Existed = $true }
}

function Get-ManagementGroupSubscriptionId {
    <# Subscription IDs placed directly under the management group. Separated from
       the removal step so the "is it even placed here" question is answerable
       without attempting a mutation. #>
    param([Parameter(Mandatory)][string]$Name)
    $mg = Invoke-AzCli -AllowFailure -Arguments @('account', 'management-group', 'show', '--name', $Name, '--expand')
    if (-not $mg) { return @() }
    $children = @($mg.children)
    return @(
        $children |
            Where-Object { "$($_.type)" -like '*managementGroups/subscriptions' } |
            ForEach-Object { $_.name }
    )
}

function Remove-SubscriptionFromManagementGroup {
    <# Move the subscription back to the tenant root. Returns @{ SubscriptionId; Existed }. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$ManagementGroupName, [Parameter(Mandatory)][string]$SubscriptionId)
    $placed = @(Get-ManagementGroupSubscriptionId -Name $ManagementGroupName)
    if ($placed -notcontains $SubscriptionId) {
        Write-Status "Subscription '$SubscriptionId' is not under management group '$ManagementGroupName' - nothing to move." -Color DarkGray
        return @{ SubscriptionId = $SubscriptionId; Existed = $false }
    }
    Invoke-AzMutation -Target $SubscriptionId -Action "Move subscription back to tenant root (remove from '$ManagementGroupName')" -Arguments @(
        'account', 'management-group', 'subscription', 'remove', '--name', $ManagementGroupName, '--subscription', $SubscriptionId
    ) | Out-Null
    return @{ SubscriptionId = $SubscriptionId; Existed = $true }
}

function Get-ExistingManagementGroup {
    param([Parameter(Mandatory)][string]$Name)
    return Invoke-AzCli -AllowFailure -Arguments @('account', 'management-group', 'show', '--name', $Name)
}

function Remove-ManagementGroup {
    <# Delete-if-present the management group itself. Returns @{ Name; Existed }. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name)
    $existing = Get-ExistingManagementGroup -Name $Name
    if (-not $existing) {
        Write-Status "Management group '$Name' already absent - nothing to delete." -Color DarkGray
        return @{ Name = $Name; Existed = $false }
    }
    Invoke-AzMutation -Target $Name -Action 'Delete management group' -Arguments @(
        'account', 'management-group', 'delete', '--name', $Name
    ) | Out-Null
    return @{ Name = $Name; Existed = $true }
}

# --- main ----------------------------------------------------------------------------------

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [string]$NamingFile = (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'bicep/naming.bicep'),
        [AllowEmptyString()][string]$SubscriptionId = '',
        [switch]$AllowAutomation
    )
    Assert-NotAutomated -AllowAutomation:$AllowAutomation

    $mgName = Get-ManagementGroupName -Path $NamingFile
    $mgScope = "/providers/Microsoft.Management/managementGroups/$mgName"

    $effectiveSubscriptionId = $SubscriptionId
    if ([string]::IsNullOrWhiteSpace($effectiveSubscriptionId)) {
        $effectiveSubscriptionId = $env:AZURE_SUBSCRIPTION_ID
    }

    $assignmentNames = @(Get-TagPolicyAssignmentName)
    $nistName = Get-NistAssignmentName

    Write-G3Banner `
        -Scope "management group '$mgName': $($assignmentNames.Count) tag/location policy assignment(s), the NIST 800-53 R5 initiative assignment, the subscription placement, and the management group itself." `
        -Consequence "Deletes a tenant-level governance guardrail; rebuilding management group '$mgName' and re-placing the subscription restarts policy-assignment propagation, and policy compliance data resets."

    $summary = [ordered]@{
        AssignmentsDeleted = 0; AssignmentsNotFound = 0
        NistOutcome = ''
        SubscriptionOutcome = ''
        ManagementGroupOutcome = ''
        SkippedInWhatIf = 0
    }

    # ---- 1: tag + allowed-locations policy assignments -----------------------------------
    foreach ($name in $assignmentNames) {
        $result = Remove-PolicyAssignment -Name $name -Scope $mgScope
        if (-not $result.Existed) { $summary.AssignmentsNotFound++ }
        elseif ($WhatIfPreference) { $summary.SkippedInWhatIf++ }
        else { $summary.AssignmentsDeleted++; Write-Status "Deleted policy assignment '$name'." -Color Green }
    }

    # ---- 2: NIST initiative assignment (subscription scope, not MG scope - see
    #         Get-SubscriptionScope) ------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($effectiveSubscriptionId)) {
        Write-Status 'No subscription ID supplied (neither -SubscriptionId nor $env:AZURE_SUBSCRIPTION_ID) - skipping the NIST assignment (it is assigned at subscription scope, and there is no scope to check).' -Color Yellow
        $summary.NistOutcome = 'Skipped'
    }
    else {
        $nistScope = Get-SubscriptionScope -SubscriptionId $effectiveSubscriptionId
        $nistResult = Remove-PolicyAssignment -Name $nistName -Scope $nistScope
        if (-not $nistResult.Existed) { $summary.NistOutcome = 'NotFound' }
        elseif ($WhatIfPreference) { $summary.NistOutcome = 'WhatIf'; $summary.SkippedInWhatIf++ }
        else { $summary.NistOutcome = 'Deleted'; Write-Status "Deleted NIST initiative assignment '$nistName'." -Color Green }
    }

    # ---- 3: move the subscription back to tenant root (MG will not delete otherwise) -----
    if ([string]::IsNullOrWhiteSpace($effectiveSubscriptionId)) {
        Write-Status 'No subscription ID supplied (neither -SubscriptionId nor $env:AZURE_SUBSCRIPTION_ID) - skipping the subscription-placement step.' -Color Yellow
        $summary.SubscriptionOutcome = 'Skipped'
    }
    else {
        $subResult = Remove-SubscriptionFromManagementGroup -ManagementGroupName $mgName -SubscriptionId $effectiveSubscriptionId
        if (-not $subResult.Existed) { $summary.SubscriptionOutcome = 'NotFound' }
        elseif ($WhatIfPreference) { $summary.SubscriptionOutcome = 'WhatIf'; $summary.SkippedInWhatIf++ }
        else { $summary.SubscriptionOutcome = 'Deleted'; Write-Status "Moved subscription '$effectiveSubscriptionId' back to tenant root." -Color Green }
    }

    # ---- 4: delete the management group ----------------------------------------------------
    $mgResult = Remove-ManagementGroup -Name $mgName
    if (-not $mgResult.Existed) { $summary.ManagementGroupOutcome = 'NotFound' }
    elseif ($WhatIfPreference) { $summary.ManagementGroupOutcome = 'WhatIf'; $summary.SkippedInWhatIf++ }
    else { $summary.ManagementGroupOutcome = 'Deleted'; Write-Status "Deleted management group '$mgName'." -Color Green }

    $summaryObject = [pscustomobject]$summary
    Write-Status ("Done: " + (($summary.Keys | ForEach-Object { "$_=$($summary[$_])" }) -join ' ')) -Color Cyan
    return $summaryObject
}

if (-not $env:MLS_SKIP_MAIN) {
    Invoke-Main -NamingFile $NamingFile -SubscriptionId $SubscriptionId -AllowAutomation:$AllowAutomation
}
