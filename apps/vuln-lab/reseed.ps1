#Requires -Version 7.0
<#
.SYNOPSIS
    Re-arms the vuln-lab after a self-healing cycle: restores BOTH the seeded
    CodeQL code flaws and the three deliberately vulnerable dependency pins.

.DESCRIPTION
    L10 heals this lab along two tracks, and a completed cycle disarms both:

      * Copilot Autofix rewrites the seeded CODE flaws in seeds/*.js
        (CodeQL alerts -> autofix -> PR -> gauntlet -> auto-merge);
      * Dependabot bumps the vulnerable dependency PINS.

    This script restores the seeded state so the next demo has real alerts of
    both kinds to heal again:

      1. restores each seeds/<name>.js from its armed twin seeds/<name>.js.seed
         and verifies the flaw's marker line is back;
      2. rewrites apps/vuln-lab/package.json's dependency block to the pinned
         vulnerable versions;
      3. regenerates package-lock.json from those pins (npm install
         --package-lock-only, no packages downloaded);
      4. verifies with `npm audit` that all three advisories are back.

    WHY THE `.js.seed` TWINS. Autofix edits `seeds/*.js`; it never touches
    `*.js.seed`, and CodeQL does not extract that extension, so the armed
    original survives the heal it is meant to be restored from. Restoring is a
    file copy rather than a patch, so it cannot half-succeed.

    Step 1 runs FIRST and is entirely offline, so `-SkipAudit` (which returns
    early) can never leave the code half of the lab disarmed.

    The script only writes inside apps/vuln-lab. It NEVER commits or pushes:
    per CLAUDE.md the restored seeds reach main through a normal PR, which is
    what re-raises both alert kinds.

.PARAMETER WhatIf
    Standard: shows the changes without writing them.

.PARAMETER SkipAudit
    Skip the post-reseed `npm audit` verification (offline use). The code-flaw
    restore in step 1 still runs.

.EXAMPLE
    pwsh apps/vuln-lab/reseed.ps1

.EXAMPLE
    pwsh apps/vuln-lab/reseed.ps1 -WhatIf

.NOTES
    Seeded code flaws (both in the DEFAULT CodeQL suite, so GitHub default
    setup and this repo's security-and-quality config both report them):
      seeds/report-viewer.js      js/path-injection          CWE-22/23/36/73/99
      seeds/component-history.js  js/command-line-injection  CWE-78/88

    Seeded advisories (all fixable without a major-version bump):
      json5    2.2.0 -> 2.2.2  GHSA-9c47-m6qq-7p4h / CVE-2022-46175 (high)
      minimist 1.2.5 -> 1.2.6  GHSA-xvch-5gv4-984h / CVE-2021-44906 (critical)
      semver   7.5.1 -> 7.5.2  GHSA-c2qf-rxjj-qqgw / CVE-2022-25883 (high)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $SkipAudit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The seeded (vulnerable) pins this lab must always return to.
$VulnerablePins = [ordered]@{
    json5    = '2.2.0'
    minimist = '1.2.5'
    semver   = '7.5.1'
}

# The seeded (vulnerable) CODE this lab must always return to. `Marker` is the
# exact line carrying the flaw: if Autofix's rewrite survived the restore, the
# marker is absent and the lab is silently disarmed - which would waste an L10
# audit attempt, so it is an error rather than a warning.
$CodeFlaws = @(
    [pscustomobject]@{
        Path   = 'seeds/report-viewer.js'
        Seed   = 'seeds/report-viewer.js.seed'
        Rule   = 'js/path-injection'
        Marker = 'const reportPath = path.join(REPORTS_DIR, requested);'
    }
    [pscustomobject]@{
        Path   = 'seeds/component-history.js'
        Seed   = 'seeds/component-history.js.seed'
        Rule   = 'js/command-line-injection'
        Marker = 'const command = "git log --oneline -20 -- " + component;'
    }
)

$labRoot = $PSScriptRoot
$manifestPath = Join-Path $labRoot 'package.json'
$lockPath = Join-Path $labRoot 'package-lock.json'

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "vuln-lab manifest not found at $manifestPath"
}

Write-Information "Re-seeding vuln-lab at $labRoot" -InformationAction Continue

# --- 1. restore the seeded code flaws ---------------------------------------
# Deliberately first: it is offline, and -SkipAudit returns early further down.

foreach ($flaw in $CodeFlaws) {
    $target = Join-Path $labRoot $flaw.Path
    $source = Join-Path $labRoot $flaw.Seed

    if (-not (Test-Path -LiteralPath $source)) {
        throw ("Armed original missing: {0}. Without it the {1} flaw cannot be restored and the Autofix track has nothing to heal." -f $flaw.Seed, $flaw.Rule)
    }

    $armed = Get-Content -LiteralPath $source -Raw
    $current = if (Test-Path -LiteralPath $target) { Get-Content -LiteralPath $target -Raw } else { $null }

    if ($current -eq $armed) {
        Write-Information ("  {0}: already armed ({1})." -f $flaw.Path, $flaw.Rule) -InformationAction Continue
        continue
    }

    $reason = if ($null -eq $current) { 'absent' } else { 'healed or edited' }
    Write-Information ("  {0}: {1} -> restoring from {2} ({3})" -f $flaw.Path, $reason, $flaw.Seed, $flaw.Rule) -InformationAction Continue

    if ($PSCmdlet.ShouldProcess($target, "Restore the seeded $($flaw.Rule) flaw")) {
        Copy-Item -LiteralPath $source -Destination $target -Force
        $restored = Get-Content -LiteralPath $target -Raw
        if ($restored -notlike ("*{0}*" -f $flaw.Marker)) {
            throw ("Re-seed incomplete: {0} was restored but its {1} marker line is missing. The lab is not armed." -f $flaw.Path, $flaw.Rule)
        }
    }
}

# --- 2. restore the vulnerable pins in package.json -------------------------
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$current = $manifest.dependencies

$changes = [System.Collections.Generic.List[string]]::new()
foreach ($name in $VulnerablePins.Keys) {
    $want = $VulnerablePins[$name]
    $have = if ($current.PSObject.Properties.Name -contains $name) { $current.$name } else { $null }
    if ($have -ne $want) {
        $changes.Add(("{0}: {1} -> {2}" -f $name, ($have ?? '(absent)'), $want))
    }
}

if ($changes.Count -eq 0) {
    Write-Information 'Pins already at seeded (vulnerable) versions.' -InformationAction Continue
}
else {
    foreach ($change in $changes) {
        Write-Information "  $change" -InformationAction Continue
    }
}

# Rebuild the dependency object so the key order is deterministic.
$deps = [ordered]@{}
foreach ($name in $VulnerablePins.Keys) {
    $deps[$name] = $VulnerablePins[$name]
}
$manifest.dependencies = [pscustomobject]$deps

if ($PSCmdlet.ShouldProcess($manifestPath, 'Restore vulnerable dependency pins')) {
    # npm writes package.json with two-space indent and a trailing newline.
    $json = $manifest | ConvertTo-Json -Depth 20
    $json = $json -replace "`r`n", "`n"
    Set-Content -LiteralPath $manifestPath -Value ($json + "`n") -Encoding utf8NoBOM -NoNewline
    Write-Information "Wrote $manifestPath" -InformationAction Continue
}

# --- 3. regenerate the lockfile from those pins -----------------------------
if ($PSCmdlet.ShouldProcess($lockPath, 'Regenerate lockfile from seeded pins')) {
    Push-Location $labRoot
    try {
        # --package-lock-only: resolve and write the lockfile without installing.
        # --no-workspaces: the lab is audited standalone, not through the root.
        $installArgs = @('install', '--package-lock-only', '--no-workspaces', '--no-audit', '--no-fund')
        & npm @installArgs
        if ($LASTEXITCODE -ne 0) {
            throw "npm install --package-lock-only failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
    Write-Information "Wrote $lockPath" -InformationAction Continue
}

# --- 4. verify the advisories are back --------------------------------------
if ($SkipAudit) {
    Write-Information 'Skipping npm audit verification (-SkipAudit).' -InformationAction Continue
    return
}

if (-not $PSCmdlet.ShouldProcess($labRoot, 'Verify seeded advisories with npm audit')) {
    return
}

$auditArgs = @('audit', '--json', '--no-workspaces')
Push-Location $labRoot
try {
    # npm audit exits non-zero when advisories exist, which is the armed state.
    $auditJson = & npm @auditArgs
}
finally {
    Pop-Location
}

if (-not $auditJson) {
    Write-Warning 'npm audit produced no output; verify network access and re-run.'
    return
}

$audit = $auditJson | ConvertFrom-Json
$found = @($audit.vulnerabilities.PSObject.Properties.Name)
$expected = @($VulnerablePins.Keys)
$missing = @($expected | Where-Object { $_ -notin $found })

foreach ($name in $found) {
    $entry = $audit.vulnerabilities.$name
    Write-Information ("  advisory: {0} ({1})" -f $name, $entry.severity) -InformationAction Continue
}

if ($missing.Count -gt 0) {
    throw ("Re-seed incomplete: no advisory reported for {0}. The lab is not armed." -f ($missing -join ', '))
}

Write-Information ("vuln-lab re-armed: {0} advisories present ({1}); {2} code flaw(s) restored ({3})." -f
    $found.Count, ($found -join ', '), $CodeFlaws.Count, (($CodeFlaws | ForEach-Object { $_.Rule }) -join ', ')) -InformationAction Continue
Write-Information 'Open a PR with these changes; never push to main directly (CLAUDE.md).' -InformationAction Continue
Write-Information 'The merge is what re-raises both the Dependabot alerts and the CodeQL alerts.' -InformationAction Continue
