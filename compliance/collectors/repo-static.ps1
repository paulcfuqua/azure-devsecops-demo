#Requires -Version 7.0
<#
.SYNOPSIS
    The repo-static collector (spec section 4, plan Task 6): evidence read straight from
    the working tree, with no tenant and no network call.

.DESCRIPTION
    This is the only collector that works before G0. Nothing in this estate has ever
    been deployed, so every record this collector emits is evidence the REPOSITORY
    declares a control-relevant setting - never evidence that setting is running
    anywhere. That distinction is the single most important thing this file does: every
    `observed` string is built through Format-MlsRepoStaticObserved (below), which
    appends the same explicit "declared, not deployed" clause to every record, so a board
    rendering this collector's evidence cannot mistake repository intent for deployed
    reality no matter which check produced the record.

    EIGHT CHECKS, EACH A SMALL FUNCTION, EACH ONE RECORD
    -------------------------------------------------------
    Every Get-MlsRepoStatic*Evidence function inspects one part of the working tree and
    returns exactly one EvidenceRecord (CollectorContract.psm1) for exactly one control.
    Two checks (secret-scanning-workflow-present, no-secret-shaped-outputs) both target
    3.13.16 from different angles - a control can and does carry evidence from more than
    one check, and from more than one collector entirely (github-security also reports
    against 3.13.16 with a live GHAS signal Task 7 adds).

    CONTROL-SCOPED, NOT CRITERION-SCOPED
    -----------------------------------------
    None of these checks name a -Criterion. repo-static observes a control directly; it
    has no Verifier criterion to cite, and inventing one would be a false join key
    (CollectorContract.psm1's docstring, and Task 3's Get-MlsControlStatus, which matches
    machine-verified evidence to a declared criterion by that field alone).

    A CHECK THAT CANNOT RUN NEVER SILENTLY DISAPPEARS
    -------------------------------------------------------
    A file or directory a check expects (infra/bicep/platform/, .github/workflows/
    codeql.yml, apps/*/Dockerfile, ...) simply not existing is itself an observable,
    concrete finding - "0 occurrences" or "file not found" - and reports FAIL, the same as
    finding the file and it not satisfying the check. That is different from the source
    being wholly unreachable: when -RepoRoot itself does not exist, there is nothing to
    read at all, and this collector returns no evidence rather than fabricating eight FAIL
    records about a directory tree it was never given (see the module header rule: a
    missing or unreachable source is inconclusive or empty, never a manufactured verdict).

    ONE BAD CHECK MUST NOT LOSE THE OTHER SEVEN
    -------------------------------------------------
    Each check runs in its own try/catch at the orchestration level (mirroring Task 5's
    per-report try/catch): an exception in one check is logged with -WarningAction and the
    remaining checks still run. The Dependabot check additionally treats an unparsable
    dependabot.yml as its own recoverable case - `inconclusive`, not `fail` - because
    "could not be read" and "was read and does not cover anything" are different findings
    and only one of them is an honest FAIL.

.PARAMETER RepoRoot
    Root of the working tree to inspect. Defaults to this repository's own root (three
    directories up from this script), so it works the same run from anywhere. Overridable
    for tests, which point it at compliance/tests/fixtures/repo-static/<case> instead.

.OUTPUTS
    Zero or more validated EvidenceRecord objects (compliance/collectors/
    CollectorContract.psm1), each with `source` = 'repo-static' and `criterion` = $null.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest

$script:CollectorName = 'repo-static'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..')).Path
}
$script:RepoRoot = $RepoRoot

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'CollectorContract.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'verification', 'MlsAudit.psm1') -Force

# --- the honesty clause every record carries ------------------------------------------

function Format-MlsRepoStaticObserved {
    <#
    .SYNOPSIS
        Append the same explicit "this is the repository, not a deployment" clause to a
        check's factual finding, so every record this collector emits carries it
        identically rather than depending on each check remembering to write it.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Finding)
    return "$Finding This describes what the repository declares, not what is deployed " +
        '- nothing in this estate has been deployed, so it is not evidence anything runs.'
}

function Get-MlsRepoStaticArtifact {
    <#
    .SYNOPSIS
        A path relative to $RepoRoot, POSIX-separated, for an EvidenceRecord's
        `artifact` field - mirrors verification-suite's Get-MlsVerificationSuiteArtifact.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$FullPath
    )
    $relative = [System.IO.Path]::GetRelativePath($RepoRoot, $FullPath)
    return ($relative -replace '\\', '/')
}

# --- checks --------------------------------------------------------------------------

function Get-MlsRepoStaticDiagnosticSettingsEvidence {
    <#
    .SYNOPSIS
        3.3.1 - diagnosticSettings declared in the platform Bicep, >=4 occurrences.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    $platformDir = Join-Path -Path $RepoRoot -ChildPath 'infra/bicep/platform'
    if (-not (Test-Path -LiteralPath $platformDir -PathType Container)) {
        New-MlsEvidence -Control '3.3.1' -Source $script:CollectorName -Status 'fail' `
            -Observed (Format-MlsRepoStaticObserved 'No infra/bicep/platform directory exists; 0 diagnosticSettings declarations across 0 Bicep templates.')
        return
    }

    $bicepFile = @(Get-ChildItem -LiteralPath $platformDir -Filter '*.bicep' -File -Recurse -ErrorAction SilentlyContinue)
    $count = 0
    foreach ($file in $bicepFile) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        $count += @([regex]::Matches($text, '(?m)^\s*diagnosticSettings\s*:')).Count
    }
    $status = if ($count -ge 4) { 'pass' } else { 'fail' }
    New-MlsEvidence -Control '3.3.1' -Source $script:CollectorName -Status $status `
        -Observed (Format-MlsRepoStaticObserved "$count diagnosticSettings declaration(s) across $($bicepFile.Count) Bicep template(s) under infra/bicep/platform/.") `
        -Artifact (Get-MlsRepoStaticArtifact -RepoRoot $RepoRoot -FullPath $platformDir)
}

function Get-MlsRepoStaticSqlAuditEvidence {
    <#
    .SYNOPSIS
        3.3.2 - SQL audit destination declared (isAzureMonitorTargetEnabled present)
        somewhere in the platform Bicep.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    $platformDir = Join-Path -Path $RepoRoot -ChildPath 'infra/bicep/platform'
    if (-not (Test-Path -LiteralPath $platformDir -PathType Container)) {
        New-MlsEvidence -Control '3.3.2' -Source $script:CollectorName -Status 'fail' `
            -Observed (Format-MlsRepoStaticObserved 'No infra/bicep/platform directory exists; isAzureMonitorTargetEnabled is not declared anywhere.')
        return
    }

    $bicepFile = @(Get-ChildItem -LiteralPath $platformDir -Filter '*.bicep' -File -Recurse -ErrorAction SilentlyContinue)
    $found = $false
    foreach ($file in $bicepFile) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ($text -match 'isAzureMonitorTargetEnabled\s*:\s*true') { $found = $true; break }
    }
    $status = if ($found) { 'pass' } else { 'fail' }
    $finding = if ($found) {
        'isAzureMonitorTargetEnabled: true is declared on a SQL auditing settings resource under infra/bicep/platform/.'
    }
    else {
        "isAzureMonitorTargetEnabled is not declared true anywhere across $($bicepFile.Count) Bicep template(s) under infra/bicep/platform/."
    }
    New-MlsEvidence -Control '3.3.2' -Source $script:CollectorName -Status $status `
        -Observed (Format-MlsRepoStaticObserved $finding) `
        -Artifact (Get-MlsRepoStaticArtifact -RepoRoot $RepoRoot -FullPath $platformDir)
}

function Get-MlsRepoStaticCodeQlScheduleEvidence {
    <#
    .SYNOPSIS
        3.11.2 - .github/workflows/codeql.yml exists and declares a `schedule:` trigger.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    $path = Join-Path -Path $RepoRoot -ChildPath '.github/workflows/codeql.yml'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        New-MlsEvidence -Control '3.11.2' -Source $script:CollectorName -Status 'fail' `
            -Observed (Format-MlsRepoStaticObserved '.github/workflows/codeql.yml does not exist.')
        return
    }

    $text = Get-Content -LiteralPath $path -Raw
    $hasSchedule = $text -match '(?m)^\s*schedule\s*:\s*$'
    $status = if ($hasSchedule) { 'pass' } else { 'fail' }
    $finding = if ($hasSchedule) {
        'codeql.yml declares a schedule: trigger, so analysis runs on a cadence independent of pushes.'
    }
    else {
        'codeql.yml exists but declares no schedule: trigger - analysis would only ever run on push/pull_request.'
    }
    New-MlsEvidence -Control '3.11.2' -Source $script:CollectorName -Status $status `
        -Observed (Format-MlsRepoStaticObserved $finding) `
        -Artifact (Get-MlsRepoStaticArtifact -RepoRoot $RepoRoot -FullPath $path)
}

function Get-MlsRepoStaticDependabotEvidence {
    <#
    .SYNOPSIS
        3.14.1 - .github/dependabot.yml exists, parses as a recognised shape, and
        declares at least one package-ecosystem entry.
    .DESCRIPTION
        This platform has no YAML library available offline, so "parses" here means
        "read as text and the top-level updates: key and at least one
        `- package-ecosystem:` line are recognisable" - a deliberately light heuristic,
        not a YAML validator. A file that exists but does not look like a dependabot
        config at all (no updates: key found) is reported `inconclusive`, not `fail`:
        "could not be read as this shape" and "was read and covers nothing" are different
        findings, and only the second one is an honest FAIL.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    $path = Join-Path -Path $RepoRoot -ChildPath '.github/dependabot.yml'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        New-MlsEvidence -Control '3.14.1' -Source $script:CollectorName -Status 'fail' `
            -Observed (Format-MlsRepoStaticObserved '.github/dependabot.yml does not exist.')
        return
    }

    try {
        $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ($text -notmatch '(?m)^\s*updates\s*:\s*$') {
            throw 'no top-level updates: key found - not a recognised dependabot config shape'
        }
        $entry = @([regex]::Matches($text, '(?m)^\s*-\s*package-ecosystem\s*:\s*(\S+)') |
            ForEach-Object { $_.Groups[1].Value })
        $status = if ($entry.Count -ge 1) { 'pass' } else { 'fail' }
        $finding = if ($entry.Count -ge 1) {
            "dependabot.yml declares $($entry.Count) package-ecosystem entry(ies): $($entry -join ', ')."
        }
        else {
            'dependabot.yml has an updates: key but declares no package-ecosystem entries.'
        }
        New-MlsEvidence -Control '3.14.1' -Source $script:CollectorName -Status $status `
            -Observed (Format-MlsRepoStaticObserved $finding) `
            -Artifact (Get-MlsRepoStaticArtifact -RepoRoot $RepoRoot -FullPath $path)
    }
    catch {
        New-MlsEvidence -Control '3.14.1' -Source $script:CollectorName -Status 'inconclusive' `
            -Observed (Format-MlsRepoStaticObserved "dependabot.yml exists but could not be read as a recognised config: $($_.Exception.Message).") `
            -Artifact (Get-MlsRepoStaticArtifact -RepoRoot $RepoRoot -FullPath $path)
    }
}

function Get-MlsRepoStaticSecretScanningWorkflowEvidence {
    <#
    .SYNOPSIS
        3.13.16 - .github/workflows/gitleaks.yml exists and scans full history
        (fetch-depth: 0).
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    $path = Join-Path -Path $RepoRoot -ChildPath '.github/workflows/gitleaks.yml'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        New-MlsEvidence -Control '3.13.16' -Source $script:CollectorName -Status 'fail' `
            -Observed (Format-MlsRepoStaticObserved '.github/workflows/gitleaks.yml does not exist.')
        return
    }

    $text = Get-Content -LiteralPath $path -Raw
    $fullHistory = $text -match 'fetch-depth\s*:\s*0\b'
    $status = if ($fullHistory) { 'pass' } else { 'fail' }
    $finding = if ($fullHistory) {
        'gitleaks.yml exists and checks out with fetch-depth: 0 (full history scanned).'
    }
    else {
        'gitleaks.yml exists but does not declare fetch-depth: 0 - it would only scan a shallow checkout.'
    }
    New-MlsEvidence -Control '3.13.16' -Source $script:CollectorName -Status $status `
        -Observed (Format-MlsRepoStaticObserved $finding) `
        -Artifact (Get-MlsRepoStaticArtifact -RepoRoot $RepoRoot -FullPath $path)
}

function Get-MlsRepoStaticSecretShapedOutputEvidence {
    <#
    .SYNOPSIS
        3.13.16 - no Bicep `output` declares a secret-shaped name (ends in
        ConnectionString, Key or Secret). Anchored on the identifier's suffix, not a bare
        substring match, so a legitimate reference name like keyVaultUri or
        keyVaultResourceId (ends in Uri/Id, merely contains "key") does not false-positive.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    $bicepDir = Join-Path -Path $RepoRoot -ChildPath 'infra/bicep'
    if (-not (Test-Path -LiteralPath $bicepDir -PathType Container)) {
        New-MlsEvidence -Control '3.13.16' -Source $script:CollectorName -Status 'inconclusive' `
            -Observed (Format-MlsRepoStaticObserved 'No infra/bicep directory exists; no outputs to inspect.')
        return
    }

    $bicepFile = @(Get-ChildItem -LiteralPath $bicepDir -Filter '*.bicep' -File -Recurse -ErrorAction SilentlyContinue)
    $offender = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $bicepFile) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($match in [regex]::Matches($text, '(?m)^\s*output\s+(\S+)\s')) {
            $name = $match.Groups[1].Value
            if ($name -cmatch '(ConnectionString|Key|Secret)$') {
                $offender.Add("$($file.Name):$name")
            }
        }
    }
    $status = if ($offender.Count -eq 0) { 'pass' } else { 'fail' }
    $finding = if ($offender.Count -eq 0) {
        "No secret-shaped output names found across $($bicepFile.Count) Bicep template(s) under infra/bicep/."
    }
    else {
        "Secret-shaped output name(s) found: $($offender -join ', ')."
    }
    New-MlsEvidence -Control '3.13.16' -Source $script:CollectorName -Status $status `
        -Observed (Format-MlsRepoStaticObserved $finding) `
        -Artifact (Get-MlsRepoStaticArtifact -RepoRoot $RepoRoot -FullPath $bicepDir)
}

function Get-MlsRepoStaticNonRootContainerEvidence {
    <#
    .SYNOPSIS
        3.13.1 - every apps/*/Dockerfile declares a USER directive.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    $appsDir = Join-Path -Path $RepoRoot -ChildPath 'apps'
    if (-not (Test-Path -LiteralPath $appsDir -PathType Container)) {
        New-MlsEvidence -Control '3.13.1' -Source $script:CollectorName -Status 'fail' `
            -Observed (Format-MlsRepoStaticObserved 'No apps/ directory exists; no Dockerfile can be confirmed to run as non-root.')
        return
    }

    $dockerfile = @(Get-ChildItem -LiteralPath $appsDir -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path -Path $_.FullName -ChildPath 'Dockerfile' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        ForEach-Object { Get-Item -LiteralPath $_ })

    if ($dockerfile.Count -eq 0) {
        New-MlsEvidence -Control '3.13.1' -Source $script:CollectorName -Status 'fail' `
            -Observed (Format-MlsRepoStaticObserved 'No Dockerfile found under apps/*/.')
        return
    }

    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $dockerfile) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ($text -notmatch '(?m)^\s*USER\s+\S+') {
            $missing.Add((Get-MlsRepoStaticArtifact -RepoRoot $RepoRoot -FullPath $file.FullName))
        }
    }
    $status = if ($missing.Count -eq 0) { 'pass' } else { 'fail' }
    $finding = if ($missing.Count -eq 0) {
        "All $($dockerfile.Count) app Dockerfile(s) under apps/*/ declare a USER directive."
    }
    else {
        "$($missing.Count) of $($dockerfile.Count) app Dockerfile(s) declare no USER directive (run as root): $($missing -join ', ')."
    }
    New-MlsEvidence -Control '3.13.1' -Source $script:CollectorName -Status $status `
        -Observed (Format-MlsRepoStaticObserved $finding) `
        -Artifact (Get-MlsRepoStaticArtifact -RepoRoot $RepoRoot -FullPath $appsDir)
}

function Get-MlsRepoStaticBranchProtectionEvidence {
    <#
    .SYNOPSIS
        3.4.5 - branch protection documented as a committed ruleset config under
        .github/rulesets/.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    $rulesetDir = Join-Path -Path $RepoRoot -ChildPath '.github/rulesets'
    if (-not (Test-Path -LiteralPath $rulesetDir -PathType Container)) {
        New-MlsEvidence -Control '3.4.5' -Source $script:CollectorName -Status 'fail' `
            -Observed (Format-MlsRepoStaticObserved 'No .github/rulesets/ directory exists; branch protection is not documented as committed configuration.')
        return
    }

    $rulesetFile = @(Get-ChildItem -LiteralPath $rulesetDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $status = if ($rulesetFile.Count -ge 1) { 'pass' } else { 'fail' }
    $finding = if ($rulesetFile.Count -ge 1) {
        "$($rulesetFile.Count) ruleset config file(s) committed under .github/rulesets/: $($rulesetFile.Name -join ', ')."
    }
    else {
        '.github/rulesets/ exists but contains no ruleset config file.'
    }
    New-MlsEvidence -Control '3.4.5' -Source $script:CollectorName -Status $status `
        -Observed (Format-MlsRepoStaticObserved $finding) `
        -Artifact (Get-MlsRepoStaticArtifact -RepoRoot $RepoRoot -FullPath $rulesetDir)
}

# --- orchestration ---------------------------------------------------------------------

# Everything below runs inside Task 4's Invoke-MlsCollector so the same read-only guard
# applies here too, even though repo-static only ever reads the filesystem - a stray
# az/gh/git call added later fails the same way a real collector's would.
Invoke-MlsCollector -Name $script:CollectorName -ScriptBlock {

    if (-not (Test-Path -LiteralPath $script:RepoRoot)) {
        # -RepoRoot itself does not exist: there is nothing to read at all. This is the
        # "source unreachable" case, not eight manufactured FAIL records about a tree
        # that was never given to us.
        Write-Verbose "repo-static: repo root '$script:RepoRoot' does not exist; returning no evidence."
        return
    }

    $check = @(
        'Get-MlsRepoStaticDiagnosticSettingsEvidence',
        'Get-MlsRepoStaticSqlAuditEvidence',
        'Get-MlsRepoStaticCodeQlScheduleEvidence',
        'Get-MlsRepoStaticDependabotEvidence',
        'Get-MlsRepoStaticSecretScanningWorkflowEvidence',
        'Get-MlsRepoStaticSecretShapedOutputEvidence',
        'Get-MlsRepoStaticNonRootContainerEvidence',
        'Get-MlsRepoStaticBranchProtectionEvidence'
    )

    foreach ($checkName in $check) {
        # Each check is independent and isolated: one that throws unexpectedly is warned
        # about and skipped, and the rest still run (mirrors Task 5's per-report
        # try/catch, at the granularity of one check instead of one report file).
        try {
            & $checkName -RepoRoot $script:RepoRoot
        }
        catch {
            Write-Warning "repo-static: check '$checkName' failed - $($_.Exception.Message)"
        }
    }
}
