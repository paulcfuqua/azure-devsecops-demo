#Requires -Version 7.0
<#
.SYNOPSIS
    Re-arms the vuln-lab by restoring its three deliberately vulnerable
    dependency pins and lockfile after a self-healing cycle.

.DESCRIPTION
    L10's self-healing pipeline heals these pins (Dependabot alert -> Claude
    triage -> patch PR -> gauntlet -> auto-merge), which leaves the lab
    disarmed. This script restores the seeded state so the next demo has real
    alerts to heal again:

      1. rewrites apps/vuln-lab/package.json's dependency block to the pinned
         vulnerable versions;
      2. regenerates package-lock.json from those pins (npm install
         --package-lock-only, no packages downloaded);
      3. verifies with `npm audit` that all three advisories are back.

    The script only writes inside apps/vuln-lab. It NEVER commits or pushes:
    per CLAUDE.md the restored pins reach main through a normal PR, which is
    what re-raises the Dependabot alerts.

.PARAMETER WhatIf
    Standard: shows the changes without writing them.

.PARAMETER SkipAudit
    Skip the post-reseed `npm audit` verification (offline use).

.EXAMPLE
    pwsh apps/vuln-lab/reseed.ps1

.EXAMPLE
    pwsh apps/vuln-lab/reseed.ps1 -WhatIf

.NOTES
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

$labRoot = $PSScriptRoot
$manifestPath = Join-Path $labRoot 'package.json'
$lockPath = Join-Path $labRoot 'package-lock.json'

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "vuln-lab manifest not found at $manifestPath"
}

Write-Information "Re-seeding vuln-lab at $labRoot" -InformationAction Continue

# --- 1. restore the vulnerable pins in package.json -------------------------
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

# --- 2. regenerate the lockfile from those pins -----------------------------
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

# --- 3. verify the advisories are back --------------------------------------
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

Write-Information ("vuln-lab re-armed: {0} advisories present ({1})." -f $found.Count, ($found -join ', ')) -InformationAction Continue
Write-Information 'Open a PR with these changes; never push to main directly (CLAUDE.md).' -InformationAction Continue
