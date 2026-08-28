#Requires -Version 7.0
<#
.SYNOPSIS
    L3 Verifier audit - Entra users, groups, CA policies, app registrations. READ-ONLY.

.DESCRIPTION
    Implements the four master-plan Verify criteria owned by
    docs/runbooks/layers/L03.md section Validation cycle, and nothing else:

      V3.1  Graph queries confirm object counts (5 users / 4 groups / 3 app registrations,
            plus a drift sweep for mls-prefixed objects absent from the manifest).
      V3.2  Graph queries confirm group memberships (set equality with the manifest).
      V3.3  CA policy state == enabledForReportingButNotEnforced.
      V3.4  License assignment state == success for every user the manifest flags
            "licensed": true (all 5 during the trial; narrows after expiry).

    The audit never assigns a licence and neither does apply-entra.ps1 - assignment is a
    human step (g0-bootstrap.md C10). V3.4 reports what the tenant actually shows.

    Every expected value comes from infra/entra/manifest.json at the audited commit - the
    audit reads the manifest, not the plan text (L03.md section Validation cycle).

    Graph is read GET-only as mls-verifier: Directory.Read.All for objects, Policy.Read.All
    for the conditional-access read (consented on mls-verifier at G0 precisely so this
    audit can run read-only; a writable Verifier credential would itself be a finding).

.EXAMPLE
    ./layer-03-audit.ps1 -Domain contoso.onmicrosoft.com
#>
[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$Domain,
    [string]$LicenseSkuPartNumber = 'EMSPREMIUM',
    [string]$NamingPrefix = 'mls',
    [string]$ReportRoot,
    [switch]$NoRetry
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'MlsAudit.psm1') -Force

function Get-ManifestUserPrincipalName {
    <# UPNs are composed as <userPrincipalNamePrefix>@<domain>; the manifest domain is a
       placeholder overridden at apply time, so the audit composes them the same way.

       -LicensedOnly narrows the set to users the manifest flags "licensed": true, which is
       what V3.4 asserts against. A user with the property absent counts as licensed, so a
       manifest predating the flag audits exactly as it did before. V3.1/V3.2 deliberately
       do NOT narrow - every declared user must exist and hold its group memberships
       whether or not anyone pays for a seat. #>
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Domain,
        [switch]$LicensedOnly
    )
    $user = @($Manifest.users)
    if ($LicensedOnly) {
        $user = @($user | Where-Object {
                $flag = Get-MlsProperty -InputObject $_ -Name 'licensed'
                $null -eq $flag -or [bool]$flag
            })
    }
    return @($user | ForEach-Object { "$($_.userPrincipalNamePrefix)@$Domain" })
}

function Test-DirectoryObjectCount {
    <# V3.1 - every manifest entry resolves to exactly one directory object, and no
       mls-prefixed group or app exists that the manifest does not declare. #>
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$NamingPrefix
    )
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()

    $userPrincipalName = Get-ManifestUserPrincipalName -Manifest $Manifest -Domain $Domain
    $resolvedUser = 0
    foreach ($upn in $userPrincipalName) {
        $user = Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/users/$upn"
        if ($null -ne $user -and $null -ne (Get-MlsProperty -InputObject $user -Name 'id')) { $resolvedUser++ }
        else { $problem.Add("user '$upn' did not resolve") }
    }
    $observed.Add("users $resolvedUser/$(@($userPrincipalName).Count)")

    $resolvedGroup = 0
    foreach ($group in $Manifest.groups) {
        $found = Get-MlsCollection -Response (Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$($group.displayName)'")
        if (@($found).Count -eq 1) { $resolvedGroup++ } else { $problem.Add("group '$($group.displayName)' resolved to $(@($found).Count) objects") }
    }
    $observed.Add("groups $resolvedGroup/$(@($Manifest.groups).Count)")

    $resolvedApplication = 0
    foreach ($application in $Manifest.appRegistrations) {
        $found = Get-MlsCollection -Response (Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$($application.displayName)'")
        if (@($found).Count -eq 1) { $resolvedApplication++ } else { $problem.Add("app registration '$($application.displayName)' resolved to $(@($found).Count) objects") }
    }
    $observed.Add("appRegistrations $resolvedApplication/$(@($Manifest.appRegistrations).Count)")

    # Drift sweep: mls-prefixed groups/apps that the manifest does not declare.
    $manifestGroupName = @($Manifest.groups | ForEach-Object { $_.displayName })
    $liveGroup = @(Get-MlsCollection -Response (Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=startswith(displayName,'$NamingPrefix')") |
            ForEach-Object { Get-MlsProperty -InputObject $_ -Name 'displayName' })
    $extraGroup = @($liveGroup | Where-Object { $_ -and $_ -notin $manifestGroupName })
    $manifestApplicationName = @($Manifest.appRegistrations | ForEach-Object { $_.displayName })
    $liveApplication = @(Get-MlsCollection -Response (Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=startswith(displayName,'$NamingPrefix')") |
            ForEach-Object { Get-MlsProperty -InputObject $_ -Name 'displayName' })
    $extraApplication = @($liveApplication | Where-Object {
            $_ -and $_ -notin $manifestApplicationName -and $_ -notin @('mls-github-deployer', 'mls-verifier')
        })
    if ($extraGroup.Count -gt 0) { $problem.Add("drift - $NamingPrefix-prefixed groups absent from the manifest: $($extraGroup -join ', ')") }
    if ($extraApplication.Count -gt 0) { $problem.Add("drift - $NamingPrefix-prefixed app registrations absent from the manifest: $($extraApplication -join ', ')") }

    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ')
    }
    return New-MlsCheckResult -Passed $false -Observed (($observed -join '; ') + ' | ' + ($problem -join ' | ')) `
        -Detail 'Entra object propagation can lag 15-45 min (spec F6); partial counts that increase between polls are the propagation case this window exists for.'
}

function Test-GroupMembership {
    <# V3.2 - each group's member set equals the manifest's list exactly. #>
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Domain
    )
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()
    foreach ($group in $Manifest.groups) {
        $found = Get-MlsCollection -Response (Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$($group.displayName)'")
        if (@($found).Count -ne 1) {
            $problem.Add("group '$($group.displayName)' resolved to $(@($found).Count) objects")
            continue
        }
        $groupId = Get-MlsProperty -InputObject $found[0] -Name 'id'
        $member = @(Get-MlsCollection -Response (Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members") |
                ForEach-Object { Get-MlsProperty -InputObject $_ -Name 'userPrincipalName' })
        $expected = @($group.members | ForEach-Object { "$_@$Domain" })
        $comparison = Test-MlsSetEquality -Actual $member -Expected $expected
        $observed.Add("$($group.displayName): $(@($member).Count) member(s)")
        if (-not $comparison.Equal) {
            $problem.Add("$($group.displayName) missing [$($comparison.Missing -join ', ')] extra [$($comparison.Extra -join ', ')]")
        }
    }
    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ')
    }
    return New-MlsCheckResult -Passed $false -Observed ($problem -join ' | ') `
        -Detail 'Set equality: a missing member and an extra member both fail (L03.md V3.2).'
}

function Test-ConditionalAccessState {
    <# V3.3 - both policies present and report-only. A visible-but-wrong state fails
       immediately: that is not a propagation artifact (L03.md V3.3). #>
    param([Parameter(Mandatory)]$Manifest)
    $expectedState = 'enabledForReportingButNotEnforced'
    $expectedName = @($Manifest.conditionalAccessPolicies | ForEach-Object { $_.displayName })
    $policies = Get-MlsCollection -Response (Invoke-MlsGraph -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies')
    $relevant = @($policies | Where-Object { (Get-MlsProperty -InputObject $_ -Name 'displayName') -in $expectedName })
    $observed = @($relevant | ForEach-Object {
            "$(Get-MlsProperty -InputObject $_ -Name 'displayName')=$(Get-MlsProperty -InputObject $_ -Name 'state')"
        })
    if ($relevant.Count -ne @($expectedName).Count) {
        return New-MlsCheckResult -Passed $false `
            -Observed "$($relevant.Count) of $(@($expectedName).Count) manifest CA policies visible: $($observed -join ', ')" `
            -Detail 'CA propagation can take up to 45 min worst case; the audit retries inside the standard 30-minute window.'
    }
    $wrong = @($relevant | Where-Object { (Get-MlsProperty -InputObject $_ -Name 'state') -ne $expectedState })
    if ($wrong.Count -gt 0) {
        $enforced = @($wrong | Where-Object { (Get-MlsProperty -InputObject $_ -Name 'state') -eq 'enabled' })
        $detail = 'Wrong state is not a propagation artifact - failing immediately (L03.md V3.3).'
        if ($enforced.Count -gt 0) {
            $detail = 'SAFETY FLAG: a CA policy is ENFORCED (state=enabled) in the demo tenant. L03 rollback exception: the lead may converge it back to report-only immediately, before any other analysis - tenant lockout is the blast radius.'
        }
        return New-MlsCheckResult -Passed $false -Observed ($observed -join ', ') -Detail $detail -Final
    }
    return New-MlsCheckResult -Passed $true -Observed ($observed -join ', ')
}

function Test-LicenseAssignment {
    <# V3.4 - EMS E5 assignment Active with no error, for every user the manifest flags
       licensed. That set is all five while the trial's free seats last; after expiry it
       narrows to whoever is still signed in as on stage. Users deliberately left
       unlicensed are not a finding - an unlicensed demo persona still exists, still holds
       its group memberships (V3.1/V3.2), and still sits in the report-only CA scope. What
       it loses is sign-in risk and enforced CA, which is a licensing fact, not drift. #>
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$LicenseSkuPartNumber
    )
    $target = Get-ManifestUserPrincipalName -Manifest $Manifest -Domain $Domain -LicensedOnly
    if ($target.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed 'no manifest user is flagged licensed - nothing to assert' `
            -Detail 'Every user carries "licensed": false, so the demo is running fully unlicensed: no sign-in risk feed and no enforceable CA. Deliberate after trial expiry; if it is not deliberate, the flags are wrong.'
    }
    $skus = Get-MlsCollection -Response (Invoke-MlsGraph -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus')
    $sku = @($skus | Where-Object { (Get-MlsProperty -InputObject $_ -Name 'skuPartNumber') -eq $LicenseSkuPartNumber })
    if ($sku.Count -eq 0) {
        return New-MlsCheckResult -Passed $false -Observed "SKU '$LicenseSkuPartNumber' is not present on the tenant" `
            -Detail 'L03 failure mode 2: trial not activated, or the SKU was never added. Human action in the M365 admin center.'
    }
    $skuId = Get-MlsProperty -InputObject $sku[0] -Name 'skuId'
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()
    foreach ($upn in $target) {
        $user = Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/users/$upn`?`$select=licenseAssignmentStates"
        $states = @(Get-MlsProperty -InputObject $user -Name 'licenseAssignmentStates')
        $relevant = @($states | Where-Object { (Get-MlsProperty -InputObject $_ -Name 'skuId') -eq $skuId })
        if ($relevant.Count -eq 0) {
            $problem.Add("$upn has no $LicenseSkuPartNumber assignment")
            continue
        }
        $state = Get-MlsProperty -InputObject $relevant[0] -Name 'state'
        $assignmentError = Get-MlsProperty -InputObject $relevant[0] -Name 'error'
        $observed.Add("$upn=$state")
        if ($state -ne 'Active') { $problem.Add("$upn state '$state'") }
        if ($assignmentError -and "$assignmentError" -notin @('None', '')) { $problem.Add("$upn error '$assignmentError'") }
    }
    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ')
    }
    return New-MlsCheckResult -Passed $false -Observed ($problem -join ' | ') `
        -Detail 'Group-based licensing is asynchronous - the full 30-minute window applies. CountViolation means the seat pool is exhausted (L03 failure mode 2).'
}

function Invoke-Main {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is consumed inside the criterion scriptblocks; PSSA cannot see through scriptblock closures.')]
    param(
        [string]$ManifestPath,
        [string]$Domain,
        [string]$LicenseSkuPartNumber = 'EMSPREMIUM',
        [string]$NamingPrefix = 'mls',
        [string]$ReportRoot,
        [switch]$NoRetry
    )
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $manifestFile = Resolve-MlsInput -Name 'ManifestPath' -Value $ManifestPath -EnvironmentVariable @('MLS_ENTRA_MANIFEST') `
        -DefaultValue (Join-Path -Path $repoRoot -ChildPath 'infra' -AdditionalChildPath 'entra', 'manifest.json') `
        -Hint 'The identity manifest is the source of every expected value in this audit.'
    $manifest = Get-MlsJsonFile -Path $manifestFile -Purpose 'L3 identity manifest - the audit reads the manifest, not the plan text'

    $manifestDomain = "$(Get-MlsProperty -InputObject $manifest -Name 'domain')"
    $domainDefault = ''
    if ($manifestDomain -and $manifestDomain -ne 'mls.example') { $domainDefault = $manifestDomain }
    $tenantDomain = Resolve-MlsInput -Name 'Domain' -Value $Domain -EnvironmentVariable @('MLS_TENANT_DOMAIN', 'TENANT_DOMAIN') `
        -DefaultValue $domainDefault `
        -Hint "The tenant's verified domain. UPNs are composed as <prefix>@<domain>; the manifest ships the placeholder 'mls.example', which apply-entra.ps1 overrides at apply time, so the audit cannot guess it."

    $context = New-MlsAuditContext -Layer 3 -Title 'Entra layer: users, groups, CA, app registrations' `
        -ScriptName 'verification/layer-03-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry
    Add-MlsPreflight -Context $context -Name 'Manifest' -Value $manifestFile
    Add-MlsPreflight -Context $context -Name 'Tenant domain' -Value $tenantDomain
    Add-MlsPreflight -Context $context -Name 'Manifest shape' `
        -Value "$(@($manifest.users).Count) users / $(@($manifest.groups).Count) groups / $(@($manifest.appRegistrations).Count) app registrations / $(@($manifest.conditionalAccessPolicies).Count) CA policies"

    Invoke-MlsCriterion -Context $context -Id 'V3.1' -Control @('3.1.1', '3.5.1') `
        -Description 'Graph queries confirm object counts' `
        -Command "GET /v1.0/users/<upn> for each manifest user`nGET /v1.0/groups?`$filter=displayName eq '<name>'`nGET /v1.0/applications?`$filter=displayName eq '<name>'`nGET /v1.0/groups?`$filter=startswith(displayName,'$NamingPrefix')  # drift sweep" `
        -Expected "$(@($manifest.users).Count) users, $(@($manifest.groups).Count) groups, $(@($manifest.appRegistrations).Count) app registrations - each manifest entry resolving to exactly one object, zero $NamingPrefix-prefixed extras" `
        -Test { Test-DirectoryObjectCount -Manifest $manifest -Domain $tenantDomain -NamingPrefix $NamingPrefix } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V3.2' -Control @('3.1.1', '3.1.2') `
        -Description 'Graph queries confirm group memberships' `
        -Command "GET /v1.0/groups/<id>/members for each manifest group" `
        -Expected "each group's member set equals the manifest's member list exactly (set equality)" `
        -Test { Test-GroupMembership -Manifest $manifest -Domain $tenantDomain } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V3.3' -Control @('3.5.3', '3.5.4') `
        -Description 'CA policy state == enabledForReportingButNotEnforced' `
        -Command 'GET /v1.0/identity/conditionalAccess/policies  # Policy.Read.All, read-only' `
        -Expected 'both manifest CA policies present with State == enabledForReportingButNotEnforced' `
        -Test { Test-ConditionalAccessState -Manifest $manifest } | Out-Null

    $licensedUser = Get-ManifestUserPrincipalName -Manifest $manifest -Domain $tenantDomain -LicensedOnly
    # -Control @(): license assignment is an entitlement/billing precondition for identity
    # features (Conditional Access, Identity Protection) to be available, not itself an
    # implemented protection. What those features do is evidenced directly by V3.3;
    # licence state alone would over-claim if mapped to the identification/authentication
    # requirements those features realize.
    Invoke-MlsCriterion -Context $context -Id 'V3.4' -Control @() `
        -Description "License assignment state == success for all $($licensedUser.Count) licensed of $(@($manifest.users).Count)" `
        -Command "GET /v1.0/subscribedSkus`nGET /v1.0/users/<upn>?`$select=licenseAssignmentStates" `
        -Expected "each of the $($licensedUser.Count) manifest user(s) flagged licensed carries the $LicenseSkuPartNumber assignment with State == Active and no error" `
        -Test { Test-LicenseAssignment -Manifest $manifest -Domain $tenantDomain -LicenseSkuPartNumber $LicenseSkuPartNumber } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -ManifestPath $ManifestPath -Domain $Domain `
            -LicenseSkuPartNumber $LicenseSkuPartNumber -NamingPrefix $NamingPrefix `
            -ReportRoot $ReportRoot -NoRetry:$NoRetry
    }
    catch {
        Write-MlsStatus -Message "layer-03-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
