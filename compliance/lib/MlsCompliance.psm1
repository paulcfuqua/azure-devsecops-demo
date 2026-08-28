#Requires -Version 7.0
<#
.SYNOPSIS
    Status derivation for the self-auditing compliance platform: the one place a
    control's rendered status and its provenance are decided.

.DESCRIPTION
    `Get-MlsControlStatus` is a PURE function over (requirement, assessment, evidence).
    It reads no file, opens no socket, reads no clock and no environment variable, keeps
    no module-scope state, and mutates neither of its inputs. The same inputs produce the
    same output on every call, forever. That is not incidental: every honesty rule this
    platform makes is enforced here mechanically rather than by review discipline, and a
    function that consulted anything outside its arguments could not make that claim.

    TWO VOCABULARIES, DELIBERATELY NOT THE SAME ONE
    ------------------------------------------------
    The REGISTER vocabulary is what a human asserted, and compliance/README.md defines it:

      GAP    - a known open finding stands against this control.
      CLOSED - no known open finding stands against it. Deliberately WEAKER than "the
               control is met"; the register never asserts that anything is met.

    The DERIVED vocabulary is what this platform can justify saying:

      COMPLIANT | PARTIAL | GAP | INCONCLUSIVE | NOT_APPLICABLE | NOT_ASSESSED

    These are different things and are never conflated. `assertion.status` is MAPPED, never
    passed through - passing it through would emit `CLOSED`, a word that belongs to neither
    enum, straight onto the board.

    THE HONESTY INVARIANT
    ---------------------
    Two halves, both structural rather than defensive:

      1. `Provenance` is set by WHICH BRANCH FIRED, never from any input field. No input
         can therefore ask to be called machine-verified.
      2. `COMPLIANT` is reachable from the criteria branch ONLY - every claimed criterion
         collected and passing. An authored assertion can never produce it, whatever its
         status. The register's own definition says CLOSED is weaker than "the control is
         met", so deriving COMPLIANT from CLOSED would launder the weaker claim into the
         stronger one on the board. An authored CLOSED citing evidence derives to PARTIAL.

    compliance/tests/derivation.Tests.ps1 tests both halves as properties over a generated
    space of assertion shapes, including statuses the register could never legitimately
    hold.

    THE DERIVATION, IN ORDER
    ------------------------
    | Assessment                                          | Status         | Provenance      |
    |-----------------------------------------------------|----------------|-----------------|
    | $null                                               | NOT_ASSESSED   | none            |
    | authored against a different control                | NOT_ASSESSED   | none            |
    | not-applicable WITH naJustification                 | NOT_APPLICABLE | declared        |
    | not-applicable WITHOUT one                          | NOT_ASSESSED   | none            |
    | applicability neither applicable nor not-applicable | NOT_ASSESSED   | none            |
    | criteria, all present and passing                   | COMPLIANT      | machine-verified|
    | criteria, any failing                               | GAP            | machine-verified|
    | criteria, any inconclusive / skipped / MISSING      | INCONCLUSIVE   | machine-verified|
    | no criteria, assertion CLOSED, evidence cited       | PARTIAL        | asserted        |
    | no criteria, assertion GAP, evidence cited          | GAP            | asserted        |
    | no criteria, assertion unrecognised, evidence cited | INCONCLUSIVE   | asserted        |
    | no criteria, assertion citing nothing               | NOT_ASSESSED   | none            |
    | no criteria, no assertion                           | NOT_ASSESSED   | none            |

    A failure outranks a missing or inconclusive criterion (a known failure is the more
    actionable statement, and both are non-green). Where one criterion carries several
    evidence records, the worst outcome wins: corroboration cannot erase a failure.
    Evidence for criteria the assessment does not claim is discarded, so stray evidence
    can never silently upgrade a control.

    FAIL CLOSED
    -----------
    Nothing unrecognised may reach COMPLIANT or machine-verified. An unknown applicability,
    an unknown assertion status, a malformed evidence record, a criteria entry that is not
    a usable id, an assertion block that is not an object - each degrades to a non-claim
    rather than throwing, so one bad record cannot take down a 110-control run. Only the
    literal outcomes `pass` and `fail` are recognised (case-insensitively, whitespace
    trimmed); everything else, `passed` and `ok` included, is inconclusive.

    WHAT `Observed` CARRIES
    -----------------------
    The rows the decision actually rested on, so a UI can show its working and a reader can
    judge the criterion-to-control mapping themselves (spec section 6.1). Every row has the
    same seven fields whatever branch produced it:

      Kind        'criterion' | 'assertion' | 'justification' | 'mismatch'
      Criterion   the criterion id for a criterion row, otherwise $null
      Outcome     'pass' | 'fail' | 'inconclusive' | 'missing' for a criterion row,
                  otherwise $null
      Detail      the evidence record's own observed text; or, on the authored path, what
                  the register asserted and how many references it cited; or the N/A
                  justification; or what the control mismatch was
      Source      the collector that produced the record, or 'assessment-register'
      Artifact    the committed report the record came from, when it named one
      CollectedAt the record's own ISO-8601 stamp, when it named one

    Criterion rows appear one per CLAIMED criterion in declared order (a criterion nothing
    collected still gets a row, marked `missing`, so a control cannot degrade silently);
    a criterion collected more than once contributes one row per record. On the authored
    path there is exactly one row, and it NAMES the register's word without adopting it -
    which is what lets a board say "the author asserted CLOSED; the platform derives
    PARTIAL because nothing here was machine-verified". `Observed` is empty exactly when
    the decision rested on nothing.

    Spec section 3.3's state artifact carries `observed` as a single string; rendering
    these rows down to one is the state emitter's join (plan Task 8), not this function's.

    NO SCORE. The board reports counts by status and provenance, never a blended
    "% compliant" figure (spec section 3.4), so this module emits no percentage, ratio or
    score of any kind and no later task should add one here.

.EXAMPLE
    $r = Get-MlsControlStatus -Requirement @{ id = '3.5.3' } `
        -Assessment (Get-Content compliance/assessment/3.5.1.json -Raw | ConvertFrom-Json) `
        -Evidence @(@{ criterion = 'V3.3'; status = 'pass'; observed = 'CA policy enforced' })
#>

Set-StrictMode -Version Latest

function Get-MlsComplianceVocabulary {
    <#
    .SYNOPSIS
        The two vocabularies this module maps between, published as data.
    .DESCRIPTION
        Exported so the state emitter and the board count every status - including the
        ones with zero occurrences - from one list rather than inventing their own, and so
        the boundary between what a human asserted and what the platform derived is
        checkable by test rather than by reading prose. `CLOSED` is in RegisterStatus and
        never in Status; `COMPLIANT` is in Status and never in RegisterStatus.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    [pscustomobject]@{
        Status         = @('COMPLIANT', 'PARTIAL', 'GAP', 'INCONCLUSIVE', 'NOT_APPLICABLE', 'NOT_ASSESSED')
        Provenance     = @('machine-verified', 'asserted', 'declared', 'none')
        RegisterStatus = @('GAP', 'CLOSED')
    }
}

function Get-MlsComplianceField {
    <#
    .SYNOPSIS
        Field read from a hashtable or a PSObject that is safe under Set-StrictMode.
    .DESCRIPTION
        Assessments arrive either as hashtables (tests, fixtures) or as PSCustomObjects
        (ConvertFrom-Json), and a partial record is normal input rather than an error, so
        a missing field must yield $null instead of throwing. Under
        Set-StrictMode -Version Latest, PowerShell 7 throws on an absent key of a
        hashtable just as it does on an absent property of an object, so both need this.
    #>
    param(
        $InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    # Every value return is comma-wrapped: PowerShell unrolls a collection on output, which
    # would turn a criteria list of @($null) into a bare $null and a nested array into its
    # inner elements - both of which silently change what the derivation sees.
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return , $InputObject[$Name] }
        return $null
    }
    # A scalar where an object was expected is malformed input, not a field bag.
    if ($InputObject -is [string] -or $InputObject.GetType().IsPrimitive) { return $null }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return , $property.Value }
    return $null
}

function Get-MlsComplianceText {
    <#
    .SYNOPSIS
        The trimmed string form of a value, or $null when the value is not usable text.
    .DESCRIPTION
        The gate every free-text input passes through. A number, a boolean, an array, a
        null, an empty string and a whitespace-only string all reduce to $null, so a
        justification that justifies nothing and a criterion id that identifies nothing
        are indistinguishable from absent - which is what makes the fail-closed branches
        uniform.
    #>
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -isnot [string]) { return $null }
    $trimmed = $Value.Trim()
    if ($trimmed.Length -eq 0) { return $null }
    return $trimmed
}

function ConvertTo-MlsComplianceOutcome {
    <#
    .SYNOPSIS
        Normalise one evidence record's status to pass / fail / inconclusive.
    .DESCRIPTION
        Only the literal words `pass` and `fail` are recognised, case-insensitively and
        whitespace-trimmed. Everything else - `skip`, `pending`, `inconclusive`, `passed`,
        `ok`, `true`, a number, a missing field - is inconclusive. A collector that emits
        an unexpected word therefore turns controls grey, which is visible, rather than
        green, which is not.
    #>
    param($Value)

    $text = Get-MlsComplianceText $Value
    if ($null -eq $text) { return 'inconclusive' }
    switch ($text.ToLowerInvariant()) {
        'pass' { return 'pass' }
        'fail' { return 'fail' }
        default { return 'inconclusive' }
    }
}

function Merge-MlsComplianceOutcome {
    <#
    .SYNOPSIS
        Worst-outcome-wins fold over a control's criterion outcomes.
    .DESCRIPTION
        fail beats missing and inconclusive, which beat pass. A failure outranks an
        unknown because a known failure is the more actionable statement and neither is
        green; pass loses to everything because a single uncollected criterion must not
        leave a control looking verified.
    #>
    param(
        [Parameter(Mandatory)][string]$Current,
        [Parameter(Mandatory)][string]$Incoming
    )

    $rank = @{ 'pass' = 0; 'missing' = 1; 'inconclusive' = 1; 'fail' = 2 }
    if ($rank[$Incoming] -gt $rank[$Current]) { return $Incoming }
    return $Current
}

function New-MlsComplianceObservation {
    <#
    .SYNOPSIS
        One row of the working a derivation rested on. See the module header for the
        meaning of each field.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record; no system state is changed.')]
    param(
        [Parameter(Mandatory)][string]$Kind,
        $Criterion = $null,
        $Outcome = $null,
        $Detail = $null,
        $Source = $null,
        $Artifact = $null,
        $CollectedAt = $null
    )

    [pscustomobject]@{
        Kind        = $Kind
        Criterion   = $Criterion
        Outcome     = $Outcome
        Detail      = $Detail
        Source      = $Source
        Artifact    = $Artifact
        CollectedAt = $CollectedAt
    }
}

function New-MlsComplianceResult {
    <#
    .SYNOPSIS
        The three-field result Get-MlsControlStatus returns.
    .DESCRIPTION
        Status and Provenance are supplied by the calling branch, never read from input.
        Every exit from Get-MlsControlStatus goes through here, so there is exactly one
        place a provenance can be assigned and it is always a literal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record; no system state is changed.')]
    param(
        [Parameter(Mandatory)][ValidateSet('COMPLIANT', 'PARTIAL', 'GAP', 'INCONCLUSIVE',
            'NOT_APPLICABLE', 'NOT_ASSESSED')][string]$Status,
        [Parameter(Mandatory)][ValidateSet('machine-verified', 'asserted', 'declared', 'none')][string]$Provenance,
        $Observed = @()
    )

    [pscustomobject]@{
        Status     = $Status
        Provenance = $Provenance
        Observed   = @($Observed)
    }
}

function Get-MlsControlStatus {
    <#
    .SYNOPSIS
        Derive one control's status and provenance from its assessment and the evidence
        collected for it. Pure; see the module header for the full table and the honesty
        invariant it enforces.
    .PARAMETER Requirement
        The catalog entry being rendered. Its `id` is used for one thing only: to refuse
        an assessment authored against a different control, which is a wrong box even when
        the assessment itself is well formed. Nothing else about the requirement
        influences the derivation.
    .PARAMETER Assessment
        The `compliance/assessment/<control-id>.json` record, as a hashtable or a
        PSCustomObject. $null - the normal state for most of the 110 - derives
        NOT_ASSESSED.
    .PARAMETER Evidence
        Collector-emitted EvidenceRecords (spec section 4). Records whose `criterion` the
        assessment does not claim are discarded.
    .OUTPUTS
        [pscustomobject] with Status, Provenance and Observed. Nothing else - in
        particular, no percentage, ratio or score.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Requirement,
        $Assessment = $null,
        $Evidence = $null
    )

    # --- 1. Nothing authored -----------------------------------------------------------
    if ($null -eq $Assessment) {
        return New-MlsComplianceResult -Status 'NOT_ASSESSED' -Provenance 'none'
    }

    # --- 2. The assessment must be the one authored for THIS requirement ----------------
    # The register keys four of its records on 800-53 ids (CM-6, SI-4, IR-4, CP-9), so a
    # join that reaches an assessment through a framework mapping rather than an exact id
    # is a live possibility. CP-9's author wrote about CP-9, not about whichever 800-171
    # requirement maps to it.
    $requirementId = Get-MlsComplianceText (Get-MlsComplianceField -InputObject $Requirement -Name 'id')
    $assessedControl = Get-MlsComplianceText (Get-MlsComplianceField -InputObject $Assessment -Name 'control')
    if ($null -ne $requirementId -and $null -ne $assessedControl -and $requirementId -ne $assessedControl) {
        return New-MlsComplianceResult -Status 'NOT_ASSESSED' -Provenance 'none' -Observed (
            New-MlsComplianceObservation -Kind 'mismatch' -Source 'assessment-register' -Detail (
                "the assessment is authored against control '$assessedControl' " +
                "but was joined to requirement '$requirementId'"))
    }

    # --- 3. Applicability ---------------------------------------------------------------
    $applicability = Get-MlsComplianceText (Get-MlsComplianceField -InputObject $Assessment -Name 'applicability')

    if ($applicability -eq 'not-applicable') {
        # An unjustified N/A is the most common way real assessments inflate a score
        # (spec section 3.2), so it derives NOT_ASSESSED rather than NOT_APPLICABLE.
        $justification = Get-MlsComplianceText (
            Get-MlsComplianceField -InputObject $Assessment -Name 'naJustification')
        if ($null -eq $justification) {
            return New-MlsComplianceResult -Status 'NOT_ASSESSED' -Provenance 'none'
        }
        return New-MlsComplianceResult -Status 'NOT_APPLICABLE' -Provenance 'declared' -Observed (
            New-MlsComplianceObservation -Kind 'justification' -Source 'assessment-register' `
                -Detail $justification)
    }

    if ($applicability -ne 'applicable') {
        # Absent, blank or a word the schema does not permit: claim nothing.
        return New-MlsComplianceResult -Status 'NOT_ASSESSED' -Provenance 'none'
    }

    # --- 4. Criteria-driven: the only branch that can reach COMPLIANT -------------------
    $criteriaRaw = Get-MlsComplianceField -InputObject $Assessment -Name 'criteria'
    $criteria = @()
    if ($null -ne $criteriaRaw) { $criteria = @($criteriaRaw) }

    if ($criteria.Count -gt 0) {
        $observations = @()
        $worst = 'pass'

        foreach ($entry in $criteria) {
            $criterionId = Get-MlsComplianceText $entry

            $matched = @()
            if ($null -ne $criterionId) {
                foreach ($record in @($Evidence)) {
                    $recordCriterion = Get-MlsComplianceText (
                        Get-MlsComplianceField -InputObject $record -Name 'criterion')
                    if ($null -ne $recordCriterion -and $recordCriterion -eq $criterionId) {
                        $matched += , $record
                    }
                }
            }

            if ($matched.Count -eq 0) {
                # A claimed criterion nothing collected is shown, not omitted: a renamed
                # criterion must degrade loudly rather than silently.
                $observations += New-MlsComplianceObservation -Kind 'criterion' -Criterion $criterionId `
                    -Outcome 'missing' -Detail 'no evidence record was collected for this criterion'
                $worst = Merge-MlsComplianceOutcome -Current $worst -Incoming 'missing'
                continue
            }

            foreach ($record in $matched) {
                $outcome = ConvertTo-MlsComplianceOutcome (
                    Get-MlsComplianceField -InputObject $record -Name 'status')
                $observations += New-MlsComplianceObservation -Kind 'criterion' -Criterion $criterionId `
                    -Outcome $outcome `
                    -Detail (Get-MlsComplianceText (
                        Get-MlsComplianceField -InputObject $record -Name 'observed')) `
                    -Source (Get-MlsComplianceText (
                        Get-MlsComplianceField -InputObject $record -Name 'source')) `
                    -Artifact (Get-MlsComplianceText (
                        Get-MlsComplianceField -InputObject $record -Name 'artifact')) `
                    -CollectedAt (Get-MlsComplianceText (
                        Get-MlsComplianceField -InputObject $record -Name 'collectedAt'))
                $worst = Merge-MlsComplianceOutcome -Current $worst -Incoming $outcome
            }
        }

        $status = switch ($worst) {
            'fail' { 'GAP' }
            'pass' { 'COMPLIANT' }
            default { 'INCONCLUSIVE' }
        }
        return New-MlsComplianceResult -Status $status -Provenance 'machine-verified' -Observed $observations
    }

    # --- 5. Assertion-driven: authored, and never able to reach COMPLIANT ---------------
    $assertion = Get-MlsComplianceField -InputObject $Assessment -Name 'assertion'
    if ($null -ne $assertion) {
        # Only citations that are usable text count. An evidence array of nulls or blanks
        # cites nothing, and must not be mistaken for an assertion that carries evidence.
        $citationsRaw = Get-MlsComplianceField -InputObject $assertion -Name 'evidence'
        $citations = @()
        if ($null -ne $citationsRaw) {
            $citations = @(@($citationsRaw) | ForEach-Object { Get-MlsComplianceText $_ } |
                Where-Object { $null -ne $_ })
        }

        if ($citations.Count -gt 0) {
            $authored = Get-MlsComplianceText (Get-MlsComplianceField -InputObject $assertion -Name 'status')
            $display = if ($null -eq $authored) { '(none)' } else { $authored }
            $cited = "citing $($citations.Count) evidence reference(s)"

            if ($authored -eq 'CLOSED') {
                # CLOSED means "no known open finding", which is weaker than "the control
                # is met". PARTIAL is the strongest thing the platform can honestly say.
                return New-MlsComplianceResult -Status 'PARTIAL' -Provenance 'asserted' -Observed (
                    New-MlsComplianceObservation -Kind 'assertion' -Source 'assessment-register' -Detail (
                        "the register asserts CLOSED (no known open finding) $cited; " +
                        'nothing here was machine-verified'))
            }
            if ($authored -eq 'GAP') {
                return New-MlsComplianceResult -Status 'GAP' -Provenance 'asserted' -Observed (
                    New-MlsComplianceObservation -Kind 'assertion' -Source 'assessment-register' -Detail (
                        "the register asserts GAP (a known open finding stands) $cited"))
            }
            # A word outside the register's two-value vocabulary. Something was authored,
            # so this is not NOT_ASSESSED; the platform cannot read it, so it is not a
            # claim either.
            return New-MlsComplianceResult -Status 'INCONCLUSIVE' -Provenance 'asserted' -Observed (
                New-MlsComplianceObservation -Kind 'assertion' -Source 'assessment-register' -Detail (
                    "the register asserts an unrecognised status '$display' $cited; " +
                    'the platform cannot interpret it'))
        }
    }

    # --- 6. Nothing to go on -------------------------------------------------------------
    return New-MlsComplianceResult -Status 'NOT_ASSESSED' -Provenance 'none'
}

Export-ModuleMember -Function @(
    'Get-MlsControlStatus',
    'Get-MlsComplianceVocabulary'
)
