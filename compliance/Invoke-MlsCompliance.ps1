#Requires -Version 7.0
<#
.SYNOPSIS
    The state emitter (spec section 3.3, plan Task 8): joins the catalog, the assessment
    register and every collector's evidence into the one artifact the board renders and
    the `query_compliance` MCP tool answers from.

.DESCRIPTION
    Read-only and offline-capable by construction. It reads files, runs the five
    collectors (each of which is itself structurally incapable of mutation - see
    collectors/CollectorContract.psm1), calls the pure `Get-MlsControlStatus` once per
    requirement, and writes two files. It never authenticates, never deploys and never
    writes anything outside -OutputRoot.

    NOTHING HAS EVER BEEN DEPLOYED, AND THAT IS THE NORMAL CASE
    ----------------------------------------------------------
    There is no tenant. `verification-suite` finds no committed reports, `github-security`
    and `azure-policy` are handed no response, and only `repo-static` and `manual` produce
    anything. That must yield a COMPLETE, honest artifact - all 110 requirements present,
    every one of them NOT_ASSESSED where nothing was said - not an error and not a short
    file. A collector that collected nothing is recorded as having collected nothing
    (`collectors[].recordCount = 0`), which is a different and more useful statement than
    its absence.

    THE THREE THINGS THIS FILE DECIDES, AND WHY
    ===========================================

    1. THE FOUR 800-53-KEYED REGISTER RECORDS GET THEIR OWN ROWS
    ------------------------------------------------------------
    `compliance/assessment/` holds four records - CM-6, CP-9, IR-4, SI-4 - keyed on NIST
    SP 800-53 Rev 5 control ids for which the 110-requirement 800-171 catalog has no
    requirement at all. Iterating the catalog alone would drop all four silently, because
    Task 3's derivation deliberately fails closed on a control/requirement mismatch. So
    this runner iterates the REGISTER as well as the catalog, and renders each such record
    as its own row in `outOfCatalogControls`, keyed on its own 800-53 id, labelled
    `framework: 'nist-800-53r5'` and `inCatalog: false`, and counted separately in
    `summary.outOfCatalog` so the 110-requirement totals stay arithmetic.

    They are deliberately NOT resolved through the catalog's `mappings.nist-800-53r5` into
    800-171 rows. CP-9 maps to 3.8.9; rendering CP-9's authored CLOSED against 3.8.9 would
    put a claim on the board that CP-9's author never made, about a requirement they never
    wrote about. That wrong-box join is precisely what Task 3's control-id guard exists to
    catch, and reintroducing it here would defeat the guard from the other side. Each row
    does carry `requirementsMappingToThisControl` - the requirements whose catalog mappings
    happen to cite the control - but for orientation only: the row's `note` says in words
    that the assertion is not applied to them, and their own rows are unaffected.

    2. CONTROL-SCOPED EVIDENCE IS SURFACED, VISIBLY SEPARATED FROM WHAT DROVE THE STATUS
    ------------------------------------------------------------------------------------
    Every record in the register declares `criteria: []` today, so every one takes the
    asserted path - which ignores collected evidence entirely. `repo-static`,
    `github-security`, `azure-policy` and `manual` evidence therefore contributes nothing
    to any derived status. Dropping it would make the collection layer pointless and would
    be its own dishonesty: evidence collected and then hidden. Attaching it so that it
    reads as if it had moved the status would be worse.

    So each control row carries three fields with three different meanings:

      statusBasis        - the rows Get-MlsControlStatus's own `Observed` returned. This
                           IS the decision's working: nothing outside it moved the status.
      evidence           - the collected records that participated, i.e. those matching a
                           criterion the assessment claims. `participatedInStatus: true`.
      supportingEvidence - everything else collected for this control. Real, collected,
                           renderable context that did NOT move the status.
                           `participatedInStatus: false`.

    The partition mirrors the derivation exactly (`Get-MlsComplianceClaimedCriterion`
    below reproduces its three conditions and nothing else), and
    compliance/tests/state-emitter.Tests.ps1 asserts on every run that the two agree - so
    the mirror cannot drift without a test going red. `notes.supportingEvidence` states
    the distinction in the artifact itself, for a reader who has only the JSON.

    3. A SKIPPED CRITERION IS MACHINE-VERIFIED, AND MUST NOT READ AS PASSING
    ------------------------------------------------------------------------
    A SKIP becomes an `inconclusive` evidence record, which derives INCONCLUSIVE with
    provenance `machine-verified` - a machine reached the question and explicitly declined
    to answer it. That ruling stands and is not reversed here. But it means a wholly
    skipped control lands in `byProvenance['machine-verified']`, and a reader who saw only
    that total could mistake it for verified-and-passing.

    The fix is in the counting, not in the derivation: `summary.byProvenanceAndStatus`
    cross-tabulates the two, so `machine-verified` is never presented as a single figure
    without its status breakdown beside it, and `summary.notes` says in words what the
    word does and does not mean. COMPLIANT is the only status that means verified and
    passing, and it is reachable from the criteria branch alone.

    NO SCORE
    --------
    Counts by status, counts by provenance, and the cross-tabulation of the two. There is
    deliberately no percentage, ratio or score of any kind anywhere in this artifact
    (spec section 3.4): a figure that blends machine-verified and asserted controls is
    exactly the number an adopter would quote to an auditor, and exactly the number that
    would be wrong. state-emitter.Tests.ps1 walks the whole emitted object graph and fails
    on any property named like one.

    WHAT THE ARTIFACT DELIBERATELY DOES NOT CARRY
    ---------------------------------------------
    The register's `assertion.rationale` - often several thousand words per record - is
    not copied into state. Each row names its source file in `assessment.path` instead, so
    a board can link to it in git, where it is reviewable with its history. Copying it
    would multiply the size of every nightly artifact for text that never changes between
    runs.

    COLLECTOR LIMITATIONS TRAVEL WITH THE EVIDENCE
    ----------------------------------------------
    `collectors[].limitation` states, in the artifact, what each collector's evidence
    cannot support. This matters most for `azure-policy`: the built-in "NIST SP 800-53
    Rev. 5" initiative is a REGULATORY COMPLIANCE initiative composed almost entirely of
    `audit` / `auditIfNotExists` policies, so an assignment-level `enforcementMode:
    Default` is not evidence that anything is enforced, and the field that would settle it
    (`policyDefinitionAction`) is absent from the response shape this platform consumes.
    A reader of the JSON alone must be able to see that; a board that presented those rows
    as enforcement would be overclaiming.

.PARAMETER CatalogPath
    The requirement catalog (Task 1). Defaults to compliance/catalog/nist-800-171r2.json.
.PARAMETER AssessmentRoot
    Directory of `<control-id>.json` register records. Defaults to compliance/assessment/.
.PARAMETER OutputRoot
    Where `state-<ISO-date>.json` and `state-latest.json` are written. Defaults to
    compliance/state/, and is created if absent.
.PARAMETER RepoRoot
    Working tree the `repo-static` collector inspects. Defaults to this repository.
.PARAMETER VerificationReportRoot
    Directory of committed Verifier reports for `verification-suite`. Defaults to
    verification/reports/ - which does not exist yet, and that is fine.
.PARAMETER GitHubSecurityResponsePath
    JSON file holding a `GET /repos/{owner}/{repo}` response for `github-security`.
    Omitted in every current run: there is no collection identity yet.
.PARAMETER AzurePolicyResponsePath
    JSON file holding a policy-state response for `azure-policy`. Omitted in every current
    run: there is no tenant.
.PARAMETER Commit
    The commit to stamp. Defaults to this repository's HEAD, read through MlsAudit's
    read-only git transport. CI passes the sha it actually checked out.
.PARAMETER PassThru
    Also return the artifact as an object, for tests and for callers that want it without
    re-reading the file.

.OUTPUTS
    Nothing, or the state artifact as a [pscustomobject] with -PassThru. Always writes
    both files.

.EXAMPLE
    pwsh compliance/Invoke-MlsCompliance.ps1
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string]$CatalogPath = '',
    [string]$AssessmentRoot = '',
    [string]$OutputRoot = '',
    [string]$RepoRoot = '',
    [string]$VerificationReportRoot = '',
    [string]$GitHubSecurityResponsePath = '',
    [string]$AzurePolicyResponsePath = '',
    [string]$Commit = '',
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PlatformRoot = $PSScriptRoot
$script:GitRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'lib' -AdditionalChildPath 'MlsCompliance.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'verification', 'MlsAudit.psm1') -Force

if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
    $CatalogPath = Join-Path -Path $PSScriptRoot -ChildPath 'catalog' -AdditionalChildPath 'nist-800-171r2.json'
}
if ([string]::IsNullOrWhiteSpace($AssessmentRoot)) {
    $AssessmentRoot = Join-Path -Path $PSScriptRoot -ChildPath 'assessment'
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path -Path $PSScriptRoot -ChildPath 'state'
}

# --- the sentences the artifact carries about itself -------------------------------------
# Held as constants so the artifact, this file's header and the tests all quote one text.

$script:SupportingEvidenceNote = @(
    'supportingEvidence holds evidence that was collected for the control and did NOT'
    'drive its status. What drove the status is statusBasis, which is the working the'
    'derivation itself returned; evidence[] is the subset of collected records that'
    'participated in it. Every record in the register declares an empty criteria list'
    'today, so every control takes the authored path and no collected evidence'
    'participates anywhere - it is rendered as context, and only as context.'
) -join ' '

$script:OutOfCatalogNote = @(
    'outOfCatalogControls holds assessment records keyed on control ids the NIST SP'
    '800-171 Rev 2 catalog has no requirement for. They are rendered on their own rows,'
    'against the framework they were actually assessed under, and counted separately from'
    'the 110. They are deliberately not resolved through the catalog framework mappings'
    'onto 800-171 rows: that would attribute a claim to a requirement its author never'
    'wrote about.'
) -join ' '

$script:CountsOnlyNote = @(
    'Counts only. There is deliberately no percentage, ratio or score anywhere in this'
    'artifact: a figure that blends machine-verified and asserted controls is the number'
    'an adopter would quote to an auditor and the number that would be wrong.'
) -join ' '

$script:ProvenanceNote = @(
    'machine-verified means a machine reached the question - including a criterion it'
    'explicitly declined to run, which is collected as an inconclusive record and renders'
    'INCONCLUSIVE / machine-verified. It does not mean passing. COMPLIANT is the only'
    'status that means verified and passing, and it is reachable from the criteria branch'
    'alone; read byProvenanceAndStatus, never byProvenance on its own.'
) -join ' '

$script:AssertedNote = @(
    'asserted means a human wrote it down and the platform checked nothing. declared means'
    'a human declared the requirement not applicable and justified it. none means nothing'
    'was asserted and nothing was collected.'
) -join ' '

# --- helpers -------------------------------------------------------------------------------

function Get-MlsComplianceRelativePath {
    <#
    .SYNOPSIS
        A repository-relative, POSIX-separated path for an artifact reference, falling back
        to the bare file name when the target lies outside the repository (a TestDrive
        fixture root, for instance) so the artifact never carries a machine-local absolute
        path.
    #>
    param([Parameter(Mandatory)][string]$FullPath)

    $relative = [System.IO.Path]::GetRelativePath($script:GitRoot, $FullPath) -replace '\\', '/'
    if ($relative.StartsWith('../') -or [System.IO.Path]::IsPathRooted($relative)) {
        return (Split-Path -Path $FullPath -Leaf)
    }
    return $relative
}

function Get-MlsComplianceTrimmed {
    <#
    .SYNOPSIS
        Trimmed string form of a value, or $null when it is not usable text - the same
        gate MlsCompliance.psm1 and CollectorContract.psm1 each apply to their own inputs.
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -isnot [string]) { return $null }
    $trimmed = $Value.Trim()
    if ($trimmed.Length -eq 0) { return $null }
    return $trimmed
}

function Get-MlsComplianceClaimedCriterion {
    <#
    .SYNOPSIS
        The criterion ids an assessment claims, or an empty list when it claims none.
    .DESCRIPTION
        This MIRRORS the three conditions Get-MlsControlStatus's criteria branch requires -
        an assessment exists, its applicability is exactly 'applicable', and its criteria
        list holds usable ids - and nothing else. It exists so a control row can say which
        collected records participated in its status without re-deciding anything, and
        state-emitter.Tests.ps1 asserts on every emitted row that this partition and the
        derivation's own Observed rows agree, so the mirror cannot drift silently.
    #>
    param($Assessment)

    # Every return is comma-wrapped: PowerShell unrolls an empty array on output, which
    # would hand the caller $null where it asked for a list.
    if ($null -eq $Assessment) { return , @() }
    $applicability = Get-MlsComplianceTrimmed (Get-MlsProperty -InputObject $Assessment -Name 'applicability')
    if ($applicability -ne 'applicable') { return , @() }

    $criteria = Get-MlsProperty -InputObject $Assessment -Name 'criteria'
    if ($null -eq $criteria) { return , @() }
    return , @(@($criteria) | ForEach-Object { Get-MlsComplianceTrimmed $_ } | Where-Object { $null -ne $_ })
}

function ConvertTo-MlsComplianceEvidenceRow {
    <#
    .SYNOPSIS
        One collected EvidenceRecord, projected for the artifact and stamped with whether
        it participated in the control's status.
    #>
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][bool]$Participated
    )

    [pscustomobject][ordered]@{
        source               = Get-MlsComplianceTrimmed (Get-MlsProperty -InputObject $Record -Name 'source')
        criterion            = Get-MlsComplianceTrimmed (Get-MlsProperty -InputObject $Record -Name 'criterion')
        status               = Get-MlsComplianceTrimmed (Get-MlsProperty -InputObject $Record -Name 'status')
        observed             = Get-MlsComplianceTrimmed (Get-MlsProperty -InputObject $Record -Name 'observed')
        artifact             = Get-MlsComplianceTrimmed (Get-MlsProperty -InputObject $Record -Name 'artifact')
        collectedAt          = Get-MlsComplianceTrimmed (Get-MlsProperty -InputObject $Record -Name 'collectedAt')
        participatedInStatus = $Participated
    }
}

function ConvertTo-MlsComplianceBasisRow {
    <#
    .SYNOPSIS
        One row of Get-MlsControlStatus's `Observed` - the working the decision rested on -
        projected into the artifact's lower-camel shape.
    #>
    param([Parameter(Mandatory)]$Observation)

    [pscustomobject][ordered]@{
        kind        = $Observation.Kind
        criterion   = $Observation.Criterion
        outcome     = $Observation.Outcome
        detail      = $Observation.Detail
        source      = $Observation.Source
        artifact    = $Observation.Artifact
        collectedAt = $Observation.CollectedAt
    }
}

function Format-MlsComplianceObserved {
    <#
    .SYNOPSIS
        The derivation's `Observed` rows rendered down to spec section 3.3's single
        `observed` string - the emitter's join, deliberately not the pure function's job.
    .DESCRIPTION
        Never empty. A control nothing was said about gets a sentence saying so, because a
        blank cell on a board is indistinguishable from a bug - and where evidence WAS
        collected but drove nothing, the sentence says that instead, rather than the flatly
        untrue "nothing was collected for it".
    #>
    param($Observation, [int]$SupportingCount = 0)

    $rows = @($Observation)
    if ($rows.Count -eq 0) {
        if ($SupportingCount -gt 0) {
            return "Nothing that could drive a status was asserted about this control. " +
            "$SupportingCount evidence record(s) were collected for it and are carried in " +
            'supportingEvidence as context only.'
        }
        return 'Nothing has been asserted about this control and nothing was collected for it.'
    }

    $part = foreach ($row in $rows) {
        $detail = Get-MlsComplianceTrimmed $row.Detail
        if ($row.Kind -eq 'criterion') {
            $criterion = if ($row.Criterion) { $row.Criterion } else { '(unnamed criterion)' }
            $text = if ($detail) { $detail } else { 'no detail was recorded' }
            "$criterion ($($row.Outcome)): $text"
        }
        elseif ($detail) { $detail }
        else { "$($row.Kind): no detail was recorded" }
    }
    return (@($part) -join ' | ')
}

function Get-MlsComplianceCount {
    <#
    .SYNOPSIS
        Counts of $Value over the fixed key list $Key, so a status or provenance that
        occurred zero times still renders as a zero rather than vanishing.
    .DESCRIPTION
        $Key always comes from Get-MlsComplianceVocabulary, never from a second copy of
        the enum written out here - which is what keeps the board's key list and the
        derivation's own vocabulary provably the same list.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Key,
        [AllowEmptyCollection()][string[]]$Value = @()
    )

    # The loop variables are deliberately not $key / $value: PowerShell variable names are
    # case-insensitive, so those would BE the parameters $Key and $Value and the first
    # iteration would overwrite the very list being iterated.
    $count = [ordered]@{}
    foreach ($vocabularyEntry in $Key) { $count[$vocabularyEntry] = 0 }
    foreach ($observed in $Value) {
        if ($count.Contains($observed)) { $count[$observed]++ }
    }
    return [pscustomobject]$count
}

function ConvertTo-MlsComplianceAssessmentRow {
    <#
    .SYNOPSIS
        The authored side of a control row: where the record lives and what its author
        wrote, with the register's own vocabulary named as such.
    .DESCRIPTION
        `registerStatus` is the author's word (GAP / CLOSED), carried verbatim and labelled
        so it can never be confused with the derived `status` beside it. The lengthy
        `assertion.rationale` is not copied - see the file header.
    #>
    param(
        [Parameter(Mandatory)]$Assessment,
        # AllowEmptyString, not ValidateNotNullOrEmpty: a register record read from a root
        # outside the repository has no repo-relative path to name, and losing the whole
        # row to a parameter-binding error over a cosmetic field would be the wrong trade.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )

    $assertion = Get-MlsProperty -InputObject $Assessment -Name 'assertion'
    [pscustomobject][ordered]@{
        path           = $Path
        applicability  = Get-MlsComplianceTrimmed (Get-MlsProperty -InputObject $Assessment -Name 'applicability')
        registerStatus = Get-MlsComplianceTrimmed (Get-MlsProperty -InputObject $assertion -Name 'status')
        assertedBy     = Get-MlsComplianceTrimmed (Get-MlsProperty -InputObject $assertion -Name 'assertedBy')
        assertedAt     = Get-MlsComplianceTrimmed (Get-MlsProperty -InputObject $assertion -Name 'assertedAt')
        gapSeverity    = Get-MlsComplianceTrimmed (Get-MlsProperty -InputObject $Assessment -Name 'gapSeverity')
        recommendation = Get-MlsComplianceTrimmed (Get-MlsProperty -InputObject $Assessment -Name 'recommendation')
        references     = @(@(Get-MlsProperty -InputObject $Assessment -Name 'references') |
                ForEach-Object { Get-MlsComplianceTrimmed $_ } | Where-Object { $null -ne $_ })
    }
}

# --- 1. catalog ----------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $CatalogPath)) {
    throw "Invoke-MlsCompliance: catalog '$CatalogPath' does not exist. The catalog is reference data, not a collected source; its absence is a broken checkout, not an empty result."
}
$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
$requirement = @($catalog.requirements)
if ($requirement.Count -eq 0) {
    throw "Invoke-MlsCompliance: catalog '$CatalogPath' declares no requirements."
}

$requirementById = [ordered]@{}
foreach ($item in $requirement) { $requirementById[$item.id] = $item }

# 800-53 control id -> the 800-171 requirements whose mappings cite it. Built for
# orientation on out-of-catalog rows ONLY; it is never used to resolve an assessment.
$requirementByControlMapping = @{}
foreach ($item in $requirement) {
    foreach ($controlId in @(Get-MlsProperty -InputObject $item.mappings -Name 'nist-800-53r5')) {
        $key = Get-MlsComplianceTrimmed $controlId
        if ($null -eq $key) { continue }
        if (-not $requirementByControlMapping.ContainsKey($key)) {
            $requirementByControlMapping[$key] = [System.Collections.Generic.List[string]]::new()
        }
        $requirementByControlMapping[$key].Add($item.id)
    }
}

# --- 2. the register -----------------------------------------------------------------------

$assessmentByControl = [ordered]@{}
$assessmentPathByControl = @{}
$assessmentProblem = [System.Collections.Generic.List[object]]::new()

if (Test-Path -LiteralPath $AssessmentRoot) {
    $assessmentFile = @(Get-ChildItem -LiteralPath $AssessmentRoot -Filter '*.json' -File -ErrorAction SilentlyContinue) |
        Sort-Object -Property Name
    foreach ($file in $assessmentFile) {
        try {
            $record = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $controlId = Get-MlsComplianceTrimmed (Get-MlsProperty -InputObject $record -Name 'control')
            if ($null -eq $controlId) { throw "'control' is missing or blank" }
            if ($assessmentByControl.Contains($controlId)) {
                throw "control '$controlId' is already assessed by '$($assessmentPathByControl[$controlId])'"
            }
            $assessmentByControl[$controlId] = $record
            $assessmentPathByControl[$controlId] = Get-MlsComplianceRelativePath -FullPath $file.FullName
        }
        catch {
            # A register file that cannot be read is recorded, never dropped: a control
            # that silently left the board is the failure mode this platform exists to
            # prevent, and it is worse when the reason is a typo nobody was told about.
            $assessmentProblem.Add([pscustomobject][ordered]@{
                    file    = $file.Name
                    problem = $_.Exception.Message
                })
            Write-Warning "Invoke-MlsCompliance: skipping assessment file '$($file.Name)' - $($_.Exception.Message)"
        }
    }
}
else {
    $assessmentProblem.Add([pscustomobject][ordered]@{
            file    = (Get-MlsComplianceRelativePath -FullPath $AssessmentRoot)
            problem = 'the assessment root does not exist; every requirement renders NOT_ASSESSED'
        })
}

# --- 3. collectors -------------------------------------------------------------------------
# Each runs in its own try/catch. A collector that throws is recorded as failed WITH its
# error and the run continues: a partial artifact that says which source failed is more
# useful, and more honest, than no artifact at all.

$collectorRoot = Join-Path -Path $script:PlatformRoot -ChildPath 'collectors'

$collectorArgument = [ordered]@{}
$collectorArgument['verification-suite'] = @{}
if (-not [string]::IsNullOrWhiteSpace($VerificationReportRoot)) {
    $collectorArgument['verification-suite']['ReportRoot'] = $VerificationReportRoot
}
$collectorArgument['repo-static'] = @{}
if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
    $collectorArgument['repo-static']['RepoRoot'] = $RepoRoot
}
$collectorArgument['github-security'] = @{}
$collectorArgument['azure-policy'] = @{}
$collectorArgument['manual'] = @{ AssessmentRoot = $AssessmentRoot }

$collectorLimitation = @{
    'verification-suite' = 'Reads committed Verifier audit reports. It reports what an audit run observed at the time that report was written, not the state of the estate now. Nothing in this estate has been deployed, so there are no reports to read.'
    'repo-static'        = 'Reads the working tree. Every record describes what the repository declares, not what is deployed - nothing in this estate has been deployed, so it is not evidence that anything runs.'
    'github-security'    = 'Reads a GET /repos/{owner}/{repo} response. It observes which GitHub Advanced Security features are switched on, never whether any finding they produced was acted on.'
    'azure-policy'       = 'Reads Azure Policy compliance state. The built-in "NIST SP 800-53 Rev. 5" initiative is a Regulatory Compliance initiative composed almost entirely of audit and auditIfNotExists policies, so an assignment-level enforcementMode of Default is NOT evidence that anything is enforced; the field that would settle it, policyDefinitionAction, is absent from the response shape this platform consumes. Treat every record from this collector as an audit observation, never as enforcement.'
    'manual'             = 'Transcribes an authored assertion from the register into an evidence record. It is a human claim carried forward verbatim, not an observation, and it can never drive a control to COMPLIANT.'
}

$collectorResult = [System.Collections.Generic.List[object]]::new()
$evidence = [System.Collections.Generic.List[object]]::new()

foreach ($name in @($collectorArgument.Keys)) {
    $status = 'ok'
    $errorText = $null
    $count = 0
    try {
        $splat = $collectorArgument[$name]
        if ($name -eq 'github-security' -and -not [string]::IsNullOrWhiteSpace($GitHubSecurityResponsePath)) {
            $splat = @{ Response = (Get-Content -LiteralPath $GitHubSecurityResponsePath -Raw -ErrorAction Stop | ConvertFrom-Json) }
        }
        if ($name -eq 'azure-policy' -and -not [string]::IsNullOrWhiteSpace($AzurePolicyResponsePath)) {
            $splat = @{ Response = (Get-Content -LiteralPath $AzurePolicyResponsePath -Raw -ErrorAction Stop | ConvertFrom-Json) }
        }
        $collected = @(& (Join-Path -Path $collectorRoot -ChildPath "$name.ps1") @splat)
        foreach ($record in $collected) { $evidence.Add($record) }
        $count = $collected.Count
    }
    catch {
        $status = 'failed'
        $errorText = $_.Exception.Message
        Write-Warning "Invoke-MlsCompliance: collector '$name' failed - $errorText"
    }
    $collectorResult.Add([pscustomobject][ordered]@{
            name        = $name
            status      = $status
            recordCount = $count
            limitation  = $collectorLimitation[$name]
            error       = $errorText
        })
}

$evidenceByControl = @{}
foreach ($record in $evidence) {
    $key = Get-MlsComplianceTrimmed (Get-MlsProperty -InputObject $record -Name 'control')
    if ($null -eq $key) { continue }
    if (-not $evidenceByControl.ContainsKey($key)) {
        $evidenceByControl[$key] = [System.Collections.Generic.List[object]]::new()
    }
    $evidenceByControl[$key].Add($record)
}

# --- 4. derive ------------------------------------------------------------------------------

function Get-MlsComplianceControlRow {
    <#
    .SYNOPSIS
        One control row: the derivation's verdict, its working, and the evidence collected
        for the control split by whether it participated in that verdict.
    #>
    param(
        [Parameter(Mandatory)][string]$ControlId,
        [Parameter(Mandatory)][AllowNull()]$Requirement,
        [AllowNull()]$Assessment = $null,
        [AllowNull()][string]$AssessmentPath = $null,
        [AllowEmptyCollection()][object[]]$Evidence = @()
    )

    $result = Get-MlsControlStatus -Requirement $Requirement -Assessment $Assessment -Evidence $Evidence

    $claimed = Get-MlsComplianceClaimedCriterion -Assessment $Assessment
    $participating = [System.Collections.Generic.List[object]]::new()
    $supporting = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $Evidence) {
        $criterion = Get-MlsComplianceTrimmed (Get-MlsProperty -InputObject $record -Name 'criterion')
        if ($null -ne $criterion -and $claimed -contains $criterion) {
            $participating.Add((ConvertTo-MlsComplianceEvidenceRow -Record $record -Participated $true))
        }
        else {
            $supporting.Add((ConvertTo-MlsComplianceEvidenceRow -Record $record -Participated $false))
        }
    }

    $row = [ordered]@{
        control    = $ControlId
        framework  = 'nist-800-171r2'
        inCatalog  = $true
        family     = $null
        familyName = $null
        title      = $null
        mappings   = $null
    }
    if ($null -ne $Requirement) {
        $row['family'] = Get-MlsProperty -InputObject $Requirement -Name 'family'
        $row['familyName'] = Get-MlsProperty -InputObject $Requirement -Name 'familyName'
        $row['title'] = Get-MlsProperty -InputObject $Requirement -Name 'title'
        $row['mappings'] = Get-MlsProperty -InputObject $Requirement -Name 'mappings'
    }

    $row['status'] = $result.Status
    $row['provenance'] = $result.Provenance
    $row['observed'] = Format-MlsComplianceObserved -Observation $result.Observed -SupportingCount $supporting.Count
    $row['statusBasis'] = @(@($result.Observed) | ForEach-Object { ConvertTo-MlsComplianceBasisRow -Observation $_ })
    $row['evidence'] = @($participating)
    $row['supportingEvidence'] = @($supporting)
    $row['assessment'] = if ($null -eq $Assessment) { $null }
    else { ConvertTo-MlsComplianceAssessmentRow -Assessment $Assessment -Path $AssessmentPath }

    return [pscustomobject]$row
}

$control = [System.Collections.Generic.List[object]]::new()
foreach ($item in $requirement) {
    $id = $item.id
    $assessment = if ($assessmentByControl.Contains($id)) { $assessmentByControl[$id] } else { $null }
    $path = if ($assessmentPathByControl.ContainsKey($id)) { $assessmentPathByControl[$id] } else { $null }
    $forControl = @()
    if ($evidenceByControl.ContainsKey($id)) { $forControl = @($evidenceByControl[$id]) }
    $control.Add((Get-MlsComplianceControlRow -ControlId $id -Requirement $item -Assessment $assessment `
                -AssessmentPath $path -Evidence $forControl))
}

# The register, not the catalog. Anything the register assessed that the catalog has no
# requirement for gets its own row rather than disappearing on Task 3's mismatch guard.
$outOfCatalog = [System.Collections.Generic.List[object]]::new()
foreach ($id in @($assessmentByControl.Keys)) {
    if ($requirementById.Contains($id)) { continue }

    $forControl = @()
    if ($evidenceByControl.ContainsKey($id)) { $forControl = @($evidenceByControl[$id]) }
    # -Requirement carries the record's OWN id, so the derivation's control-id guard
    # passes on an exact match and the authored assertion is read for the control it was
    # actually written about.
    $row = Get-MlsComplianceControlRow -ControlId $id -Requirement ([pscustomobject]@{ id = $id }) `
        -Assessment $assessmentByControl[$id] -AssessmentPath $assessmentPathByControl[$id] `
        -Evidence $forControl

    $related = @()
    if ($requirementByControlMapping.ContainsKey($id)) { $related = @($requirementByControlMapping[$id]) }
    $relatedText = if ($related.Count -eq 0) { 'no requirement in the catalog cites it' } else { $related -join ', ' }

    $row.framework = 'nist-800-53r5'
    $row.inCatalog = $false
    $row.family = ($id -split '-')[0]
    $row | Add-Member -NotePropertyName 'requirementsMappingToThisControl' -NotePropertyValue $related
    $row | Add-Member -NotePropertyName 'note' -NotePropertyValue (@(
            "This record was assessed against NIST SP 800-53 Rev 5 control $id."
            'The NIST SP 800-171 Rev 2 catalog has no requirement for it, so it is rendered on'
            'its own row and counted separately from the 110.'
            "requirementsMappingToThisControl ($relatedText) is listed for orientation only:"
            'this record''s assertion is not applied to those requirements and does not appear'
            'in their rows, because its author wrote about'
            "$id, not about them."
        ) -join ' ')
    $outOfCatalog.Add($row)
}

# --- 5. summary ------------------------------------------------------------------------------

$vocabulary = Get-MlsComplianceVocabulary

# Projected through ForEach-Object rather than member enumeration ($control.status):
# under Set-StrictMode -Version Latest, enumerating a member off an EMPTY collection
# throws, and an empty out-of-catalog list is the ordinary case for a register that keys
# every record on a catalog id.
$byStatus = Get-MlsComplianceCount -Key $vocabulary.Status -Value @($control | ForEach-Object { $_.status })
$byProvenance = Get-MlsComplianceCount -Key $vocabulary.Provenance -Value @($control | ForEach-Object { $_.provenance })

# The cross-tabulation is the answer to "a wholly skipped control counts as
# machine-verified": machine-verified is never presentable as a single figure without its
# status breakdown beside it.
$byProvenanceAndStatus = [ordered]@{}
foreach ($provenance in $vocabulary.Provenance) {
    $byProvenanceAndStatus[$provenance] = Get-MlsComplianceCount -Key $vocabulary.Status `
        -Value @($control | Where-Object provenance -EQ $provenance | ForEach-Object { $_.status })
}

$summary = [pscustomobject][ordered]@{
    totalRequirements     = $control.Count
    byStatus              = $byStatus
    byProvenance          = $byProvenance
    byProvenanceAndStatus = [pscustomobject]$byProvenanceAndStatus
    outOfCatalog          = [pscustomobject][ordered]@{
        count        = $outOfCatalog.Count
        byStatus     = Get-MlsComplianceCount -Key $vocabulary.Status -Value @($outOfCatalog | ForEach-Object { $_.status })
        byProvenance = Get-MlsComplianceCount -Key $vocabulary.Provenance -Value @($outOfCatalog | ForEach-Object { $_.provenance })
    }
    notes                 = @($script:ProvenanceNote, $script:AssertedNote, $script:CountsOnlyNote)
}

# --- 6. provenance of the artifact itself ------------------------------------------------------

$commitSha = Get-MlsComplianceTrimmed $Commit
$workingTreeClean = $false
try {
    if ($null -eq $commitSha) {
        $revParse = Invoke-MlsGit -Argument @('rev-parse', 'HEAD') -WorkingDirectory $script:GitRoot
        if ($revParse.ExitCode -eq 0 -and $revParse.Line.Count -gt 0) {
            $commitSha = Get-MlsComplianceTrimmed $revParse.Line[0]
        }
    }
    $porcelain = Invoke-MlsGit -Argument @('status', '--porcelain') -WorkingDirectory $script:GitRoot
    $workingTreeClean = ($porcelain.ExitCode -eq 0 -and $porcelain.Line.Count -eq 0)
}
catch {
    # git absent or the tree is not a checkout. Not fatal - but the artifact must not
    # claim a clean tree it could not observe, so it stays false.
    Write-Warning "Invoke-MlsCompliance: could not read git state - $($_.Exception.Message)"
}
if ($null -eq $commitSha) {
    throw 'Invoke-MlsCompliance: could not determine the commit to stamp. Pass -Commit explicitly; an artifact that cannot name the commit it was collected at is not a defensible record.'
}

$state = [pscustomobject][ordered]@{
    schemaVersion        = 1
    framework            = Get-MlsProperty -InputObject $catalog -Name 'framework'
    frameworkName        = Get-MlsProperty -InputObject $catalog -Name 'frameworkName'
    collectedAt          = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    commit               = $commitSha
    commitShort          = $commitSha.Substring(0, [Math]::Min(7, $commitSha.Length))
    workingTreeClean     = $workingTreeClean
    notes                = [pscustomobject][ordered]@{
        supportingEvidence   = $script:SupportingEvidenceNote
        outOfCatalogControls = $script:OutOfCatalogNote
        countsOnly           = $script:CountsOnlyNote
    }
    summary              = $summary
    collectors           = @($collectorResult)
    assessmentProblems   = @($assessmentProblem)
    controls             = @($control)
    outOfCatalogControls = @($outOfCatalog)
}

# --- 7. write --------------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

$datedPath = Join-Path -Path $OutputRoot -ChildPath "state-$($state.collectedAt.Substring(0, 10)).json"
$latestPath = Join-Path -Path $OutputRoot -ChildPath 'state-latest.json'

# Written through .NET rather than Set-Content so the bytes are identical whichever OS
# ran the collection: UTF-8 with no BOM, LF only, one trailing newline. The repo is
# authored on Windows and collected on Linux, and a CRLF artifact would make every CI
# commit a whole-file diff.
$json = ($state | ConvertTo-Json -Depth 12) -replace "`r`n", "`n"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($datedPath, $json + "`n", $utf8NoBom)

# A REAL FILE COPY, never a symlink or a hard link: this repo is authored on Windows
# (where creating a symlink needs Developer Mode or elevation) and collected on Linux, and
# a link would not survive that round trip or a zip-based artifact download. Any existing
# entry is removed first so a copy can never be written THROUGH a link left behind by
# something else.
if (Test-Path -LiteralPath $latestPath) {
    Remove-Item -LiteralPath $latestPath -Force -ErrorAction SilentlyContinue
}
Copy-Item -LiteralPath $datedPath -Destination $latestPath -Force

Write-Information "compliance state written: $datedPath (and state-latest.json)" -InformationAction Continue
Write-Information (@(
        "  $($control.Count) requirements;"
        "$($outOfCatalog.Count) out-of-catalog record(s);"
        "$($evidence.Count) evidence record(s) from $(@($collectorResult | Where-Object status -EQ 'ok').Count) of $($collectorResult.Count) collectors."
    ) -join ' ') -InformationAction Continue

if ($PassThru) { return $state }
