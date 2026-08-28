#Requires -Version 7.0
<#
.SYNOPSIS
    The contract every compliance collector (Tasks 5-7) is built on: a validated,
    timestamped evidence record, and a runner that makes a collector structurally
    incapable of mutating the estate it assesses.

.DESCRIPTION
    Two functions:

      New-MlsEvidence     - builds one EvidenceRecord (spec section 4), validated and
                             stamped at construction. This is the shape of every evidence
                             record the platform will ever produce.
      Invoke-MlsCollector - runs a collector's scriptblock and validates EVERY record it
                             emits, not just the first, before handing them back.

    BARE `az`/`gh`/`git` INSIDE A COLLECTOR IS NOT SAFE BY ACCIDENT
    ----------------------------------------------------------------
    verification/MlsAudit.psm1's read-only guards
    (Assert-MlsReadOnlyAzArgument / Assert-MlsReadOnlyGhArgument) protect callers of
    Invoke-MlsAz / Invoke-MlsGh - they do nothing for a collector that shells out to the
    bare `az`, `gh` or `git` executable directly, which is exactly the shape a careless
    collector author reaches for first (it is also the literal shape of the plan's own
    isolation test: `az group create -n x -l y`, not `Invoke-MlsAz -Argument @('group',
    'create', ...)`). A guard a collector can sidestep by typing the native command name
    is not "structurally incapable of mutating" - it is a guideline.

    Invoke-MlsCollector closes that gap by SHADOWING `az`, `gh` and `git` for the
    duration of the scriptblock's execution: it defines three functions of those names
    AT THE GLOBAL SCOPE (`function global:az { ... }`), each of which routes to the
    corresponding guarded MlsAudit transport (Invoke-MlsAz / Invoke-MlsGh / Invoke-MlsGit),
    invokes the collector's scriptblock, and then removes (or restores, if something else
    had already defined one) each shadow in a `finally` before returning - regardless of
    whether the scriptblock succeeded, returned invalid records, or threw. PowerShell
    looks up a function ahead of an external command of the same name, so a bare
    `az group create -n x -l y` inside the scriptblock, or `& az group create ...` via
    the call operator, resolves to the shadow rather than the real az.exe. The same
    read-only assertions verification/ already runs apply, because the shadow's whole
    body is a call to the guarded transport. `git` is shadowed onto Invoke-MlsGit, which
    only permits `grep`/`log`/`show`/`ls-files`/`rev-parse`/`status`/`diff` - any other
    verb, including every mutating one, is refused there already.

    WHY GLOBAL SCOPE, NOT A LOCAL ONE
    ------------------------------------
    A collector's scriptblock is written somewhere else entirely - a collector file, a
    Pester `It` block - which means it was PARSED in a different PowerShell session state
    than this module's. PowerShell resolves a scriptblock's commands against the session
    state it was created in, not the session state of whatever happens to be calling `&`
    at the moment: defining `function az { ... }` inside Invoke-MlsCollector's own
    (module-local) function scope is invisible to a scriptblock that was never parsed
    inside this module, and the real az.exe still answers a bare `az` call from one -
    verified experimentally, not merely reasoned about, because the failure is easy to
    miss (it looks identical to the working case until something actually calls the CLI).
    `global:` is the one scope every session state's command resolution can reach
    regardless of which module parsed the scriptblock, so it is the only scope a
    cross-module shadow can use.

    This also means the shadow is genuinely global and process-wide for the (short)
    duration of one Invoke-MlsCollector call - a second call running concurrently on
    another thread would see the first call's shadow. Every consumer in this plan runs
    collectors sequentially (Task 8's runner, and Pester without `-Parallel`), so this is
    an accepted simplification rather than a real hazard today; a future concurrent
    runner would need a different mechanism.

    THE MECHANISM THIS REPLACED, AND WHY
    ----------------------------------------
    An earlier draft used `ScriptBlock.InvokeWithContext()`, the API actually designed
    for "inject temporary functions/variables around an existing scriptblock without
    redefining it," which sidesteps the cross-session-state problem entirely by operating
    on the scriptblock instance itself. It works outside Pester, but every test that goes
    through it fails with `InvalidOperationException: A 'break' or 'continue' statement
    with a label that does not match any enclosing loop escaped from your code` (a known
    interaction between that API and Pester's own scriptblock instrumentation - see
    https://github.com/pester/Pester/issues/2669). This platform's entire test suite runs
    under Pester, so an isolation mechanism that cannot run under test is not a mechanism
    this repo can ship, however textbook-correct the API is otherwise.

    THE ALTERNATIVE, AND WHY IT LOSES
    ----------------------------------
    Refusing bare native calls outright (throw the moment `az`/`gh`/`git` resolves to the
    real executable at all) is simpler to implement, but it fails the plan's own isolation
    test dishonestly: that test expects the message to say '*read-only*', naming the
    reason a MUTATING call was refused, not merely that native invocation is banned. A
    blanket ban would also make it impossible for a collector to legitimately shell out to
    `git grep` for a repo-static check the way L1.3's own audit already does
    (verification/layer-01-audit.ps1) - it would have to duplicate Invoke-MlsGit's logic
    or route everything through it by hand, which is exactly the reimplementation the
    plan brief says not to do. Shadowing keeps the safe verbs usable while making the
    mutating ones throw for the real, stated reason.

    WHAT THIS DOES NOT COVER
    -------------------------
    This guards the invocation shapes a collector author would actually type: bare
    `az ...`, `& az ...`, and their `gh`/`git` equivalents. It does not chase
    `Start-Process az`, dynamic invocation built from a string via `aliases (Set-Alias -Scope Global az ... defeats the shadow outright, because aliases outrank functions in command resolution - the one bypass an author could reach by accident rather than intent), Start-Process, cmd /c. NOT in this list, because it IS covered: Invoke-Expression`,
    or a `.exe` invoked by an absolute path - those are deliberate evasions, not the
    "typed `az` instead of `Invoke-MlsAz`" failure mode this exists to catch, and no
    collector in this plan needs any of them.

    EVIDENCE MUST NEVER STAND FOR AN ABSENCE OF OBSERVATION
    ----------------------------------------------------------
    Two rules make that structural rather than a matter of collector discipline:

      1. -Status accepts only the literal words `pass`, `fail` or `inconclusive`
         (case-sensitively) - the literal words `skip` and `pending` themselves are
         refused, so nobody invents a fourth status. A collector that read a SKIPPED or
         PENDING criterion reports it as `inconclusive` - never omitted, and never
         `pass`. Omitting it would actually be LESS honest: under Task 3's derivation
         (Get-MlsControlStatus) a claimed criterion with no matching evidence record
         renders INCONCLUSIVE with provenance 'none' ("we have no idea"), while an
         inconclusive record renders the same status with provenance 'machine-verified'
         and an Observed line saying exactly why the criterion did not resolve - strictly
         more informative, no less honest. What must never happen, and what this rule
         exists to block, is a SKIPPED or PENDING criterion surfacing as `pass`.
      2. -Observed is mandatory and, after trimming whitespace, must be non-empty.
         Observed is the field that lets a human judge whether a criterion-to-control
         mapping is honest (spec section 6.1); a record without it is not evidence of
         anything and this module refuses to construct or accept one.

    REFERENTIAL INTEGRITY AGAINST THE CATALOG
    -------------------------------------------
    -Control must resolve to a real requirement id in
    compliance/catalog/nist-800-171r2.json - checked via MlsAudit.psm1's
    Get-MlsControlCatalogRequirementId, the same catalog set Invoke-MlsCriterion already
    validates -Control against, reused rather than reimplemented so the two checks can
    never drift apart. A dangling control id has already shipped once on this branch
    (compliance/README.md's four 800-53-keyed register records); this is the collector
    side of preventing a second one.

    ONE VALIDATION PATH, TWO CALLERS
    -----------------------------------
    Get-MlsEvidenceProblem is the single place these rules are checked. New-MlsEvidence
    runs a fully-built candidate record through it before returning; Invoke-MlsCollector
    runs the same function over every object a collector's scriptblock emitted, whether
    or not it came from New-MlsEvidence - a collector that builds a hashtable by hand and
    forgets a field, or invents a status word, fails the exact same way a bad call to
    New-MlsEvidence would. Two enforcement paths that could drift apart would be worse
    than one.
#>

Set-StrictMode -Version Latest

# --- dependency -------------------------------------------------------------------------
# The read-only transport guards and the catalog id set both live in verification/
# MlsAudit.psm1 (spec section 4.1: "collectors ... live beside verification/ and reuse
# MlsAudit.psm1 ... structurally incapable of mutating"). Reused here, not reimplemented.
$script:MlsAuditModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..' `
    -AdditionalChildPath '..', 'verification', 'MlsAudit.psm1'
Import-Module $script:MlsAuditModulePath -Force -ErrorAction Stop

# The only three literal status words an EvidenceRecord may carry. Deliberately not
# 'skip' or 'pending' - see the module header.
$script:MlsEvidenceStatus = @('pass', 'fail', 'inconclusive')

# The one collector that reads Verifier audits, and therefore the only source permitted
# to name a criterion. See Get-MlsEvidenceProblem.
$script:MlsCriterionScopedSource = 'verification-suite'

# --- private helpers ----------------------------------------------------------------------

function Get-MlsEvidenceText {
    <#
    .SYNOPSIS
        Trimmed string form of a value, or $null when it is not usable text.
    .DESCRIPTION
        A non-string, a null, an empty string and a whitespace-only string all reduce to
        $null, matching MlsCompliance.psm1's Get-MlsComplianceText - the same shape of
        gate, kept local rather than imported so this module's only cross-module
        dependency stays MlsAudit.psm1 (the one the brief names).
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -isnot [string]) { return $null }
    $trimmed = $Value.Trim()
    if ($trimmed.Length -eq 0) { return $null }
    return $trimmed
}

function Get-MlsEvidenceProblem {
    <#
    .SYNOPSIS
        Every structural problem with a candidate evidence record, or an empty array
        when it is a valid EvidenceRecord. Shared by New-MlsEvidence and
        Invoke-MlsCollector so construction and post-hoc validation can never enforce
        different rules.
    #>
    [OutputType([string[]])]
    param($Record)

    # criterion is a Verifier-audit concept. Only the verification-suite collector reads
    # Verifier audits, so only it may set one. Enforced here rather than left to each
    # collector's restraint: a reviewer demonstrated that
    # `New-MlsEvidence -Source 'manual' ... -Criterion 'V3.3'` derived
    # COMPLIANT / machine-verified end to end, as did a hand-built record passed through
    # Invoke-MlsCollector - which also defeated the four per-collector "never sets a
    # criterion" tests, since those only observe what the collectors choose to emit.
    # Control-scoped evidence satisfying a criterion that never ran is the single worst
    # thing this contract could permit.

    $problem = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $Record) {
        $problem.Add('the record is $null')
        return , @($problem.ToArray())
    }

    $control = Get-MlsEvidenceText (Get-MlsProperty -InputObject $Record -Name 'control')
    if ($null -eq $control) {
        $problem.Add("'control' is missing or blank")
    }
    else {
        $validControlId = Get-MlsControlCatalogRequirementId
        if (-not $validControlId.Contains($control)) {
            $problem.Add("'control' value '$control' is not a requirement id in compliance/catalog/nist-800-171r2.json")
        }
    }

    $source = Get-MlsEvidenceText (Get-MlsProperty -InputObject $Record -Name 'source')
    if ($null -eq $source) {
        $problem.Add("'source' is missing or blank")
    }

    $status = Get-MlsProperty -InputObject $Record -Name 'status'
    if (-not ($script:MlsEvidenceStatus -ccontains "$status")) {
        $problem.Add("'status' is '$status'; it must be exactly one of $($script:MlsEvidenceStatus -join ', ') " +
            "- a collector must never default an absent or unrecognised status, and must report a SKIPPED or " +
            "PENDING criterion as 'inconclusive', never the literal word 'skip' or 'pending' and never 'pass'")
    }

    $observed = Get-MlsEvidenceText (Get-MlsProperty -InputObject $Record -Name 'observed')
    if ($null -eq $observed) {
        $problem.Add("'observed' is missing or blank - it is the field that lets a reader judge whether the mapping is honest")
    }

    $collectedAt = Get-MlsProperty -InputObject $Record -Name 'collectedAt'
    if ([string]::IsNullOrWhiteSpace("$collectedAt") -or "$collectedAt" -notmatch '^\d{4}-\d{2}-\d{2}T') {
        $problem.Add("'collectedAt' must be an ISO-8601 timestamp stamped at construction, found '$collectedAt'")
    }

    $criterion = Get-MlsEvidenceText (Get-MlsProperty -InputObject $Record -Name 'criterion')
    if ($null -ne $criterion -and $source -ne $script:MlsCriterionScopedSource) {
        $problem.Add("'criterion' is '$criterion' but 'source' is '$source'; only the " +
            "$($script:MlsCriterionScopedSource) collector reads Verifier audits, so only it may name a " +
            "criterion. Control-scoped evidence carrying a criterion would satisfy a declared criterion " +
            "that never ran, and could make a control derive COMPLIANT / machine-verified off a grep of " +
            "the working tree")
    }

    return , @($problem.ToArray())
}

# --- public contract ----------------------------------------------------------------------

function New-MlsEvidence {
    <#
    .SYNOPSIS
        Build one validated, timestamped EvidenceRecord (spec section 4). The shape of
        every evidence record the platform will ever produce.
    .PARAMETER Control
        The NIST SP 800-171 Rev 2 requirement id this record is evidence for. Must
        resolve in compliance/catalog/nist-800-171r2.json (Task 1's catalog, the
        authoritative source); a typo or a stale id throws immediately naming the
        offending value, rather than shipping a dangling pointer.
    .PARAMETER Source
        The collector that produced this record, e.g. 'verification-suite'.
    .PARAMETER Status
        pass | fail | inconclusive - the only three literal words accepted; `skip` and
        `pending` are refused so nobody invents a fourth status. A collector reading a
        SKIPPED or PENDING criterion reports it as `inconclusive` - that is the honest
        word for "ran, but did not resolve to pass or fail" - never omitted and never
        `pass`. See the module header (EVIDENCE MUST NEVER STAND FOR AN ABSENCE OF
        OBSERVATION) for why silence is less honest than an inconclusive record here.
    .PARAMETER Observed
        What was actually seen, in plain language. Mandatory and non-blank: it is the
        field that lets a human judge whether the criterion-to-control mapping is honest
        (spec section 6.1), so a record without it carries no defensible claim and this
        function refuses to build one.
    .PARAMETER Criterion
        The Verifier criterion id this record came from, e.g. 'V3.3'. Optional, because
        evidence comes in two shapes and only one of them has a criterion:
          * CRITERION-SCOPED - produced by the verification-suite collector from a layer
            audit row. Task 3's Get-MlsControlStatus matches these against an
            assessment's declared `criteria` list BY THIS FIELD, so a record without it
            can never satisfy a declared criterion however well its control matches.
          * CONTROL-SCOPED - produced by the repo-static, github-security, azure-policy
            and manual collectors, which observe a control directly and have no criterion
            to name. These carry $null here.
        It lives in the contract rather than being bolted on by each collector because
        two other tasks already depend on reading it: Task 5's tests select on
        `.criterion`, and Task 3's derivation joins on it.
    .PARAMETER Artifact
        The committed report or file this record came from, when there is one. Optional.
    .OUTPUTS
        [pscustomobject] with control, source, status, observed, artifact and a
        collectedAt stamped in ISO-8601 at construction.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record; no system state is changed.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Control,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Source,
        [Parameter(Mandatory)][ValidateSet('pass', 'fail', 'inconclusive')][string]$Status,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Observed,
        [AllowNull()][AllowEmptyString()][string]$Criterion = $null,
        [AllowNull()][AllowEmptyString()][string]$Artifact = $null
    )

    $candidate = [pscustomobject]@{
        control     = $Control
        criterion   = if ([string]::IsNullOrWhiteSpace($Criterion)) { $null } else { $Criterion.Trim() }
        source      = $Source
        status      = $Status
        observed    = $Observed
        artifact    = $Artifact
        collectedAt = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    $problem = Get-MlsEvidenceProblem -Record $candidate
    if ($problem.Count -gt 0) {
        throw "New-MlsEvidence: invalid evidence record ($($problem -join '; '))."
    }

    return $candidate
}

function Invoke-MlsCollector {
    <#
    .SYNOPSIS
        Run a collector's scriptblock with `az`/`gh`/`git` shadowed onto MlsAudit's
        read-only transports, and validate every record it emits before returning them.
    .PARAMETER Name
        The collector's name, used only to attribute a thrown error to the right
        collector (e.g. 'verification-suite').
    .PARAMETER ScriptBlock
        The collector body. Runs with `az`, `gh` and `git` shadowed for its duration
        (see the module header) so a bare mutating call throws for the same read-only
        reason Invoke-MlsAz / Invoke-MlsGh / Invoke-MlsGit already throw for. Whatever it
        outputs is treated as a stream of candidate evidence records.
    .DESCRIPTION
        Any exception - from the shadowed transports, from a call the shadow does not
        cover, or from the collector's own logic - propagates out of this function
        rather than being swallowed: a collector that fails partway through must surface
        that failure, not silently hand back whatever it managed to emit before it died.

        Every emitted record - not only the first - is checked with the same
        Get-MlsEvidenceProblem rules New-MlsEvidence itself uses, so a collector that
        builds records by hand (rather than calling New-MlsEvidence) cannot bypass the
        contract, and a bad record anywhere in the stream fails the whole run rather than
        shipping a partially-validated set.
    .OUTPUTS
        The collector's emitted records, each already proven valid.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalFunctions', '',
        Justification = 'Deliberate, save-and-restore isolation shadow, not accidental script pollution - see the module header (WHY GLOBAL SCOPE, NOT A LOCAL ONE). Global scope is the only one a foreign scriptblock''s command resolution can reach regardless of which module parsed it; every prior definition is captured and restored in a finally block, and the shadow never survives past this one function call.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    # Shadow az/gh/git at the global scope - the one scope reachable from a scriptblock
    # regardless of which session state parsed it (see the module header for why a
    # module-local function definition does not work here). Any pre-existing global
    # function of the same name is saved and restored, rather than assumed absent, so a
    # theoretical nested call - or a leftover shadow from an aborted prior run - cannot
    # widen or narrow what the next collector inherits.
    $shadowCommand = @('az', 'gh', 'git')
    $priorShadow = @{}
    foreach ($command in $shadowCommand) {
        $existing = Get-Item -Path "function:$command" -ErrorAction SilentlyContinue
        $priorShadow[$command] = if ($existing) { $existing.ScriptBlock } else { $null }
    }
    function global:az { Invoke-MlsAz -Argument ([string[]]$args) }
    function global:gh { Invoke-MlsGh -Argument ([string[]]$args) }
    function global:git { Invoke-MlsGit -Argument ([string[]]$args) }

    $raw = $null
    try {
        try {
            $raw = & $ScriptBlock
        }
        catch {
            throw "Collector '$Name' failed: $($_.Exception.Message)"
        }
    }
    finally {
        foreach ($command in $shadowCommand) {
            if ($null -ne $priorShadow[$command]) {
                Set-Item -Path "function:$command" -Value $priorShadow[$command] -Force
            }
            else {
                Remove-Item -Path "function:$command" -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $records = @($raw)
    foreach ($record in $records) {
        $problem = Get-MlsEvidenceProblem -Record $record
        if ($problem.Count -gt 0) {
            throw "Collector '$Name' emitted an invalid evidence record: $($problem -join '; ')."
        }
    }

    return $records
}

Export-ModuleMember -Function @(
    'New-MlsEvidence',
    'Invoke-MlsCollector'
)
