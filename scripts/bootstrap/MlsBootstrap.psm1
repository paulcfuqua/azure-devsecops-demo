<#
    Shared bootstrap helpers.

    This module exists because verify-g0.ps1 has to ask GitHub the same question
    01-root-oidc.ps1 asks - which subject will GitHub actually present? - and a second
    copy of that answer is precisely the defect F50 was about: a fact stated twice will
    eventually be stated differently. One implementation, imported by both.
#>

Set-StrictMode -Version Latest

function Get-GitHubSubClaimPrefix {
    <#
        WHAT SUBJECT WILL GITHUB ACTUALLY PRESENT? Ask it, do not construct it.

        This script used to register exactly one subject per app, built by hand as
        "repo:<owner>/<repo>:environment:<env>". On 2026-08-29 the first real OIDC
        login failed against a live tenant with:

          AADSTS700213: No matching federated identity record found for presented
          assertion subject
          'repo:paulcfuqua@51541817/azure-devsecops-demo@1347346268:environment:demo'

        GitHub now embeds IMMUTABLE ACTOR IDENTIFIERS -- the numeric owner id and
        repository id -- in the subject claim, so that renaming an org or repo cannot
        silently redirect a federated trust to someone else. The hand-built string is
        the old shape and no longer matches.

        GitHub reports the prefix it will use at
        GET /repos/{owner}/{repo}/actions/oidc/customization/sub, in `sub_claim_prefix`.
        Note that the tenant this was found on returned `use_immutable_subject: false`
        while still presenting the immutable form -- so DO NOT branch on that flag.
        Read the prefix and trust it.

        Returns $null when the field is absent or gh is unavailable; the caller then
        registers only the classic subject, which is the pre-2026-08-29 behaviour.
    #>
    param([Parameter(Mandatory)][string]$Repository)

    $raw = & gh api "repos/$Repository/actions/oidc/customization/sub" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        Write-Status "  (could not read GitHub's sub_claim_prefix for $Repository; registering the classic subject only)" -Color Yellow
        return $null
    }
    try { $parsed = $raw | ConvertFrom-Json } catch { return $null }
    $prefix = $parsed.sub_claim_prefix
    if ([string]::IsNullOrWhiteSpace($prefix)) { return $null }
    if ($prefix -eq "repo:$Repository") { return $null }   # same as the classic form
    return [string]$prefix
}

Export-ModuleMember -Function Get-GitHubSubClaimPrefix
