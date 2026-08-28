#Requires -Version 7.0
<#
.SYNOPSIS
    The verification-suite collector (spec section 4, plan Task 5): turns committed
    layer-audit reports under verification/reports/ into evidence records.

.DESCRIPTION
    This is the machine-verified path - the only collector whose evidence can drive a
    control's derived status all the way to COMPLIANT (compliance/lib/MlsCompliance.psm1).
    Every other collector (repo-static, github-security, azure-policy, manual) observes a
    control directly; this one alone reads what a Verifier audit already decided about a
    named criterion (verification/MlsAudit.psm1's Invoke-MlsCriterion / Write-MlsReport)
    and carries that decision, and the criterion id itself, into an EvidenceRecord.

    ONE RECORD PER (CRITERION, CONTROL) PAIR
    ------------------------------------------
    A criterion row can declare more than one Control (Invoke-MlsCriterion -Control is a
    string[]); this collector fans that out to one evidence record per control, each
    carrying the same criterion id, the same status and the same Observed text. A
    criterion whose Control array is empty (Task 2 left 17 of 47 criteria deliberately
    unmapped - cost checks, availability checks, a licensing precondition) emits nothing
    for that row; inventing evidence for an unmapped criterion would undo that decision.

    STATUS MAPPING - SKIP AND PENDING ARE OBSERVATIONS, NOT SILENCE
    -------------------------------------------------------------------
    PASS -> pass, FAIL -> fail, SKIP -> inconclusive, PENDING -> inconclusive. Never PASS
    for a SKIP or a PENDING - that is the one laundering this collector exists to prevent
    (a skipped audit is an unverified control, and rendering it green hides exactly that).

    This differs from an earlier reading of Task 4's contract docstring, which said a
    collector reading a SKIPPED or PENDING criterion "must not call [New-MlsEvidence] for
    it at all." That would be less honest, not more: under Get-MlsControlStatus, a
    criterion an assessment claims but that has NO matching evidence record renders
    INCONCLUSIVE with provenance 'none' ("we have no idea") - while an inconclusive record
    renders the same status with provenance 'machine-verified' and an Observed line saying
    exactly why the criterion did not resolve. Silence is strictly less informative than an
    honest inconclusive record, never more honest. CollectorContract.psm1's docstring has
    been corrected to say so; New-MlsEvidence itself already accepted 'inconclusive' - only
    the prose was wrong.

    READING COMMITTED REPORTS, NOT THE TENANT
    ---------------------------------------------
    This collector never calls Azure, Graph, Fabric or GitHub itself - it reads the JSON
    Write-MlsReport already committed to verification/reports/. It still runs inside
    Invoke-MlsCollector (Task 4) so the same structural read-only guard applies, and so a
    stray az/gh/git call added here later would fail the same way a real collector's would.

    ONE BAD REPORT MUST NOT LOSE THE OTHERS
    -------------------------------------------
    verification/reports/ can and normally does hold reports this collector cannot use: no
    .json reports at all (the tenant has never been audited - the normal state today, not
    an error), a file that is not valid JSON, or a JSON document with no `criteria` array
    (not a layer-audit report at all). Each report file is processed independently inside
    its own try/catch; a report that fails is skipped with a warning naming it and
    processing continues with the rest. A single malformed criterion row (an unrecognised
    Status word, a blank Observed, a missing Id) is likewise skipped on its own rather than
    discarding the rest of that report - there is nothing honest to say about a row with no
    usable text, so it contributes no record instead of a manufactured one.

.PARAMETER ReportRoot
    Directory to read *.json layer-audit reports from. Defaults to verification/reports/
    relative to this script's own location, so it works the same run from anywhere.
    Overridable for tests, which point it at compliance/tests/fixtures instead.

.OUTPUTS
    Zero or more validated EvidenceRecord objects (compliance/collectors/CollectorContract.psm1),
    each with `source` = 'verification-suite' and `criterion` set to the originating
    criterion id.
#>
[CmdletBinding()]
param(
    [string]$ReportRoot = ''
)

Set-StrictMode -Version Latest

$script:CollectorName = 'verification-suite'
$script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..')).Path

if ([string]::IsNullOrWhiteSpace($ReportRoot)) {
    $ReportRoot = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'verification', 'reports'
}
$script:ReportRoot = $ReportRoot

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'CollectorContract.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'verification', 'MlsAudit.psm1') -Force

function ConvertTo-MlsVerificationSuiteStatus {
    <#
    .SYNOPSIS
        Map a criterion row's Status to an EvidenceRecord status, or $null when the word
        is not one this collector recognises (a malformed or foreign row).
    .DESCRIPTION
        PASS -> pass, FAIL -> fail, SKIP/PENDING -> inconclusive. Deliberately never PASS
        for SKIP or PENDING - see the module header.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Status)
    switch ("$Status") {
        'PASS' { return 'pass' }
        'FAIL' { return 'fail' }
        'SKIP' { return 'inconclusive' }
        'PENDING' { return 'inconclusive' }
        default { return $null }
    }
}

function Get-MlsVerificationSuiteArtifact {
    <#
    .SYNOPSIS
        The report file's path relative to the repository root, POSIX-separated, for the
        EvidenceRecord's `artifact` field.
    #>
    param(
        [Parameter(Mandatory)][string]$FullName
    )
    $relative = [System.IO.Path]::GetRelativePath($script:RepoRoot, $FullName)
    return ($relative -replace '\\', '/')
}

# Everything below runs inside Task 4's Invoke-MlsCollector so the same read-only guard
# (bare az/gh/git shadowed onto the guarded transports) applies here too, even though this
# collector never intends to call any of them - a stray call added later fails the same way
# a real collector's would, rather than only being caught by review.
Invoke-MlsCollector -Name $script:CollectorName -ScriptBlock {

    if (-not (Test-Path -LiteralPath $script:ReportRoot)) {
        # Pre-G0, or a ReportRoot that simply does not exist yet: nothing to collect. This
        # is the normal state today (verification/reports/ carries no .json reports), not
        # an error - the collector says so via -Verbose rather than throwing.
        Write-Verbose "verification-suite: report root '$script:ReportRoot' does not exist; returning no evidence."
        return
    }

    $reportFile = @(Get-ChildItem -LiteralPath $script:ReportRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($reportFile.Count -eq 0) {
        Write-Verbose "verification-suite: no .json reports under '$script:ReportRoot'; returning no evidence."
        return
    }

    foreach ($file in $reportFile) {
        # Each report is processed atomically: if anything about it turns out to be
        # unusable partway through, the whole file's candidate records are discarded
        # together (not emitted piecemeal) and the run moves on to the next file.
        $emitted = [System.Collections.Generic.List[object]]::new()
        try {
            $reportText = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
            $report = ConvertFrom-Json -InputObject $reportText -ErrorAction Stop

            $criteriaRaw = Get-MlsProperty -InputObject $report -Name 'criteria'
            if ($null -eq $criteriaRaw) {
                throw "no 'criteria' array - not a recognised layer-audit report shape"
            }

            $artifact = Get-MlsVerificationSuiteArtifact -FullName $file.FullName

            foreach ($row in @($criteriaRaw)) {
                $mappedStatus = ConvertTo-MlsVerificationSuiteStatus -Status (Get-MlsProperty -InputObject $row -Name 'Status')
                if ($null -eq $mappedStatus) { continue }

                $controlListRaw = Get-MlsProperty -InputObject $row -Name 'Control'
                $controlList = @()
                if ($null -ne $controlListRaw) { $controlList = @($controlListRaw) }
                if ($controlList.Count -eq 0) { continue }

                $criterionId = "$(Get-MlsProperty -InputObject $row -Name 'Id')".Trim()
                if ([string]::IsNullOrWhiteSpace($criterionId)) { continue }

                $observedText = "$(Get-MlsProperty -InputObject $row -Name 'Observed')"
                if ([string]::IsNullOrWhiteSpace($observedText)) { continue }

                foreach ($controlId in $controlList) {
                    $controlText = "$controlId".Trim()
                    if ([string]::IsNullOrWhiteSpace($controlText)) { continue }
                    # Per-ROW try, inside the per-FILE one. New-MlsEvidence throws on a
                    # control id the catalog no longer carries, and that was the single
                    # failure mode able to escape the row-level `continue`s above - so
                    # one stale id discarded every record from that report, blanking a
                    # whole layer's machine-verified evidence. The docstring already
                    # promised row-level isolation; now the code does it.
                    try {
                        $emitted.Add((New-MlsEvidence -Control $controlText -Source $script:CollectorName `
                            -Status $mappedStatus -Observed $observedText -Criterion $criterionId `
                            -Artifact $artifact))
                    }
                    catch {
                        Write-Warning "verification-suite: skipping criterion '$criterionId' -> control '$controlText' in $($file.Name): $($_.Exception.Message)"
                    }
                }
            }

            $emitted
        }
        catch {
            Write-Warning "verification-suite: skipping report '$($file.Name)' - $($_.Exception.Message)"
        }
    }
}
