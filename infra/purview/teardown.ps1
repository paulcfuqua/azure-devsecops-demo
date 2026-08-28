#Requires -Version 7.0
<#
.SYNOPSIS
    L4 Purview layer - G3 full-tenant teardown (F23). Removes the published label
    policy first, then the four sensitivity labels THIS ESTATE CREATED.

    TWO INDEPENDENT OWNERSHIP CONTROLS (F32). The label names are prefixed with the
    company prefix read from infra/bicep/naming.bicep, and every delete additionally
    requires the label's GUID to appear in verification/reports/label-guids.json - the
    baseline this script's own banner has always named and never, until now, read.
    With no usable baseline, every delete is refused.

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
    [switch]$AllowAutomation,

    # The recorded label-GUID baseline that proves which labels this estate created
    # (F32). Defaults to verification/reports/label-guids.json, or MLS_LABEL_GUID_PATH
    # when that is set - the same resolution order verification/layer-04-audit.ps1
    # uses. With no usable baseline every delete is REFUSED.
    [string]$LabelGuidPath
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

function Get-CompanyPrefix {
    <#
    .SYNOPSIS
        Reads `defaultCompanyPrefix` out of infra/bicep/naming.bicep - the same helper,
        parsed the same way, as labels.ps1's.
    .DESCRIPTION
        This is the first of TWO independent controls on what this script may delete.
        Before F32 this function did not exist and the list below was the literal
        'Public', 'Internal', 'Confidential', 'Export-Controlled' - so against an
        adopter who had ever opened Microsoft Purview, this teardown deleted their
        production `Confidential` label, and every document already labelled with it
        lost its classification and its protection.
    #>
    param([string]$Path = (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'bicep', 'naming.bicep'))
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cannot resolve the label-name prefix: '$Path' does not exist. Names come from infra/bicep/naming.bicep and nowhere else (CLAUDE.md, 'Naming and tagging'). Nothing was deleted."
    }
    $content = Get-Content -LiteralPath $Path -Raw
    $match = [regex]::Match($content, "var\s+defaultCompanyPrefix\s*=\s*'([^']+)'")
    if (-not $match.Success) {
        throw "Could not parse 'defaultCompanyPrefix' out of '$Path'. Deleting sensitivity labels under a guessed prefix is exactly the defect this parse exists to prevent. Nothing was deleted."
    }
    return $match.Groups[1].Value
}

function Get-LabelTaxonomy {
    <# The four-label demo taxonomy, lowest to highest sensitivity - the same prefixed
       names labels.ps1 creates, so this teardown removes exactly what that script
       creates and nothing else. #>
    param([Parameter(Mandatory)][string]$Prefix)
    return @("$Prefix-public", "$Prefix-internal", "$Prefix-confidential", "$Prefix-export-controlled")
}

function Get-LabelPolicyName {
    <# The single published policy name labels.ps1 publishes. #>
    param([Parameter(Mandatory)][string]$Prefix)
    return "$Prefix-demo-label-policy"
}

function Get-LabelGuidBaseline {
    <#
    .SYNOPSIS
        The set of label GUIDs this estate is known to own, from
        verification/reports/label-guids.json. Returns $null when there is no usable
        baseline.
    .DESCRIPTION
        The SECOND of the two controls on what this script may delete, and the one that
        holds even if a name somehow still collides. The banner this script has always
        printed named label-guids.json; nothing ever read it. Now nothing is deleted
        unless its GUID is in it.

        Shape is the flat { "<display name>": "<guid>" } map
        verification/layer-04-audit.ps1 writes as evidence.labelGuids and the L4 PR
        commits. Only the VALUES are used: a label is ours because its GUID is one we
        recorded, never because its name looks familiar.

        Returns $null - not an empty set - when the file is absent, unparsable or
        carries no GUIDs, so the caller can tell "no baseline, refuse everything" from
        "baseline says this label is not ours".
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $document = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
    if ($null -eq $document) { return $null }
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($property in $document.PSObject.Properties) {
        $value = "$($property.Value)"
        if (-not [string]::IsNullOrWhiteSpace($value)) { [void]$set.Add($value) }
    }
    if ($set.Count -eq 0) { return $null }
    return $set
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
        Delete-if-present a single sensitivity label THIS ESTATE OWNS. Returns
        @{ Name; Existed; Confirmed; Refused; Guid }.
    .DESCRIPTION
        OWNERSHIP FIRST (F32). BaselineGuid is the set of GUIDs recorded in
        verification/reports/label-guids.json. A label is deleted only when the object
        the tenant actually returned carries one of those GUIDs. Everything else -
        no baseline file at all, a label with no readable GUID, a GUID that is not in
        the baseline - is REFUSED, not deleted, and reported as Refused. A name match
        is not evidence of ownership: names collide, GUIDs do not, and a label whose
        GUID we never recorded is by definition one this estate did not create.

        Existed tells the caller whether a delete was attempted; Confirmed - the
        boolean $PSCmdlet.ShouldProcess itself returned - tells the caller whether
        that attempt actually proceeded or was declined at the confirmation prompt.
        Remove-Label returns nothing useful to tell a real delete from a
        ShouldProcess decline, so Confirmed is the only signal; reading
        $WhatIfPreference at the Invoke-Main call site instead - as an earlier
        revision did - conflated "declined" with "deleted", since a decline and a
        -WhatIf dry run both leave $WhatIfPreference unchanged at $false (F23
        review, Critical 1 - reporting a declined delete as done is this finding's
        own namesake defect). ConfirmImpact is 'High' HERE, on the function that
        actually calls ShouldProcess - ConfirmImpact does not propagate from a
        caller to a callee, so declaring it only on Invoke-Main (as an earlier
        revision did) never triggered the default $ConfirmPreference of 'High'.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()]$BaselineGuid
    )
    $existing = Get-ExistingLabel -Name $Name
    if (-not $existing) {
        Write-Status "Label '$Name' already absent - nothing to delete." -Color DarkGray
        return @{ Name = $Name; Existed = $false; Confirmed = $false; Refused = $false; Guid = '' }
    }
    $guid = ''
    $guidProperty = $existing.PSObject.Properties['Guid']
    if ($guidProperty) { $guid = "$($guidProperty.Value)" }
    if ($null -eq $BaselineGuid) {
        Write-Status "REFUSED: '$Name' exists but there is no recorded GUID baseline to prove this estate created it. Nothing deleted." -Color Red
        return @{ Name = $Name; Existed = $true; Confirmed = $false; Refused = $true; Guid = $guid }
    }
    if ([string]::IsNullOrWhiteSpace($guid)) {
        Write-Status "REFUSED: '$Name' exists but returned no GUID, so ownership cannot be proven. Nothing deleted." -Color Red
        return @{ Name = $Name; Existed = $true; Confirmed = $false; Refused = $true; Guid = '' }
    }
    if (-not $BaselineGuid.Contains($guid)) {
        Write-Status "REFUSED: '$Name' has GUID $guid, which is NOT in the recorded baseline. This label was created by someone else - it is not this estate's to delete." -Color Red
        return @{ Name = $Name; Existed = $true; Confirmed = $false; Refused = $true; Guid = $guid }
    }
    $confirmed = $PSCmdlet.ShouldProcess($Name, 'Delete sensitivity label')
    if ($confirmed) {
        Remove-Label -Identity $Name | Out-Null
    }
    return @{ Name = $Name; Existed = $true; Confirmed = $confirmed; Refused = $false; Guid = $guid }
}

function Remove-PublishedLabelPolicy {
    <# Delete-if-present the label policy. Returns @{ Name; Existed; Confirmed }.
       Same shape as Remove-SensitivityLabel, including ConfirmImpact 'High' on
       this function itself rather than on Invoke-Main, and Confirmed coming
       directly from ShouldProcess's own return rather than $WhatIfPreference -
       see Remove-SensitivityLabel's note (F23 review, Critical 1). #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$Name)
    $existing = Get-ExistingLabelPolicy -Name $Name
    if (-not $existing) {
        Write-Status "Label policy '$Name' already absent - nothing to delete." -Color DarkGray
        return @{ Name = $Name; Existed = $false; Confirmed = $false }
    }
    $confirmed = $PSCmdlet.ShouldProcess($Name, 'Delete label policy')
    if ($confirmed) {
        Remove-LabelPolicy -Identity $Name | Out-Null
    }
    return @{ Name = $Name; Existed = $true; Confirmed = $confirmed }
}

function Invoke-Main {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [switch]$AllowAutomation,
        [string]$LabelGuidPath
    )
    Assert-NotAutomated -AllowAutomation:$AllowAutomation
    Test-IppSession | Out-Null

    $prefix = Get-CompanyPrefix
    $policyName = Get-LabelPolicyName -Prefix $prefix
    $taxonomy = Get-LabelTaxonomy -Prefix $prefix

    if ([string]::IsNullOrWhiteSpace($LabelGuidPath)) {
        $LabelGuidPath = [Environment]::GetEnvironmentVariable('MLS_LABEL_GUID_PATH')
    }
    if ([string]::IsNullOrWhiteSpace($LabelGuidPath)) {
        $LabelGuidPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'verification', 'reports', 'label-guids.json'
    }
    $baselineGuid = Get-LabelGuidBaseline -Path $LabelGuidPath
    if ($null -eq $baselineGuid) {
        Write-Status "No usable GUID baseline at '$LabelGuidPath'. Every label delete below will be REFUSED - run verification/layer-04-audit.ps1 and commit its evidence.labelGuids to that file first." -Color Red
    }
    else {
        Write-Status "GUID baseline: $($baselineGuid.Count) recorded label GUID(s) from '$LabelGuidPath'." -Color DarkGray
    }

    Write-G3Banner `
        -Scope "label policy '$policyName' and the four-label taxonomy ($($taxonomy -join ', ')) - and ONLY those of them whose GUID is in '$LabelGuidPath'." `
        -Consequence 'Recreated labels get NEW GUIDs - verification/reports/label-guids.json must be re-baselined in the PR that records this G3 approval.'

    $outcomes = [ordered]@{}

    # Existed means "found"; Confirmed means "ShouldProcess actually let the delete
    # through" - a declined prompt leaves Existed true but Confirmed false, and
    # must be reported as Declined, never as Deleted (F23 review, Critical 1).
    # $WhatIfPreference is checked first so a -WhatIf run still reports WhatIf
    # rather than Declined - both leave Confirmed false, but only one is a dry run.

    # ---- policy first: a label still scoped by a published policy cannot be deleted ----
    $policyResult = Remove-PublishedLabelPolicy -Name $policyName
    if (-not $policyResult.Existed) { $outcomes['LabelPolicy'] = 'NotFound' }
    elseif ($WhatIfPreference) { $outcomes['LabelPolicy'] = 'WhatIf' }
    elseif (-not $policyResult.Confirmed) {
        $outcomes['LabelPolicy'] = 'Declined'
        Write-Status "Declined: label policy '$policyName' was NOT deleted." -Color Yellow
    }
    else {
        $outcomes['LabelPolicy'] = 'Deleted'
        Write-Status "Deleted label policy '$policyName'." -Color Green
    }

    # ---- then the four labels -----------------------------------------------------------
    # Refused is checked BEFORE $WhatIfPreference: a refusal is a fact about the
    # tenant ("that label is not ours"), not an artefact of a dry run, and reporting
    # it as WhatIf would hide from a -WhatIf operator the one thing they most need to
    # know before approving G3.
    $refused = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $taxonomy) {
        $result = Remove-SensitivityLabel -Name $name -BaselineGuid $baselineGuid
        if (-not $result.Existed) { $outcomes[$name] = 'NotFound' }
        elseif ($result.Refused) {
            $outcomes[$name] = 'Refused'
            $refused.Add($name)
        }
        elseif ($WhatIfPreference) { $outcomes[$name] = 'WhatIf' }
        elseif (-not $result.Confirmed) {
            $outcomes[$name] = 'Declined'
            Write-Status "Declined: label '$name' was NOT deleted." -Color Yellow
        }
        else {
            $outcomes[$name] = 'Deleted'
            Write-Status "Deleted label '$name'." -Color Green
        }
    }

    Write-Status ("Done: " + (($outcomes.Keys | ForEach-Object { "$_=$($outcomes[$_])" }) -join ' ')) -Color Cyan
    if ($refused.Count -gt 0) {
        Write-Status "Refused $($refused.Count) label(s) whose GUID is not in the recorded baseline: $($refused -join ', '). Nothing about them was changed." -Color Red
    }
    return [pscustomobject]$outcomes
}

if (-not $env:MLS_SKIP_MAIN) {
    Invoke-Main -AllowAutomation:$AllowAutomation -LabelGuidPath $LabelGuidPath
}
