#Requires -Version 7.0
<#
.SYNOPSIS
    The azure-policy collector (spec section 4, plan Task 7): evidence from real Azure
    Policy compliance state, joined back to the NIST SP 800-171 catalog through the
    built-in "NIST SP 800-53 Rev. 5" regulatory compliance initiative.

.DESCRIPTION
    Nothing in this estate has been deployed (no G0 yet), so today this collector
    collects nothing - and that must render as a clean empty result, never an error and
    never a fabricated verdict about a tenant that does not exist.

    THE JOIN: 800-53 CONTROL GROUP -> 800-171 REQUIREMENT
    -----------------------------------------------------------
    Azure's built-in NIST SP 800-53 Rev. 5 initiative groups its policy definitions by
    `policyDefinitionGroupNames`, and for that specific built-in initiative each group
    name IS the NIST 800-53 control id (e.g. "SC-7", "AU-6") - this is how Azure Policy's
    own Regulatory Compliance blade attributes a policy's compliance state to a control.
    Task 1's catalog (compliance/catalog/nist-800-171r2.json) already carries the reverse
    of that mapping under each requirement's `mappings['nist-800-53r5']`, so this
    collector builds one lookup table (800-53 id -> 800-171 id list) from the catalog once
    and reverse-joins every policy state row through it. A control group name the catalog
    does not map to any 800-171 requirement (most of the initiative - 800-53 is far larger
    than 800-171) is silently skipped for that row, the same way verification-suite skips
    a criterion Task 2 deliberately left unmapped.

    DoNotEnforce: A SCORECARD IS NOT AN ENFORCED CONTROL
    -----------------------------------------------------------
    An initiative assignment's `enforcementMode` is a property of the ASSIGNMENT, not of
    any one policy state row - denormalised here onto the response's top-level
    `assignment` object rather than repeated per row, which is how a caller who queried
    the assignment once and the compliance state separately would naturally combine them.
    When it is `DoNotEnforce` (Azure defaults an omitted value to `Default`, i.e.
    enforced, exactly as the real API does), every row's status becomes `inconclusive`
    regardless of its own complianceState - an audit-mode initiative reports compliance it
    does not enforce, and rendering a "Compliant" row from it as `pass` would let a
    scorecard stand in for an enforced control.

    TWO INDEPENDENT FAILURE MODES, BOTH HANDLED PER ROW
    ---------------------------------------------------------
    Each policyState row is processed in its own try/catch: a row with no
    policyDefinitionGroupNames at all, or any other unusable shape, is skipped with a
    warning and the remaining rows are still evaluated - the same "one bad item does not
    cost the rest" discipline as Task 5's per-report handling.

.PARAMETER Response
    An object shaped like:
      { assignment: { enforcementMode: 'Default' | 'DoNotEnforce' },
        policyStates: [ { resourceId, policyAssignmentId, policyDefinitionGroupNames: [...],
                           complianceState: 'Compliant' | 'NonCompliant' }, ... ] }
    $null when the source (a live tenant) was not queried or is unreachable - the normal
    state today, since nothing in this estate has been deployed yet.

.OUTPUTS
    Zero or more validated EvidenceRecord objects (compliance/collectors/
    CollectorContract.psm1), each with `source` = 'azure-policy' and `criterion` = $null.
#>
[CmdletBinding()]
param(
    [object]$Response = $null
)

Set-StrictMode -Version Latest

$script:CollectorName = 'azure-policy'
$script:Response = $Response
$script:ControlMap = $null

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'CollectorContract.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'verification', 'MlsAudit.psm1') -Force

function Get-MlsAzurePolicyControlMap {
    <#
    .SYNOPSIS
        800-53 control id -> list of 800-171 requirement ids, built once from Task 1's
        catalog and cached for the life of the process.
    #>
    if ($null -ne $script:ControlMap) { return $script:ControlMap }

    $catalogPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'catalog', 'nist-800-171r2.json'
    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json

    $map = @{}
    foreach ($requirement in @(Get-MlsProperty -InputObject $catalog -Name 'requirements')) {
        $requirementId = "$(Get-MlsProperty -InputObject $requirement -Name 'id')".Trim()
        if ([string]::IsNullOrWhiteSpace($requirementId)) { continue }
        $mappings = Get-MlsProperty -InputObject $requirement -Name 'mappings'
        $eight53 = @(Get-MlsProperty -InputObject $mappings -Name 'nist-800-53r5')
        foreach ($controlId in $eight53) {
            $key = "$controlId".Trim()
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            if (-not $map.ContainsKey($key)) { $map[$key] = [System.Collections.Generic.List[string]]::new() }
            $map[$key].Add($requirementId)
        }
    }
    $script:ControlMap = $map
    return $script:ControlMap
}

Invoke-MlsCollector -Name $script:CollectorName -ScriptBlock {

    if ($null -eq $script:Response) {
        # No tenant to query yet - the normal state today, not an error.
        Write-Verbose "azure-policy: no response supplied; returning no evidence."
        return
    }

    $policyState = @(Get-MlsProperty -InputObject $script:Response -Name 'policyStates')
    if ($policyState.Count -eq 0) {
        Write-Verbose "azure-policy: response carries no policyStates; returning no evidence."
        return
    }

    # Allow-list, not deny-list. An earlier revision defaulted an absent or blank
    # enforcementMode to 'Default' and then asked whether it equalled 'DoNotEnforce',
    # so an entirely ABSENT assignment object, an explicit null, and any unrecognised
    # word (including ARM's alternate 'Disabled' spelling) all resolved to "enforced"
    # and a Compliant row rendered `pass`. This collector's own docstring says the
    # caller merges TWO endpoints - compliance state and the assignment - so the
    # half-merged case, where only the first query succeeded, is the likely one, and
    # it was the one that failed open. Absence of the enforcement signal is not
    # evidence of enforcement. Every other unrecognised-input path in this layer
    # fails closed to 'inconclusive'; this one now does too.
    $assignment = Get-MlsProperty -InputObject $script:Response -Name 'assignment'
    $enforcementMode = "$(Get-MlsProperty -InputObject $assignment -Name 'enforcementMode')".Trim()
    $enforcementKnown = $enforcementMode -in @('Default', 'DoNotEnforce')
    $auditOnly = $enforcementMode -ne 'Default'

    $controlMap = Get-MlsAzurePolicyControlMap

    foreach ($row in $policyState) {
        try {
            $groupName = @(Get-MlsProperty -InputObject $row -Name 'policyDefinitionGroupNames')
            if ($groupName.Count -eq 0) {
                throw 'no policyDefinitionGroupNames on this policy state row - cannot attribute it to any control'
            }

            $complianceState = "$(Get-MlsProperty -InputObject $row -Name 'complianceState')".Trim()
            $resourceId = "$(Get-MlsProperty -InputObject $row -Name 'resourceId')".Trim()
            if ([string]::IsNullOrWhiteSpace($resourceId)) { $resourceId = '(resource id not recorded)' }

            $status = if ($auditOnly) {
                # Either DoNotEnforce (a scorecard, not an enforced control) or an
                # enforcement signal we could not read at all. Never pass, whatever
                # complianceState says.
                'inconclusive'
            }
            else {
                switch ($complianceState) {
                    'Compliant' { 'pass' }
                    'NonCompliant' { 'fail' }
                    default { 'inconclusive' }
                }
            }

            $auditNote = if (-not $auditOnly) { '' }
            elseif ($enforcementKnown) {
                " Initiative assignment enforcementMode=DoNotEnforce: this is a compliance scorecard, not an enforced control."
            }
            elseif ([string]::IsNullOrWhiteSpace($enforcementMode)) {
                " Enforcement could not be determined: the response carried no assignment enforcementMode. Absence of the signal is not evidence of enforcement, so this is reported as inconclusive rather than as a pass."
            }
            else {
                " Enforcement could not be determined: assignment enforcementMode was '$enforcementMode', which is neither Default nor DoNotEnforce. Reported as inconclusive rather than assumed enforced."
            }

            $assignmentIdText = "$(Get-MlsProperty -InputObject $row -Name 'policyAssignmentId')".Trim()
            $artifactValue = if ([string]::IsNullOrWhiteSpace($assignmentIdText)) { $null } else { $assignmentIdText }
            $complianceStateText = if ([string]::IsNullOrWhiteSpace($complianceState)) { '(absent)' } else { $complianceState }

            foreach ($group in $groupName) {
                $groupText = "$group".Trim()
                if ([string]::IsNullOrWhiteSpace($groupText)) { continue }
                if (-not $controlMap.ContainsKey($groupText)) { continue }

                foreach ($requirementId in $controlMap[$groupText]) {
                    New-MlsEvidence -Control $requirementId -Source $script:CollectorName -Status $status `
                        -Observed ("Azure Policy 'NIST SP 800-53 Rev. 5' initiative, control group ${groupText}: " +
                            "complianceState=$complianceStateText on resource $resourceId.$auditNote") `
                        -Artifact $artifactValue
                }
            }
        }
        catch {
            Write-Warning "azure-policy: skipping policy state row - $($_.Exception.Message)"
        }
    }
}
