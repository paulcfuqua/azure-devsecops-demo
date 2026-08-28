#Requires -Version 7.0
<#
.SYNOPSIS
    The manual collector (spec section 4, plan Task 7): turns an authored assertion in
    compliance/assessment/*.json (the remediation register, Task 8 of the prior
    security-remediation plan) into an evidence record, unmistakably asserted-tier.

.DESCRIPTION
    Every other collector observes something outside a human's say-so: a file in the
    working tree, a live GHAS setting, a live Azure Policy compliance state. This one is
    different on purpose - it is the one place an author's own claim ("F2 and F3 are now
    CLOSED, see these commits") becomes an EvidenceRecord at all, so a board can show that
    claim next to what was actually collected rather than only next to a bare register
    file no other part of the platform reads.

    ONLY ASSESSMENTS THAT CARRY AN ASSERTION EMIT ANYTHING
    -------------------------------------------------------------
    An assessment file with `criteria: [...]` but no `assertion` block - the criteria-
    driven shape spec section 3.2 also allows, even though nothing in this register uses
    it today - has nothing authored to transcribe. It emits nothing, silently: that is not
    a malformed record, it is the ordinary "this control is machine-verified only" shape.

    NEVER A CRITERION - and the contract now enforces that, rather than trusting this collector to abstain: Get-MlsEvidenceProblem rejects a criterion on any source but verification-suite
    ---------------------------------------------------------
    This record is control-scoped like repo-static, github-security and azure-policy: it
    never sets -Criterion. That is not merely stylistic here - Get-MlsControlStatus
    (compliance/lib/MlsCompliance.psm1) reaches COMPLIANT only through evidence that
    matches a declared criterion by that field, and a manual record naming one would be a
    false join key letting an author's own assertion masquerade as a machine-verified
    pass. Task 3 already guarantees COMPLIANT is unreachable from an assessment with no
    criteria; this collector's job is to not undermine that guarantee by inventing a
    criterion of its own.

    STATUS MAPPING IS A TRANSCRIPTION, NOT A VERIFICATION
    -------------------------------------------------------------
    The register vocabulary (compliance/README.md) is GAP / CLOSED, not the contract's
    pass / fail / inconclusive - CLOSED maps to `pass`, GAP to `fail`, and anything else to
    `inconclusive` (fail-closed, matching Get-MlsControlStatus's own handling of an
    unrecognised assertion status). This is a literal transcription of what the author
    wrote, carried at `source: 'manual'` so a reader can tell it apart from a collected
    fact - it is not this collector re-deciding whether the control is actually met.
    CLOSED itself is deliberately weaker than "the control is met" (compliance/README.md);
    nothing here launders that distinction, because - see above - a control-scoped record
    with no criterion can never drive a control to COMPLIANT no matter what its status is.

    ONE BAD FILE MUST NOT LOSE THE OTHERS
    -------------------------------------------
    Each assessment file is processed in its own try/catch, exactly like verification-
    suite's per-report handling: invalid JSON, a blank or dangling `control` id (the real
    register keys four files - CM-6, SI-4, IR-4, CP-9 - on 800-53 ids the 800-171 catalog
    has no requirement for; New-MlsEvidence throws naming the id, and this collector logs
    a warning and moves on rather than losing every other file's evidence over it), or any
    other unusable shape is warned about and skipped, and the rest of the register is
    still collected.

.PARAMETER AssessmentRoot
    Directory to read *.json assessment records from. Defaults to compliance/assessment/
    relative to this script's own location - the real remediation register - so it works
    the same run from anywhere. Overridable for tests, which point it at
    compliance/tests/fixtures/manual-assessment instead.

.OUTPUTS
    Zero or more validated EvidenceRecord objects (compliance/collectors/
    CollectorContract.psm1), each with `source` = 'manual' and `criterion` = $null.
#>
[CmdletBinding()]
param(
    [string]$AssessmentRoot = ''
)

Set-StrictMode -Version Latest

$script:CollectorName = 'manual'
$script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..')).Path

if ([string]::IsNullOrWhiteSpace($AssessmentRoot)) {
    $AssessmentRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'assessment'
}
$script:AssessmentRoot = $AssessmentRoot

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'CollectorContract.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'verification', 'MlsAudit.psm1') -Force

function ConvertTo-MlsManualStatus {
    <#
    .SYNOPSIS
        Register vocabulary (GAP/CLOSED) -> contract vocabulary (pass/fail/inconclusive).
        CLOSED -> pass, GAP -> fail, anything else -> inconclusive (fail-closed, matching
        Get-MlsControlStatus's own handling of an unrecognised assertion status).
    #>
    param([AllowNull()][AllowEmptyString()][string]$Status)
    switch ("$Status") {
        'CLOSED' { return 'pass' }
        'GAP' { return 'fail' }
        default { return 'inconclusive' }
    }
}

function Get-MlsManualArtifact {
    <#
    .SYNOPSIS
        The assessment file's path relative to the repository root, POSIX-separated, for
        the EvidenceRecord's `artifact` field - mirrors verification-suite's
        Get-MlsVerificationSuiteArtifact.
    #>
    param([Parameter(Mandatory)][string]$FullName)
    $relative = [System.IO.Path]::GetRelativePath($script:RepoRoot, $FullName)
    return ($relative -replace '\\', '/')
}

Invoke-MlsCollector -Name $script:CollectorName -ScriptBlock {

    if (-not (Test-Path -LiteralPath $script:AssessmentRoot)) {
        Write-Verbose "manual: assessment root '$script:AssessmentRoot' does not exist; returning no evidence."
        return
    }

    $assessmentFile = @(Get-ChildItem -LiteralPath $script:AssessmentRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($assessmentFile.Count -eq 0) {
        Write-Verbose "manual: no .json assessment files under '$script:AssessmentRoot'; returning no evidence."
        return
    }

    foreach ($file in $assessmentFile) {
        try {
            $recordText = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
            $record = ConvertFrom-Json -InputObject $recordText -ErrorAction Stop

            $assertion = Get-MlsProperty -InputObject $record -Name 'assertion'
            if ($null -eq $assertion) {
                # Criteria-driven or simply un-asserted yet - the ordinary shape for a
                # control this collector has nothing authored to say about. Not an error.
                continue
            }

            $control = "$(Get-MlsProperty -InputObject $record -Name 'control')".Trim()
            if ([string]::IsNullOrWhiteSpace($control)) {
                throw "assertion present but 'control' is missing or blank"
            }

            $registerStatus = "$(Get-MlsProperty -InputObject $assertion -Name 'status')".Trim()
            $mappedStatus = ConvertTo-MlsManualStatus -Status $registerStatus

            $evidenceRef = @(Get-MlsProperty -InputObject $assertion -Name 'evidence')
            $assertedBy = "$(Get-MlsProperty -InputObject $assertion -Name 'assertedBy')".Trim()
            $assertedAt = "$(Get-MlsProperty -InputObject $assertion -Name 'assertedAt')".Trim()

            $registerStatusText = if ([string]::IsNullOrWhiteSpace($registerStatus)) { '(no status)' } else { $registerStatus }
            $assertedByText = if ([string]::IsNullOrWhiteSpace($assertedBy)) { 'an unnamed author' } else { $assertedBy }
            $assertedAtText = if ([string]::IsNullOrWhiteSpace($assertedAt)) { 'an unrecorded date' } else { $assertedAt }

            $observed = "Register asserts $registerStatusText for $control, asserted by $assertedByText on " +
                "$assertedAtText, citing $($evidenceRef.Count) evidence reference(s). This is an authored " +
                "assertion, not a machine-verified observation."

            New-MlsEvidence -Control $control -Source $script:CollectorName -Status $mappedStatus `
                -Observed $observed -Artifact (Get-MlsManualArtifact -FullName $file.FullName)
        }
        catch {
            Write-Warning "manual: skipping assessment file '$($file.Name)' - $($_.Exception.Message)"
        }
    }
}
