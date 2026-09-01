#Requires -Version 7.0
<#
.SYNOPSIS
    L3 Verifier audit - Entra users, groups, CA policies, app registrations. READ-ONLY.

.DESCRIPTION
    Implements the four master-plan Verify criteria owned by
    docs/runbooks/layers/L03.md section Validation cycle, and nothing else:

      V3.1  Graph queries confirm object counts - every users/groups/appRegistrations entry
            in the manifest, whatever the manifest currently holds, plus a drift sweep for
            mls-prefixed objects absent from it.
      V3.2  Graph queries confirm group memberships (set equality with the manifest).
      V3.3  Each CA policy is live in the state the manifest declares - the two broad
            All-users/All-applications policies report-only, mls-ca-require-mfa-dashboards
            ENFORCED - and the enforced one really does require MFA, on exactly the three
            dashboard applications, with a populated break-glass exclusion behind it.
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
    # The service plans L3's own features need: Entra ID Premium (Conditional Access) and
    # MFA. Any bundle that provisions these satisfies V3.4, whatever it is called (F73).
    [string[]]$RequiredServicePlan = @('AAD_PREMIUM', 'MFA_PREMIUM'),
    [string]$NamingPrefix = 'mls',
    [string]$ReportRoot,
    [switch]$NoRetry,
    # Run only these criteria (e.g. -OnlyCriterion V3.2). Everything else reports SKIP
    # naming the reason, and the run exits 3 - a DIAGNOSTIC, never a sign-off (P-10).
    [string[]]$OnlyCriterion = @()
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

    $userPrincipalName = @(Get-ManifestUserPrincipalName -Manifest $Manifest -Domain $Domain)
    $resolvedUser = 0
    foreach ($upn in $userPrincipalName) {
        $user = Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/users/$upn"
        if ($null -ne $user -and $null -ne (Get-MlsProperty -InputObject $user -Name 'id')) { $resolvedUser++ }
        else { $problem.Add("user '$upn' did not resolve") }
    }
    $observed.Add("users $resolvedUser/$(@($userPrincipalName).Count)")

    $resolvedGroup = 0
    foreach ($group in $Manifest.groups) {
        $found = @(Get-MlsCollection -Response (Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$($group.displayName)'"))
        if (@($found).Count -eq 1) { $resolvedGroup++ } else { $problem.Add("group '$($group.displayName)' resolved to $(@($found).Count) objects") }
    }
    $observed.Add("groups $resolvedGroup/$(@($Manifest.groups).Count)")

    $resolvedApplication = 0
    foreach ($application in $Manifest.appRegistrations) {
        $found = @(Get-MlsCollection -Response (Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$($application.displayName)'"))
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
    <# V3.2 - each group's member set equals the manifest's list exactly.

       EXCEPT a group flagged "breakGlass": true, whose membership is deliberately NOT in
       the manifest: an emergency-access account is a real human credential and must never
       be one of the fictional personas this file declares (CLAUDE.md rule 4), so a human
       adds it out of band. Asserting set equality there would fail the moment the account
       an adopter is REQUIRED to create actually exists. Its membership is not unchecked -
       V3.3 asserts the stronger property, that the group holds a usable emergency-access
       account, because that is what makes the enforced MFA policy safe to turn on.

       AND EXCEPT "membershipManagedExternally": true, which is the same reasoning applied
       to groups that hold identities the repo cannot name: the operator who authors the
       Copilot Studio agent, and the human plus deploy service principal that make up the
       Azure SQL Entra admin. Both were reported as drift the first time this ran against a
       tenant where they existed, and both times the manifest was wrong rather than the
       tenant (F92).

       THESE ARE NOT SKIPPED. Set equality against an empty list asserts the group must be
       EMPTY, which is the opposite of what is wanted: a copilot-authors group with no
       members grants nobody anything, and an empty SQL admin group means nobody can
       administer the database. So the assertion becomes NON-EMPTY - weaker than naming the
       members, stronger than requiring there be none, and the only one that is true. #>
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Domain
    )
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()
    foreach ($group in $Manifest.groups) {
        if (Get-MlsProperty -InputObject $group -Name 'breakGlass') {
            $observed.Add("$($group.displayName): membership managed outside the manifest (break-glass; asserted by V3.3)")
            continue
        }
        $found = @(Get-MlsCollection -Response (Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$($group.displayName)'"))
        if (@($found).Count -ne 1) {
            $problem.Add("group '$($group.displayName)' resolved to $(@($found).Count) objects")
            continue
        }
        $groupId = Get-MlsProperty -InputObject $found[0] -Name 'id'
        $rawMember = @(Get-MlsCollection -Response (Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members"))
        if (Get-MlsProperty -InputObject $group -Name 'membershipManagedExternally') {
            # Counted RAW, not by userPrincipalName: a service principal is a legitimate
            # member of the SQL admin group and carries no UPN, so filtering by one would
            # read a correctly-populated group as empty.
            if (@($rawMember).Count -lt 1) {
                $problem.Add("$($group.displayName) is empty; its membership is managed outside the manifest, but a group with no members grants nothing")
            }
            else {
                $observed.Add("$($group.displayName): $(@($rawMember).Count) member(s), managed outside the manifest")
            }
            continue
        }
        $member = @($rawMember | ForEach-Object { Get-MlsProperty -InputObject $_ -Name 'userPrincipalName' })
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

function Get-MlsDirectoryObjectId {
    <# The id Conditional Access addresses an object by, resolved from its display name:
       `appId` for an application (NOT the directory object id), `id` for a group. Null
       unless exactly one object matches - two matches is an ambiguity, not a lookup. #>
    param(
        [Parameter(Mandatory)][string]$Resource,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Property
    )
    $found = @(Get-MlsCollection -Response (Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/$Resource`?`$filter=displayName eq '$DisplayName'"))
    if (@($found).Count -ne 1) { return $null }
    return Get-MlsProperty -InputObject $found[0] -Name $Property
}

function Test-EnforcedCaPolicy {
    <# The content assertions that only apply to a policy the manifest declares `enabled`.
       Appends to $Problem; returns a short Observed fragment. Split out because V3.3's
       two halves are genuinely different questions asked of the same Graph read. #>
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$Declared,
        [Parameter(Mandatory)]$Live,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Problem,
        [Parameter(Mandatory)][string]$Domain
    )
    $name = $Declared.displayName
    $note = [System.Collections.Generic.List[string]]::new()
    # Read the manifest's own optional keys through Get-MlsProperty, never by dotted
    # access: this script runs under Set-StrictMode -Version Latest, where a missing
    # property THROWS, and a manifest that declares `enabled` without naming applications
    # or a break-glass exclusion has to produce a legible finding rather than a stack
    # trace. (apply-entra.ps1 refuses to apply such a manifest; the audit still has to
    # describe one honestly if it meets it.)
    $declaredConditions = Get-MlsProperty -InputObject $Declared -Name 'conditions'
    $declaredApplications = Get-MlsProperty -InputObject $declaredConditions -Name 'applications'
    $declaredUsers = Get-MlsProperty -InputObject $declaredConditions -Name 'users'

    # --- the grant itself ---------------------------------------------------------
    $grant = Get-MlsProperty -InputObject $Live -Name 'grantControls'
    $builtIn = @(Get-MlsProperty -InputObject $grant -Name 'builtInControls')
    if ($builtIn -notcontains 'mfa') {
        $Problem.Add("$name grants [$($builtIn -join ', ')] - not mfa")
    }
    else { $note.Add('mfa') }

    # --- scope: exactly the declared applications, and never 'All' -----------------
    $conditions = Get-MlsProperty -InputObject $Live -Name 'conditions'
    $liveApplication = @(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $conditions -Name 'applications') -Name 'includeApplications')
    # Where-Object { $_ } because @(Get-MlsProperty ...) on an ABSENT key is a one-element
    # array holding $null, not an empty one. That is a plain PowerShell unrolling rule and
    # is still live - distinct from the Get-MlsCollection wrapper bug commit 918e475 fixed
    # in the module itself.
    $declaredName = @(Get-MlsProperty -InputObject $declaredApplications -Name 'includeApplicationsByDisplayName' |
            Where-Object { $_ })
    $expectedId = @($declaredName | ForEach-Object { Get-MlsDirectoryObjectId -Resource 'applications' -DisplayName $_ -Property 'appId' })
    if ($liveApplication -contains 'All') {
        $Problem.Add("$name is ENFORCED against every application ('All') - it must name the applications it covers")
    }
    elseif ($declaredName.Count -eq 0) {
        $Problem.Add("$name is ENFORCED but the manifest names no application for it to cover")
    }
    elseif (@($expectedId | Where-Object { $_ }).Count -ne $declaredName.Count) {
        $Problem.Add("${name}: could not resolve every declared application ($($declaredName -join ', ')) to an appId")
    }
    else {
        $comparison = Test-MlsSetEquality -Actual $liveApplication -Expected $expectedId
        if (-not $comparison.Equal) {
            $Problem.Add("${name} application scope missing [$($comparison.Missing -join ', ')] extra [$($comparison.Extra -join ', ')]")
        }
        else { $note.Add("$($declaredName.Count) app(s)") }
    }

    # --- the break-glass exclusion, and whether it is worth anything ---------------
    # An exclusion pointing at an EMPTY group is not an emergency-access path; it just
    # looks like one. So the group is read, and its members have to be real: a fictional
    # demo persona is nobody's credential, and an on-premises-synced account takes the
    # recovery path down with whatever it syncs from.
    $liveExclusion = @(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $conditions -Name 'users') -Name 'excludeGroups')
    $breakGlassName = @($Manifest.groups | Where-Object { Get-MlsProperty -InputObject $_ -Name 'breakGlass' } |
            ForEach-Object { $_.displayName })
    $declaredExclusion = @(Get-MlsProperty -InputObject $declaredUsers -Name 'excludeGroupsByDisplayName' |
            Where-Object { $breakGlassName -contains $_ })
    if ($declaredExclusion.Count -eq 0) {
        $Problem.Add("$name declares no break-glass group exclusion in the manifest")
        return ($note -join '; ')
    }
    $excluded = 0
    $emergencyAccount = 0
    $personaUpn = @($Manifest.users | ForEach-Object { "$($_.userPrincipalNamePrefix)@$Domain" })
    foreach ($groupName in $declaredExclusion) {
        $groupId = Get-MlsDirectoryObjectId -Resource 'groups' -DisplayName $groupName -Property 'id'
        if (-not $groupId) { $Problem.Add("$name excludes '$groupName', which does not resolve to exactly one group"); continue }
        if ($liveExclusion -notcontains $groupId) {
            $Problem.Add("$name does NOT exclude break-glass group '$groupName' - an enforced policy with no emergency-access exclusion can lock the tenant owner out")
            continue
        }
        $excluded++
        $member = @(Get-MlsCollection -Response (Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members?`$select=id,userPrincipalName,onPremisesSyncEnabled"))
        foreach ($entry in $member) {
            # A non-empty UPN is what makes this a user account at all - a group or a
            # service principal in the break-glass group is not an emergency-access
            # credential a human can sign in with.
            #
            # It is also belt-and-braces over a bug this check found: Get-MlsCollection
            # used to return the response WRAPPER for an empty {value:[]}, so an empty
            # break-glass group read as holding one member and the exclusion passed its
            # own emergency-access check with nobody behind it. Fixed at the source in
            # commit 918e475 (Test-MlsHasProperty tests for the key, not a non-null
            # value), so this guard is no longer load-bearing for that case - it stays
            # because the UPN test is right on its own terms and because failing closed
            # here is cheap.
            $upn = "$(Get-MlsProperty -InputObject $entry -Name 'userPrincipalName')"
            if ([string]::IsNullOrWhiteSpace($upn)) { continue }
            if ($personaUpn -contains $upn) { continue }
            if ((Get-MlsProperty -InputObject $entry -Name 'onPremisesSyncEnabled') -eq $true) { continue }
            $emergencyAccount++
        }
    }
    if ($excluded -gt 0 -and $emergencyAccount -eq 0) {
        $Problem.Add("$name excludes [$($declaredExclusion -join ', ')] but no such group holds a cloud-only emergency-access account - the exclusion protects nobody")
    }
    if ($excluded -gt 0 -and $emergencyAccount -gt 0) {
        $note.Add("break-glass $($declaredExclusion -join ', '): $emergencyAccount account(s)")
    }
    return ($note -join '; ')
}

function Test-ConditionalAccessState {
    <# V3.3 - every manifest CA policy is live in the state the MANIFEST declares, and the
       one policy declared `enabled` really does enforce what it claims to.

       Two assertions, two different reasons, one Graph read:

       * the two broad policies (All users / All applications) must stay report-only.
         Enforcing an All/All grant in an adopter's tenant is a lockout, not a demo, so a
         live `enabled` there is a SAFETY FLAG rather than a finding to analyse later.
       * mls-ca-require-mfa-dashboards must be ENFORCED, grant `mfa`, cover exactly the
         dashboard applications the manifest names (never 'All'), and exclude a break-glass
         group that actually holds an emergency-access account.

       A visible-but-wrong state fails immediately: that is not a propagation artifact
       (L03.md V3.3). A policy or object not visible YET is retried. #>
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Domain
    )
    $declared = @($Manifest.conditionalAccessPolicies)
    $expectedName = @($declared | ForEach-Object { $_.displayName })
    $policies = @(Get-MlsCollection -Response (Invoke-MlsGraph -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies'))
    $relevant = @($policies | Where-Object { (Get-MlsProperty -InputObject $_ -Name 'displayName') -in $expectedName })
    $observed = @($relevant | ForEach-Object {
            "$(Get-MlsProperty -InputObject $_ -Name 'displayName')=$(Get-MlsProperty -InputObject $_ -Name 'state')"
        })
    if ($relevant.Count -ne @($expectedName).Count) {
        # MFA ENFORCEMENT IS THE CONTROL. AN ENABLED CA POLICY IS ONE WAY TO GET IT.
        #
        # This criterion maps to 3.5.3, which asks whether multifactor authentication is
        # enforced - not whether a particular mechanism is present. Microsoft ships Security
        # Defaults precisely to enforce MFA on tenants that have not built Conditional Access
        # yet, and Graph REFUSES an enabled CA policy while they are on. So on a default
        # tenant - which is every new tenant, and therefore most adopters - this criterion
        # failed against an estate whose MFA was, in fact, enforced (F78).
        #
        # Making that green by disabling Security Defaults would be reasoning backwards from
        # the test: this manifest enforces only the dashboard policy, so the trade would take
        # baseline MFA from every user and give back one policy (F75). The criterion was
        # asserting the artefact where the control is the capability - the same error
        # [F77] found in the break-glass check, one level up.
        $securityDefaults = Invoke-MlsGraph -Uri 'https://graph.microsoft.com/v1.0/policies/identitySecurityDefaultsEnforcementPolicy'
        $defaultsOn = [bool](Get-MlsProperty -InputObject $securityDefaults -Name 'isEnabled')
        $missing = @($expectedName | Where-Object { $_ -notin @($relevant | ForEach-Object { Get-MlsProperty -InputObject $_ -Name 'displayName' }) })
        $enforcedMissing = @($declared | Where-Object { $_.state -eq 'enabled' -and $_.displayName -in $missing })

        if ($defaultsOn -and $enforcedMissing.Count -eq $missing.Count -and $missing.Count -gt 0) {
            # Only the ENFORCED policies are absent, and Security Defaults explain exactly
            # that. The report-only policies are present and auditable; MFA is enforced by a
            # different mechanism, and the estate declined to weaken it.
            return New-MlsCheckResult -Passed $true `
                -Observed "MFA is enforced by Security Defaults; $($relevant.Count) of $(@($expectedName).Count) manifest CA policies are live ($($observed -join ', ')). The enforced polic(y/ies) $($enforcedMissing.displayName -join ', ') were refused because Graph will not accept an enabled CA policy alongside Security Defaults." `
                -Detail 'Control 3.5.3 asks whether MFA is enforced, and it is. Do not disable Security Defaults to create these policies: this manifest enforces only the dashboard policy, so the tenant would lose baseline MFA for every user (F75). To move to Conditional Access properly, raise the broad policies to enabled in the manifest FIRST, register MFA for the accounts they scope, then disable Security Defaults.'
        }

        return New-MlsCheckResult -Passed $false `
            -Observed "$($relevant.Count) of $(@($expectedName).Count) manifest CA policies visible: $($observed -join ', ')$(if ($defaultsOn) { ' [Security Defaults: ON]' })" `
            -Detail 'CA propagation can take up to 45 min worst case; the audit retries inside the standard 30-minute window. An enforced policy the apply script REFUSED to create (no break-glass account) also lands here - see docs/runbooks/g0-bootstrap.md item 13.'
    }

    $problem = [System.Collections.Generic.List[string]]::new()
    $safetyFlag = $false
    $detail = [System.Collections.Generic.List[string]]::new()
    foreach ($policy in $declared) {
        $live = @($relevant | Where-Object { (Get-MlsProperty -InputObject $_ -Name 'displayName') -eq $policy.displayName })[0]
        $liveState = "$(Get-MlsProperty -InputObject $live -Name 'state')"
        if ($liveState -ne $policy.state) {
            $problem.Add("$($policy.displayName) is '$liveState', manifest declares '$($policy.state)'")
            if ($liveState -eq 'enabled') { $safetyFlag = $true }
            continue
        }
        if ($policy.state -ne 'enabled') { continue }
        $note = Test-EnforcedCaPolicy -Manifest $Manifest -Declared $policy -Live $live -Problem $problem -Domain $Domain
        if ($note) { $detail.Add("$($policy.displayName) ($note)") }
    }

    if ($problem.Count -eq 0) {
        $summary = $observed -join ', '
        if ($detail.Count -gt 0) { $summary += ' | ' + ($detail -join '; ') }
        return New-MlsCheckResult -Passed $true -Observed $summary
    }

    $why = 'Wrong state or scope is not a propagation artifact - failing immediately (L03.md V3.3).'
    if ($safetyFlag) {
        $why = 'SAFETY FLAG: a CA policy the manifest declares REPORT-ONLY is ENFORCED (state=enabled) in this tenant. L03 rollback exception: the lead may converge it back to report-only immediately, before any other analysis - tenant lockout is the blast radius. (mls-ca-require-mfa-dashboards is deliberately enforced and is not this case.)'
    }
    return New-MlsCheckResult -Passed $false -Observed (($observed -join ', ') + ' | ' + ($problem -join ' | ')) -Detail $why -Final
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
        [Parameter(Mandatory)][string]$LicenseSkuPartNumber,
        [string[]]$RequiredServicePlan = @('AAD_PREMIUM', 'MFA_PREMIUM')
    )
    $target = @(Get-ManifestUserPrincipalName -Manifest $Manifest -Domain $Domain -LicensedOnly)
    if ($target.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed 'no manifest user is flagged licensed - nothing to assert' `
            -Detail 'Every user carries "licensed": false, so the demo is running fully unlicensed: no sign-in risk feed and no enforceable CA. Deliberate after trial expiry; if it is not deliberate, the flags are wrong.'
    }
    # MATCH THE CAPABILITY, NOT THE BUNDLE NAME.
    #
    # This asked "is a SKU literally called EMSPREMIUM present" when what L3 needs is
    # "are these users licensed for the Entra features it deploys" - Conditional Access and
    # MFA, which are the AAD_PREMIUM* and MFA_PREMIUM service plans. A tenant on Microsoft
    # 365 E5 (SPE_E5) has every one of them and would have failed this check, because E5 is
    # a superset that does not contain the substring EMSPREMIUM anywhere (F73).
    #
    # A bundle name is a constant naming something in another system, and CLAUDE.md says
    # those are resolved against that system rather than written from memory. Microsoft sells
    # these capabilities under many names and adds more; enumerating the bundles is a list
    # that goes stale. The service plans are what the features actually key on.
    $skus = @(Get-MlsCollection -Response (Invoke-MlsGraph -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus'))

    # Named exactly, in preference order: an explicit -LicenseSkuPartNumber still wins, so a
    # caller who means one specific bundle can still say so.
    $sku = @($skus | Where-Object { (Get-MlsProperty -InputObject $_ -Name 'skuPartNumber') -eq $LicenseSkuPartNumber })

    if ($sku.Count -eq 0) {
        # Otherwise: any subscribed SKU that provisions the plans L3's features need.
        $sku = @($skus | Where-Object {
                $plans = @(Get-MlsProperty -InputObject $_ -Name 'servicePlans')
                $names = @($plans |
                        Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'provisioningStatus')" -eq 'Success' } |
                        ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'servicePlanName')" })
                @($RequiredServicePlan | Where-Object { $_ -notin $names }).Count -eq 0
            })
    }

    if ($sku.Count -eq 0) {
        $available = @($skus | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'skuPartNumber')" })
        return New-MlsCheckResult -Passed $false `
            -Observed "no subscribed SKU provides $($RequiredServicePlan -join ' + '); tenant has: $(if ($available.Count) { $available -join ', ' } else { '(none)' })" `
            -Detail 'L03 failure mode 2: trial not activated, or no SKU on this tenant carries Entra ID Premium and MFA. Any bundle providing those plans satisfies this - EMS E3/E5, Microsoft 365 E3/E5, or Entra ID P1/P2 standalone. Human action in the M365 admin center.'
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
        [string[]]$RequiredServicePlan = @('AAD_PREMIUM', 'MFA_PREMIUM'),
        [string]$NamingPrefix = 'mls',
        [string]$ReportRoot,
        [switch]$NoRetry,
        [string[]]$OnlyCriterion = @()
    )
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $manifestFile = Resolve-MlsInput -Name 'ManifestPath' -Value $ManifestPath -EnvironmentVariable @('MLS_ENTRA_MANIFEST') `
        -DefaultValue (Join-Path -Path $repoRoot -ChildPath 'infra' -AdditionalChildPath 'entra', 'manifest.json') `
        -Hint 'The identity manifest is the source of every expected value in this audit.'
    # The manifest ships tokenised so the estate can be rebranded from one place; resolve
    # the tokens exactly as apply-entra.ps1 does, or every name compared below is a literal
    # '${prefix}-...' that exists in no tenant (F90).
    $estateNaming = Get-MlsEstateNaming
    $manifest = Get-MlsJsonFile -Path $manifestFile -Purpose 'L3 identity manifest - the audit reads the manifest, not the plan text' `
        -TokenReplacement @{ '${prefix}' = $estateNaming.Prefix; '${env}' = $estateNaming.Env }

    $manifestDomain = "$(Get-MlsProperty -InputObject $manifest -Name 'domain')"
    $domainDefault = ''
    # `.example` is RESERVED BY RFC 2606 for documentation and can never be a real verified
    # domain, so the suffix identifies the placeholder for any prefix. This used to compare
    # against the literal 'mls.example', which stopped recognising the placeholder the moment
    # the manifest became rebrandable - a cloner's 'acme.example' would have been accepted as
    # a real tenant domain and every UPN composed against it (F90).
    if ($manifestDomain -and $manifestDomain -notlike '*.example') { $domainDefault = $manifestDomain }
    $tenantDomain = Resolve-MlsInput -Name 'Domain' -Value $Domain -EnvironmentVariable @('MLS_TENANT_DOMAIN', 'TENANT_DOMAIN') `
        -DefaultValue $domainDefault `
        -Hint "The tenant's verified domain. UPNs are composed as <prefix>@<domain>; the manifest ships the placeholder 'mls.example', which apply-entra.ps1 overrides at apply time, so the audit cannot guess it."

    $context = New-MlsAuditContext -Layer 3 -Title 'Entra layer: users, groups, CA, app registrations' `
        -ScriptName 'verification/layer-03-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry `
        -OnlyCriterion $OnlyCriterion
    Add-MlsPreflight -Context $context -Name 'Manifest' -Value $manifestFile
    Add-MlsPreflight -Context $context -Name 'Tenant domain' -Value $tenantDomain
    Add-MlsPreflight -Context $context -Name 'Manifest shape' `
        -Value "$(@($manifest.users).Count) users / $(@($manifest.groups).Count) groups / $(@($manifest.appRegistrations).Count) app registrations / $(@($manifest.conditionalAccessPolicies).Count) CA policies"

    # L03: Entra object propagation can lag 15-45 min (spec F6)
    Invoke-MlsCriterion -Context $context -Id 'V3.1' -Control @('3.1.1', '3.5.1') `
        -Description 'Graph queries confirm object counts' `
        -Command "GET /v1.0/users/<upn> for each manifest user`nGET /v1.0/groups?`$filter=displayName eq '<name>'`nGET /v1.0/applications?`$filter=displayName eq '<name>'`nGET /v1.0/groups?`$filter=startswith(displayName,'$NamingPrefix')  # drift sweep" `
        -Expected "$(@($manifest.users).Count) users, $(@($manifest.groups).Count) groups, $(@($manifest.appRegistrations).Count) app registrations - each manifest entry resolving to exactly one object, zero $NamingPrefix-prefixed extras" `
        -RetryWindowMinutes 45 `
        -Test { Test-DirectoryObjectCount -Manifest $manifest -Domain $tenantDomain -NamingPrefix $NamingPrefix } | Out-Null

    # L03: reads the directory V3.1 has already waited out
    Invoke-MlsCriterion -Context $context -Id 'V3.2' -Control @('3.1.1', '3.1.2') `
        -Description 'Graph queries confirm group memberships' `
        -Command "GET /v1.0/groups/<id>/members for each manifest group" `
        -Expected "each group's member set equals the manifest's member list exactly (set equality)" `
        -RetryWindowMinutes 10 `
        -Test { Test-GroupMembership -Manifest $manifest -Domain $tenantDomain } | Out-Null

    $enforcedPolicy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -eq 'enabled' })
    $reportOnlyPolicy = @($manifest.conditionalAccessPolicies | Where-Object { $_.state -ne 'enabled' })
    # Built with Get-MlsProperty, not dotted access: this line runs OUTSIDE any criterion's
    # try/catch, so under Set-StrictMode -Version Latest a manifest missing the key would
    # abort the whole audit instead of failing V3.3 with a legible message.
    $enforcedScope = @($enforcedPolicy | ForEach-Object {
            $applications = Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $_ -Name 'conditions') -Name 'applications'
            @(Get-MlsProperty -InputObject $applications -Name 'includeApplicationsByDisplayName').Count
        })
    # -Control @() STILL, and the reason changed completely on 2026-08-28 - read this
    # before mapping it.
    #
    # It used to be unmapped because a green V3.3 was positive evidence that MFA was NOT
    # enforced: the criterion asserted every CA policy was report-only. That is no longer
    # true. V3.3 now PASSES only when mls-ca-require-mfa-dashboards is live, ENFORCED,
    # granting mfa on exactly the three dashboard applications with a populated break-glass
    # exclusion - real, machine-verified evidence of multifactor authentication for network
    # access to those three applications.
    #
    # It is still not evidence of 3.5.3, and mapping it would be a laundered claim.
    # 3.5.3 requires MFA "for local and network access to PRIVILEGED accounts AND for
    # network access to non-privileged accounts". This criterion asserts, in the same
    # breath and as a pass condition, that mls-ca-require-mfa-admins - the policy scoped by
    # includeRoles to the admin directory roles - is REPORT-ONLY. A green V3.3 therefore
    # proves the non-privileged half for three applications and simultaneously proves the
    # privileged half is not enforced. Mapping it to 3.5.3 would let a passing criterion
    # render that requirement COMPLIANT (the criteria branch is the only path to COMPLIANT,
    # compliance/lib/MlsCompliance.psm1) while half of it is deliberately off.
    #
    # 3.5.4 (replay-resistant mechanisms) is not mapped either: what makes an Entra sign-in
    # replay-resistant is the OIDC code flow the platform implements, which this criterion
    # neither configures nor reads. compliance/assessment/3.5.3.json carries the authored
    # record and says exactly this, in both directions.
    # L03: reads the directory V3.1 has already waited out
    Invoke-MlsCriterion -Context $context -Id 'V3.3' -Control @() `
        -Description 'CA policy state matches the manifest, and the enforced policy really enforces MFA' `
        -Command "GET /v1.0/identity/conditionalAccess/policies  # Policy.Read.All, read-only`nGET /v1.0/applications?`$filter=displayName eq '<dashboard app>'  # -> appId`nGET /v1.0/groups/<break-glass>/members?`$select=id,userPrincipalName,onPremisesSyncEnabled" `
        -Expected "$(@($reportOnlyPolicy).Count) broad polic(y/ies) [$(@($reportOnlyPolicy | ForEach-Object { $_.displayName }) -join ', ')] State == enabledForReportingButNotEnforced; $(@($enforcedPolicy).Count) polic(y/ies) [$(@($enforcedPolicy | ForEach-Object { $_.displayName }) -join ', ')] State == enabled, granting mfa, scoped to exactly $($enforcedScope -join '/') named application(s) and not 'All', excluding a break-glass group that holds a cloud-only emergency-access account" `
        -RetryWindowMinutes 10 `
        -Test { Test-ConditionalAccessState -Manifest $manifest -Domain $tenantDomain } | Out-Null

    $licensedUser = @(Get-ManifestUserPrincipalName -Manifest $manifest -Domain $tenantDomain -LicensedOnly)
    # -Control @(): license assignment is an entitlement/billing precondition for identity
    # features (Conditional Access, Identity Protection) to be available, not itself an
    # implemented protection. What those features do is evidenced directly by V3.3;
    # licence state alone would over-claim if mapped to the identification/authentication
    # requirements those features realize.
    # L03: reads the directory V3.1 has already waited out
    Invoke-MlsCriterion -Context $context -Id 'V3.4' -Control @() `
        -Description "License assignment state == success for all $($licensedUser.Count) licensed of $(@($manifest.users).Count)" `
        -Command "GET /v1.0/subscribedSkus`nGET /v1.0/users/<upn>?`$select=licenseAssignmentStates" `
        -Expected "each of the $($licensedUser.Count) manifest user(s) flagged licensed carries the $LicenseSkuPartNumber assignment with State == Active and no error" `
        -RetryWindowMinutes 10 `
        -Test { Test-LicenseAssignment -Manifest $manifest -Domain $tenantDomain -LicenseSkuPartNumber $LicenseSkuPartNumber -RequiredServicePlan $RequiredServicePlan } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -ManifestPath $ManifestPath -Domain $Domain `
            -LicenseSkuPartNumber $LicenseSkuPartNumber -RequiredServicePlan $RequiredServicePlan `
            -NamingPrefix $NamingPrefix -ReportRoot $ReportRoot -NoRetry:$NoRetry `
            -OnlyCriterion $OnlyCriterion
    }
    catch {
        Write-MlsStatus -Message "layer-03-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
