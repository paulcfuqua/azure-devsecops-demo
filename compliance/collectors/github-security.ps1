#Requires -Version 7.0
<#
.SYNOPSIS
    The github-security collector (spec section 4, plan Task 7): evidence from a real
    repository's GHAS posture - genuine external state, not repository intent.

.DESCRIPTION
    Unlike repo-static, this collector reports on what GitHub itself says is configured
    for the repository (the `security_and_analysis` block of `GET /repos/{owner}/{repo}`),
    not what a workflow or Bicep file merely declares. It never calls the network itself:
    -Response takes an already-deserialised API response so every test runs offline, and a
    real caller (a future scheduled job, never this plan) is the one place that would call
    `gh api repos/:owner/:repo` and hand the parsed JSON in here.

    TWO CONTROLS, TWO INDEPENDENT CHECKS
    -----------------------------------------
    - 3.13.16: secret scanning AND push protection must both be 'enabled'. Either one
      missing or not 'enabled' is a gap; either one simply absent from the response is
      inconclusive - a field that is not there is not the same finding as a field that is
      explicitly 'disabled'.
    - 3.14.1: Dependabot security updates must be 'enabled'.

    These run as two independent try/catch blocks (not one), so a problem reading one
    does not cost the other its record - the shape of "a malformed input does not lose
    the rest" for a collector whose single response covers more than one control.

    A MISSING OR UNREADABLE RESPONSE NEVER PASSES
    ---------------------------------------------------
    No -Response (the source is unreachable, or this is a pre-G0 run with nothing to
    call), or a response with no `security_and_analysis` block at all, returns no evidence
    - never a pass, and never a fabricated inconclusive record either, since there is
    nothing to attribute it to.

.PARAMETER Response
    The deserialised `GET /repos/{owner}/{repo}` response (or an equivalent object
    carrying a `security_and_analysis` block). $null when the source was not queried or is
    unreachable.

.OUTPUTS
    Zero or more validated EvidenceRecord objects (compliance/collectors/
    CollectorContract.psm1), each with `source` = 'github-security' and
    `criterion` = $null.
#>
[CmdletBinding()]
param(
    [object]$Response = $null
)

Set-StrictMode -Version Latest

$script:CollectorName = 'github-security'
$script:Response = $Response

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'CollectorContract.psm1') -Force
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'verification', 'MlsAudit.psm1') -Force

function Get-MlsGitHubSecurityStatusText {
    <#
    .SYNOPSIS
        Trimmed lower-case status text from a `{ status: "..." }` sub-block, or $null.
    #>
    param($Block)
    $status = Get-MlsProperty -InputObject $Block -Name 'status'
    if ($null -eq $status) { return $null }
    $text = "$status".Trim()
    if ($text.Length -eq 0) { return $null }
    return $text.ToLowerInvariant()
}

Invoke-MlsCollector -Name $script:CollectorName -ScriptBlock {

    if ($null -eq $script:Response) {
        Write-Verbose "github-security: no response supplied; returning no evidence."
        return
    }

    $securityAndAnalysis = Get-MlsProperty -InputObject $script:Response -Name 'security_and_analysis'
    if ($null -eq $securityAndAnalysis) {
        Write-Verbose "github-security: response has no security_and_analysis block; returning no evidence."
        return
    }

    # --- 3.13.16: secret scanning + push protection, independently of the check below ---
    try {
        $secretScanning = Get-MlsGitHubSecurityStatusText (Get-MlsProperty -InputObject $securityAndAnalysis -Name 'secret_scanning')
        $pushProtection = Get-MlsGitHubSecurityStatusText (Get-MlsProperty -InputObject $securityAndAnalysis -Name 'secret_scanning_push_protection')

        $status = if ($null -eq $secretScanning -or $null -eq $pushProtection) {
            'inconclusive'
        }
        elseif ($secretScanning -eq 'enabled' -and $pushProtection -eq 'enabled') {
            'pass'
        }
        else {
            'fail'
        }

        New-MlsEvidence -Control '3.13.16' -Source $script:CollectorName -Status $status `
            -Observed "GitHub security_and_analysis: secret_scanning=$(if ($null -eq $secretScanning) { '(absent)' } else { $secretScanning }), secret_scanning_push_protection=$(if ($null -eq $pushProtection) { '(absent)' } else { $pushProtection })."
    }
    catch {
        Write-Warning "github-security: secret scanning / push protection check failed - $($_.Exception.Message)"
    }

    # --- 3.14.1: Dependabot security updates, independently of the check above -----------
    try {
        $dependabot = Get-MlsGitHubSecurityStatusText (Get-MlsProperty -InputObject $securityAndAnalysis -Name 'dependabot_security_updates')

        $status = switch ($dependabot) {
            'enabled' { 'pass' }
            'disabled' { 'fail' }
            default { 'inconclusive' }
        }

        New-MlsEvidence -Control '3.14.1' -Source $script:CollectorName -Status $status `
            -Observed "GitHub security_and_analysis: dependabot_security_updates=$(if ($null -eq $dependabot) { '(absent)' } else { $dependabot })."
    }
    catch {
        Write-Warning "github-security: Dependabot security updates check failed - $($_.Exception.Message)"
    }
}
