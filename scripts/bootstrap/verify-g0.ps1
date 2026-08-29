#Requires -Version 7.0
<#
.SYNOPSIS
    G0 verification - READ-ONLY pass/fail audit of the bootstrap state.

.DESCRIPTION
    Checks (all read-only; no mutation is ever issued):
      1. Azure CLI logged in and pointed at the target subscription.
      2. Deployer app (mls-github-deployer) exists.
      3. The deployer's `environment:<EnvironmentName>` GitHub OIDC federated credential
         subject is present (2026-08-26 finding F7: there is deliberately no branch-ref
         subject to check for any more - see 01-root-oidc.ps1).
      4. Deployer service principal holds Owner on the subscription.
      5. Graph application permissions ADMIN-CONSENTED for the deployer SP
         (User.ReadWrite.All, Group.ReadWrite.All, Application.ReadWrite.OwnedBy,
         Policy.ReadWrite.ConditionalAccess, Directory.Read.All - checked via
         appRoleAssignments, which only exist after consent).
      6. Verifier app (mls-verifier) exists AND holds its OWN federated credential on the
         `environment:<VerifierEnvironmentName>` subject, DISTINCT from the deployer's
         (2026-08-26 findings F6/F7 - an app registration existing is not proof the
         identity can authenticate, and a subject shared with the deployer would let a
         verify job mint the Owner-capable deployer's token instead of this one's).
      7. A FABRIC capacity (F-series sku) reachable via the Fabric REST API. The sku
         matters, not just the state: a Power BI licence alone provisions a PP3
         "Premium Per User - Reserved" capacity that is Active and cannot host a
         lakehouse (finding F46).
      8. Fabric service-principal access (G0 item C4), read from the Fabric admin
         tenant-settings API. This line used to say the toggle was "portal-verified"
         and unverifiable here; that was wrong, and C4 is now checked (F46).
      9. Licenses: the SERVICE PLANS the layers consume - AAD_PREMIUM_P2,
         RMS_S_PREMIUM, MFA_PREMIUM - from whatever sku provides them, with at least
         one unit consumed. Not sku part numbers: Microsoft 365 E5 contains the EMS
         capabilities and no separate EMSPREMIUM sku exists in such a tenant (F46).
     10. $75/month budget exists.

    Additionally, one INFORMATIONAL (non-gate-failing) check:
      - G0 item 12: the tenant-scoped Entra diagnostic setting routing SignInLogs and
        AuditLogs to the Log Analytics workspace (2026-08-26 finding F9). This is a
        human, post-L6 step deliberately kept off mls-github-deployer (creating it needs
        Security Administrator, which finding F8 specifically narrowed this SP away
        from) - see docs/runbooks/g0-bootstrap.md item 12. Reported the same way items
        C6/C7/C10 are treated in that runbook: visible, never gate-failing. The point is
        that a missing setting becomes visible rather than silently trusted, not that G0
        blocks Layer 1 on it.

    Prints a pass/fail table and exits nonzero if any check FAILS ("G0 complete" per
    docs/runbooks/g0-bootstrap.md section D means: all non-informational rows PASS). The
    informational row never contributes to the fail count or the exit code.

.EXAMPLE
    ./verify-g0.ps1 -SubscriptionId <sub>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [string]$DeployerAppName = 'mls-github-deployer',
    [string]$VerifierAppName = 'mls-verifier',
    # No default: this audit must check the repo YOU federated, not the upstream one.
    # Falls back to MLS_GITHUB_REPO / MLS_REPOSITORY, then fails with instructions.
    [ValidatePattern('^$|^[\w.-]+/[\w.-]+$')]
    [string]$Repository = '',
    [string]$EnvironmentName = 'demo',
    # Must match -VerifierEnvironmentName on 01-root-oidc.ps1. Deliberately distinct from
    # -EnvironmentName (2026-08-26 findings F6/F7) - see Test-VerifierApp below.
    [string]$VerifierEnvironmentName = 'verify',
    [string]$BudgetName = 'mls-monthly-budget',
    [int]$BudgetAmount = 75
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'MlsBootstrap.psm1') -Force

$script:GraphConsentedRoles = [ordered]@{
    'User.ReadWrite.All'                 = '741f803b-c850-494e-b5df-cde7c675a1ca'
    'Group.ReadWrite.All'                = '62a82d76-70ea-41e2-9197-370581804d09'
    'Application.ReadWrite.OwnedBy'      = '18a4783c-866b-4cc7-a460-3d5e5662c884'
    'Policy.ReadWrite.ConditionalAccess' = '01c0a623-fc9b-48e9-b794-0756f8e8f067'
    'Directory.Read.All'                 = '7ab1d382-f21e-4acd-a863-ba3e13f7da61'
    'Policy.Read.All'                    = '246dd0d5-5bd0-4def-940b-0421030a5b68'
}
# CAPABILITIES, NOT PURCHASES (finding F46).
#
# This used to demand two SKU part numbers -- one of SPE_E5/ENTERPRISEPREMIUM plus
# a separate EMSPREMIUM -- and it was wrong in a way that only a real tenant could
# reveal. Microsoft 365 E5 (SPE_E5) *contains* the Enterprise Mobility + Security
# capabilities as SERVICE PLANS; there is no separate EMSPREMIUM SKU in such a
# tenant and there never will be. The check therefore failed on a tenant holding
# every capability this estate needs, and told the operator to go buy an $18/user
# licence that would have added nothing.
#
# It is also no longer purchasable as a trial: as of 2026-08-29 the Microsoft 365
# admin center offers EMS E3 and E5 for purchase only, while Microsoft 365 E5 has
# a 25-seat trial. An adopter following the old runbook could not have satisfied
# the old check without spending money.
#
# So assert what the layers actually consume, from whatever SKU provides it:
#
#   AAD_PREMIUM_P2  Entra ID P2 -- sign-in risk and Identity Protection feed the
#                   control-tower Sec tab; risk-based Conditional Access (L3)
#   RMS_S_PREMIUM   AIP P1      -- create/manage sensitivity labels (L4)
#   MFA_PREMIUM     the enforced dashboard MFA policy V3.3 audits
#
# AAD_PREMIUM (P1) is implied by P2 and not listed separately. RMS_S_PREMIUM2
# (AIP P2, auto-labeling) is deliberately NOT required: the runbook documents
# auto-labeling as optional.
# C4 IS VERIFIABLE AFTER ALL (finding F46, correcting F43).
#
# Yesterday's F43 wrote that C4 -- the Fabric service-principal toggle -- has "no
# read path this script can use under your login" and must be confirmed by eye.
# That was wrong, and a real tenant disproved it within a day: the Fabric admin
# API returns every tenant setting to a Fabric/Global administrator at
#   GET https://api.fabric.microsoft.com/v1/admin/tenantsettings
#
# The runbook also described C4 as ONE toggle, "Service principals can use Fabric
# APIs". No setting has that name any more. It is five, and the distinction
# matters: infra/fabric/provision-workspace.ps1 calls New-FabricWorkspace, and
# CREATING a workspace is governed by ServicePrincipalAccessGlobalAPIs, not by
# the similarly-named ServicePrincipalAccessPermissionAPIs. On the tenant this
# was written against, the second was on and the first was off -- so L5 would
# have failed on a tenant whose gate said C4 was satisfied.
#
# The three admin-API settings stay OFF and are asserted off, not merely ignored:
# nothing in this repository calls a Fabric admin API (no `v1/admin` or
# `myorg/admin` under infra/fabric or verification), so an enabled one is scope
# this estate did not ask for.
$script:RequiredFabricSpSettings = [ordered]@{
    'ServicePrincipalAccessGlobalAPIs'     = 'create workspaces/connections (L5 New-FabricWorkspace)'
    'ServicePrincipalAccessPermissionAPIs' = 'call Fabric public APIs (L5, L8, V5.x)'
}
$script:ForbiddenFabricSpSettings = [ordered]@{
    'AllowServicePrincipalsUseReadAdminAPIs'    = 'read-only admin APIs'
    'AllowServicePrincipalsUseWriteAdminAPIs'   = 'admin APIs used for updates'
    'AllowServicePrincipalsCreateAndUseProfiles' = 'service principal profiles'
}

$script:RequiredServicePlans = [ordered]@{
    'AAD_PREMIUM_P2' = 'Entra ID P2 (sign-in risk, Identity Protection, risk-based CA)'
    'RMS_S_PREMIUM'  = 'AIP P1 (sensitivity label management, L4)'
    'MFA_PREMIUM'    = 'MFA enforcement (V3.3 dashboard policy)'
}

# --- plumbing (read-only: no Invoke-AzMutation on purpose) -----------------------------

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $raw = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        throw "az $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
    $text = ($raw | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

function New-CheckResult {
    <#
        -Informational marks a row as NEVER gate-failing (2026-08-26 finding F9 / G0 item
        12, Task 23): Status renders as INFO regardless of $Passed, so Get-FailCount -
        which only counts Status -eq 'FAIL' - never counts it, matching how
        docs/runbooks/g0-bootstrap.md section D already treats items C6/C7/C10. $Passed
        still records whether the underlying condition held, via Detail.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructs an in-memory result row; no system state is changed (script is read-only by contract).')]
    param(
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][bool]$Passed,
        [string]$Detail = '',
        [switch]$Informational
    )
    $status = 'FAIL'
    if ($Passed) { $status = 'PASS' }
    if ($Informational) { $status = 'INFO' }
    return [pscustomobject]@{ Check = $Check; Status = $status; Detail = $Detail }
}

function Get-AdAppByName {
    param([Parameter(Mandatory)][string]$DisplayName)
    $apps = Invoke-AzCli -Arguments @('ad', 'app', 'list', '--display-name', $DisplayName, '--output', 'json')
    $found = @($apps | Where-Object { $_ -and $_.displayName -eq $DisplayName })
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

function Get-ServicePrincipalByAppId {
    param([Parameter(Mandatory)][string]$AppId)
    $sps = Invoke-AzCli -Arguments @('ad', 'sp', 'list', '--filter', "appId eq '$AppId'", '--output', 'json')
    $found = @($sps | Where-Object { $_ })
    if ($found.Count -ge 1) { return $found[0] }
    return $null
}

# --- checks ----------------------------------------------------------------------------

function Test-CliLogin {
    param([Parameter(Mandatory)][string]$SubscriptionId)
    $account = Invoke-AzCli -Arguments @('account', 'show', '--output', 'json') -AllowFailure
    if (-not $account) {
        return New-CheckResult -Check 'CliLogin' -Passed $false -Detail 'az CLI not logged in (run az login)'
    }
    if ($account.id -ne $SubscriptionId) {
        return New-CheckResult -Check 'CliLogin' -Passed $false -Detail "logged in, but active subscription is $($account.id), expected $SubscriptionId"
    }
    return New-CheckResult -Check 'CliLogin' -Passed $true -Detail "user $($account.user.name), tenant $($account.tenantId)"
}

function Test-DeployerApp {
    param([Parameter(Mandatory)][string]$DeployerAppName)
    $app = Get-AdAppByName -DisplayName $DeployerAppName
    if ($app) {
        return New-CheckResult -Check 'DeployerApp' -Passed $true -Detail "appId $($app.appId)"
    }
    return New-CheckResult -Check 'DeployerApp' -Passed $false -Detail "app registration '$DeployerAppName' not found (run 01-root-oidc.ps1)"
}

function Test-Federation {
    param(
        [Parameter(Mandatory)][string]$DeployerAppName,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$EnvironmentName
    )
    $app = Get-AdAppByName -DisplayName $DeployerAppName
    if (-not $app) {
        return New-CheckResult -Check 'Federation' -Passed $false -Detail 'deployer app absent'
    }
    $creds = Invoke-AzCli -Arguments @('ad', 'app', 'federated-credential', 'list', '--id', $app.id, '--output', 'json')
    $subjects = @($creds | ForEach-Object { $_.subject })
    # ONLY the environment subject, deliberately (2026-08-26 finding F7): 01-root-oidc.ps1
    # no longer creates a branch-ref credential, so this audit must not expect one either -
    # a leftover expectation here would fail G0 forever on a correctly-fixed deployer.
    $expectedSubject = "repo:${Repository}:environment:$EnvironmentName"
    $missing = @()
    if ($subjects -notcontains $expectedSubject) { $missing += $expectedSubject }

    # ASK GITHUB WHICH SUBJECT IT WILL SEND (F48). Checking only the hand-built classic
    # form is how this gate passed a deployer whose first real OIDC login was refused with
    # AADSTS700213: GitHub now embeds immutable owner/repo ids in the subject claim. The
    # prefix is read, never constructed, and never inferred from `use_immutable_subject` -
    # this repo's GitHub reported that flag false while sending the immutable subject.
    # A tenant whose GitHub presents no immutable prefix is not failed for lacking a
    # credential it will never need.
    $prefix = Get-GitHubSubClaimPrefix -Repository $Repository
    if ($prefix) {
        $immutableSubject = "${prefix}:environment:$EnvironmentName"
        if ($subjects -notcontains $immutableSubject) { $missing += $immutableSubject }
    }

    if ($missing.Count -eq 0) {
        $detail = if ($prefix) { 'environment subject present, both classic and immutable forms' }
        else { 'environment subject present' }
        return New-CheckResult -Check 'Federation' -Passed $true -Detail $detail
    }
    return New-CheckResult -Check 'Federation' -Passed $false -Detail "missing subject: $($missing -join '; ')"
}

function Test-OwnerRole {
    param(
        [Parameter(Mandatory)][string]$DeployerAppName,
        [Parameter(Mandatory)][string]$SubscriptionId
    )
    $app = Get-AdAppByName -DisplayName $DeployerAppName
    if (-not $app) {
        return New-CheckResult -Check 'OwnerRole' -Passed $false -Detail 'deployer app absent'
    }
    $sp = Get-ServicePrincipalByAppId -AppId $app.appId
    if (-not $sp) {
        return New-CheckResult -Check 'OwnerRole' -Passed $false -Detail 'deployer service principal absent'
    }
    $assignments = Invoke-AzCli -Arguments @(
        'role', 'assignment', 'list',
        '--assignee', $sp.id,
        '--role', 'Owner',
        '--scope', "/subscriptions/$SubscriptionId",
        '--output', 'json'
    )
    if (@($assignments | Where-Object { $_ }).Count -ge 1) {
        return New-CheckResult -Check 'OwnerRole' -Passed $true -Detail 'Owner assigned at subscription scope'
    }
    return New-CheckResult -Check 'OwnerRole' -Passed $false -Detail 'no Owner assignment for deployer SP at subscription scope'
}

function Test-GraphConsent {
    param([Parameter(Mandatory)][string]$DeployerAppName)
    $app = Get-AdAppByName -DisplayName $DeployerAppName
    if (-not $app) {
        return New-CheckResult -Check 'GraphConsent' -Passed $false -Detail 'deployer app absent'
    }
    $sp = Get-ServicePrincipalByAppId -AppId $app.appId
    if (-not $sp) {
        return New-CheckResult -Check 'GraphConsent' -Passed $false -Detail 'deployer service principal absent'
    }
    $assignments = Invoke-AzCli -Arguments @(
        'rest', '--method', 'get',
        '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments"
    )
    $grantedIds = @()
    if ($assignments -and $assignments.PSObject.Properties.Name -contains 'value') {
        $grantedIds = @($assignments.value | ForEach-Object { $_.appRoleId })
    }
    $missing = @($script:GraphConsentedRoles.Keys | Where-Object { $grantedIds -notcontains $script:GraphConsentedRoles[$_] })
    if ($missing.Count -eq 0) {
        # Counted, never hardcoded: this read 'all 5' while the map held five, and would
        # have kept saying 5 as the map grew to six (F50).
        return New-CheckResult -Check 'GraphConsent' -Passed $true -Detail "all $($script:GraphConsentedRoles.Count) application permissions consented"
    }
    return New-CheckResult -Check 'GraphConsent' -Passed $false -Detail "not consented: $($missing -join ', ') (open the admin-consent URL printed by 01-root-oidc.ps1)"
}

function Test-VerifierApp {
    <#
        2026-08-26 findings F6/F7: an app REGISTRATION existing is not proof the verifier
        can authenticate - it needs its own federated credential - and that credential's
        subject must be DISTINCT from the deployer's, or a verify job can mint a token
        that exchanges for the Owner-capable deployer instead of this Reader-scoped
        identity. Both are asserted here so G0 cannot report green on either gap.
    #>
    param(
        [Parameter(Mandatory)][string]$VerifierAppName,
        [Parameter(Mandatory)][string]$DeployerAppName,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$VerifierEnvironmentName
    )
    $app = Get-AdAppByName -DisplayName $VerifierAppName
    if (-not $app) {
        return New-CheckResult -Check 'VerifierApp' -Passed $false -Detail "app registration '$VerifierAppName' not found (run 01-root-oidc.ps1)"
    }
    $expectedSubject = "repo:${Repository}:environment:$VerifierEnvironmentName"
    $verifierCreds = Invoke-AzCli -Arguments @('ad', 'app', 'federated-credential', 'list', '--id', $app.id, '--output', 'json')
    $verifierSubjects = @($verifierCreds | ForEach-Object { $_.subject })
    if ($verifierSubjects -notcontains $expectedSubject) {
        return New-CheckResult -Check 'VerifierApp' -Passed $false -Detail "no federated credential for subject '$expectedSubject' - mls-verifier cannot authenticate (run 01-root-oidc.ps1)"
    }
    $deployerApp = Get-AdAppByName -DisplayName $DeployerAppName
    if ($deployerApp) {
        $deployerCreds = Invoke-AzCli -Arguments @('ad', 'app', 'federated-credential', 'list', '--id', $deployerApp.id, '--output', 'json')
        $deployerSubjects = @($deployerCreds | ForEach-Object { $_.subject })
        if ($deployerSubjects -contains $expectedSubject) {
            return New-CheckResult -Check 'VerifierApp' -Passed $false -Detail "subject '$expectedSubject' is federated to BOTH apps - it must be distinct to the verifier (2026-08-26 finding F7)"
        }
    }
    return New-CheckResult -Check 'VerifierApp' -Passed $true -Detail "appId $($app.appId); federated credential present, subject distinct from the deployer's"
}

function Test-FabricCapacity {
    $response = Invoke-AzCli -Arguments @(
        'rest', '--method', 'get',
        '--url', 'https://api.fabric.microsoft.com/v1/capacities',
        '--resource', 'https://api.fabric.microsoft.com'
    ) -AllowFailure
    if (-not $response) {
        return New-CheckResult -Check 'FabricCapacity' -Passed $false -Detail 'Fabric API unreachable (no capacity, no license, or API disabled)'
    }
    $capacities = @()
    if ($response.PSObject.Properties.Name -contains 'value') { $capacities = @($response.value) }
    # SKU, NOT JUST STATE (finding F46). This used to accept any capacity in state
    # Active, which is a FALSE PASS: a tenant with a Power BI licence and no Fabric
    # capacity at all still reports one. Signing into Fabric for the first time
    # provisions "Premium Per User - Reserved", sku PP3 -- an artifact of the Power
    # BI Pro licence inside Microsoft 365 E5, not a Fabric capacity. It cannot host
    # a lakehouse, so L5 fails on a tenant this check called ready.
    #
    # Fabric-capable SKUs are the F series: F2, F4, F8 ... F2048, plus the trial.
    #
    # THE TRIAL SKU STRING IS `FTL4`, AND THREE SOURCES GOT IT WRONG BEFORE A REAL
    # TENANT SETTLED IT (finding F46):
    #   - a first guess of `FT1`, asserted from memory;
    #   - Microsoft's own trial documentation, which describes the trial in prose as
    #     "an F4 capacity (4 capacity units) or an F64 capacity"
    #     (learn.microsoft.com/fabric/fundamentals/fabric-trial, read 2026-08-29);
    #   - a corrected `^F(T)?\d+$` written from that doc, which still rejects FTL4.
    # The Power BI admin API returned `sku: FTL4` on a trial started 2026-08-29. The
    # documented capacity SIZE (4 CU) and the SKU STRING are simply different things.
    #
    # So match the F prefix and the digits, and let the middle letters be whatever
    # Microsoft ships: F4, FT1 and FTL4 all pass. This is safe against false
    # positives because no Power BI SKU begins with F -- they are P1-P5, PP3
    # (Premium Per User), EM1-EM3 and A1-A6, and none runs Fabric workloads.
    #
    # Power BI-only SKUs are P1-P5, PP3 (Premium Per User), EM1-EM3 and A1-A6, and
    # none of them runs Fabric workloads.
    $fabricCapable = @($capacities | Where-Object { $_ -and $_.sku -match '^F[A-Z]*\d+$' })
    if ($fabricCapable.Count -eq 0) {
        # The @() must wrap the WHOLE pipeline. It used to wrap only the Where-Object,
        # and the ForEach-Object after it unrolled the result again - so with exactly one
        # non-Fabric capacity (a PP3, which is the case this check exists for) $others was
        # a bare string and .Count below threw under StrictMode. F49's call-site invariant,
        # in an anonymous pipeline rather than a named helper, which is why F49's static
        # guard did not see it.
        $others = @($capacities |
                Where-Object { $_ -and $_.sku } |
                ForEach-Object { "$($_.displayName) [$($_.sku)]" })
        if ($others.Count -gt 0) {
            return New-CheckResult -Check 'FabricCapacity' -Passed $false -Detail (
                "no FABRIC capacity: found $($others -join ', '), which is Power BI only. " +
                'Start the Fabric trial (provisions an F4 or F64) or run 02-fabric-capacity.ps1 -Mode F2 (G2 gate).')
        }
        return New-CheckResult -Check 'FabricCapacity' -Passed $false `
            -Detail 'no Fabric capacity visible (start the trial or run 02-fabric-capacity.ps1 -Mode F2)'
    }
    $capacities = $fabricCapable
    $active = @($capacities | Where-Object { $_ -and $_.state -eq 'Active' })
    if ($active.Count -ge 1) {
        # displayName AND sku: the sku is the half that distinguishes a real Fabric
        # capacity from the PP3 that a Power BI licence provisions (finding F46).
        $named = @($active | ForEach-Object { "$($_.displayName) [$($_.sku)]" }) -join ', '
        return New-CheckResult -Check 'FabricCapacity' -Passed $true -Detail "active Fabric capacity: $named (SP API access checked separately by FabricSpAccess)"
    }
    if ($capacities.Count -ge 1) {
        return New-CheckResult -Check 'FabricCapacity' -Passed $true -Detail "capacity present but not Active (state: $(($capacities | ForEach-Object { $_.state }) -join ', ')) - paused F2 is expected between deploys"
    }
    return New-CheckResult -Check 'FabricCapacity' -Passed $false -Detail 'no Fabric capacity visible (start the trial or run 02-fabric-capacity.ps1 -Mode F2)'
}

function Get-MlsSettingSecurityGroup {
    <# enabledSecurityGroups is absent on an org-wide setting and empty on some tenants;
       both mean "everyone", so both must come back as an empty collection. #>
    param([Parameter(Mandatory)]$Setting)
    if ($Setting.PSObject.Properties.Name -notcontains 'enabledSecurityGroups') { return @() }
    return @($Setting.enabledSecurityGroups | Where-Object { $_ })
}

function Test-DeployerInGroup {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$GroupId,
        [Parameter(Mandatory)][string]$DeployerAppName
    )
    if ([string]::IsNullOrWhiteSpace($GroupId)) { return $false }
    $app = Get-AdAppByName -DisplayName $DeployerAppName
    if (-not $app) { return $false }
    $sp = Get-ServicePrincipalByAppId -AppId $app.appId
    if (-not $sp) { return $false }
    $result = Invoke-AzCli -Arguments @(
        'ad', 'group', 'member', 'check', '--group', $GroupId, '--member-id', $sp.id, '--output', 'json'
    ) -AllowFailure
    # Unreadable is NOT membership: an unanswerable question fails the check rather than
    # passing it, because the cost of a false PASS here is a broken L5 (F46).
    if (-not $result) { return $false }
    return [bool]$result.value
}

function Test-FabricServicePrincipal {
    <#
        C4, checked rather than trusted. Informational is deliberately NOT set: unlike
        EntraDiagnostics (F9), this one has a layer gate waiting on it -- L5 cannot
        create its workspace without it -- so it belongs in the exit code.
    #>
    param([Parameter(Mandatory)][string]$DeployerAppName)
    $response = Invoke-AzCli -Arguments @(
        'rest', '--method', 'get',
        '--url', 'https://api.fabric.microsoft.com/v1/admin/tenantsettings',
        '--resource', 'https://api.fabric.microsoft.com'
    ) -AllowFailure

    $settings = @()
    foreach ($name in 'tenantSettings', 'value') {
        if ($response -and $response.PSObject.Properties.Name -contains $name) {
            $settings = @($response.$name)
            break
        }
    }
    if ($settings.Count -eq 0) {
        return New-CheckResult -Check 'FabricSpAccess' -Passed $false `
            -Detail 'could not read Fabric tenant settings (needs a Fabric or Global administrator login)'
    }

    # The whole setting object, not just its enabled flag: a setting can be enabled for
    # SPECIFIC SECURITY GROUPS, and the API reports enabled=true either way (F50).
    $state = @{}
    foreach ($setting in $settings) {
        if ($setting.settingName) { $state[[string]$setting.settingName] = $setting }
    }

    $missing = @()
    $unscoped = @()
    foreach ($name in $script:RequiredFabricSpSettings.Keys) {
        if (-not $state.ContainsKey($name)) {
            $missing += "$name (not present in this tenant's settings)"
            continue
        }
        if (-not [bool]$state[$name].enabled) {
            $missing += "$name - $($script:RequiredFabricSpSettings[$name])"
            continue
        }
        # ENABLED IS NOT THE SAME AS ENABLED FOR US. Reading the flag alone would green-light
        # G0 while L5 fails at New-FabricWorkspace, which is the false-PASS shape F46 caught
        # in the capacity check. If the setting is scoped, confirm the deployer is inside it.
        $groups = @(Get-MlsSettingSecurityGroup -Setting $state[$name])
        if ($groups.Count -eq 0) { continue }
        $memberOf = @($groups | Where-Object { Test-DeployerInGroup -GroupId $_.graphId -DeployerAppName $DeployerAppName })
        if ($memberOf.Count -eq 0) {
            $names = @($groups | ForEach-Object { if ($_.name) { $_.name } else { $_.graphId } })
            $unscoped += "$name is enabled only for security group(s) $($names -join ', '), which '$DeployerAppName' is not a member of"
        }
    }
    if ($missing.Count -gt 0) {
        return New-CheckResult -Check 'FabricSpAccess' -Passed $false `
            -Detail "C4 incomplete, disabled: $($missing -join '; ')"
    }
    if ($unscoped.Count -gt 0) {
        return New-CheckResult -Check 'FabricSpAccess' -Passed $false `
            -Detail "C4 incomplete, scoped away from the deployer: $($unscoped -join '; ')"
    }

    # Enabled admin-API access is not a failure of C4 -- the estate still works --
    # but it is privilege nobody asked for, so say so rather than pass silently.
    $extra = @()
    foreach ($name in $script:ForbiddenFabricSpSettings.Keys) {
        if ($state.ContainsKey($name) -and [bool]$state[$name].enabled) { $extra += $script:ForbiddenFabricSpSettings[$name] }
    }
    if ($extra.Count -gt 0) {
        return New-CheckResult -Check 'FabricSpAccess' -Passed $true `
            -Detail "C4 satisfied, but service principals also hold unused admin access: $($extra -join '; ')"
    }
    return New-CheckResult -Check 'FabricSpAccess' -Passed $true `
        -Detail 'C4 satisfied: workspace-creation and public-API access on, admin APIs off'
}

function Test-License {
    $response = Invoke-AzCli -Arguments @(
        'rest', '--method', 'get',
        '--url', 'https://graph.microsoft.com/v1.0/subscribedSkus'
    ) -AllowFailure
    $skus = @()
    if ($response -and $response.PSObject.Properties.Name -contains 'value') { $skus = @($response.value) }
    if ($skus.Count -eq 0) {
        return New-CheckResult -Check 'Licenses' -Passed $false -Detail 'no subscribed SKUs visible (activate the Microsoft 365 E5 trial and assign it to your admin user)'
    }
    # Only SKUs with a seat actually assigned count. A provisioned-but-unassigned
    # trial grants nothing to anyone, which is why consumedUnits is the filter and
    # not merely prepaidUnits.enabled.
    $assigned = @($skus | Where-Object { [int]$_.consumedUnits -ge 1 })
    if ($assigned.Count -eq 0) {
        return New-CheckResult -Check 'Licenses' -Passed $false `
            -Detail 'SKUs exist but none has an assigned seat (assign the licence to your admin user)'
    }

    # Flatten every service plan across every assigned SKU. Which SKU carries a
    # capability is Microsoft''s business and it changes; that the tenant HAS the
    # capability is ours.
    $available = @{}
    foreach ($sku in $assigned) {
        foreach ($plan in @($sku.servicePlans)) {
            if ($plan.provisioningStatus -in @('Success', 'PendingProvisioning')) {
                $available[$plan.servicePlanName] = $sku.skuPartNumber
            }
        }
    }

    $missing = @()
    $satisfiedBy = @()
    foreach ($plan in $script:RequiredServicePlans.Keys) {
        if ($available.ContainsKey($plan)) {
            $satisfiedBy += "$plan (via $($available[$plan]))"
        } else {
            $missing += "$plan - $($script:RequiredServicePlans[$plan])"
        }
    }

    if ($missing.Count -eq 0) {
        return New-CheckResult -Check 'Licenses' -Passed $true `
            -Detail "all required service plans present: $($satisfiedBy -join '; ')"
    }
    return New-CheckResult -Check 'Licenses' -Passed $false `
        -Detail "missing service plan(s): $($missing -join '; ')"
}

function Test-EntraDiagnostic {
    <#
        2026-08-26 finding F9 / G0 item 12 (Task 23): the tenant Entra diagnostic
        setting routing SignInLogs + AuditLogs to the Log Analytics workspace is a
        documented human step (docs/runbooks/g0-bootstrap.md item 12), deliberately
        kept off mls-github-deployer - creating it needs Security Administrator, and
        finding F8 specifically narrowed this SP's Graph grant to shrink its tenant
        blast radius. Before this check, F9's closure rested entirely on a human
        remembering an unaudited `az monitor diagnostic-settings create` run. This
        check is READ-ONLY and INFORMATIONAL (see New-CheckResult) - never gate-failing,
        same treatment as items C6/C7/C10 in the runbook's section D.
    #>
    $response = Invoke-AzCli -Arguments @(
        'monitor', 'diagnostic-settings', 'list',
        '--resource', '/providers/microsoft.aadiam',
        '--output', 'json'
    ) -AllowFailure
    $settings = @()
    if ($response) {
        if ($response.PSObject.Properties.Name -contains 'value') { $settings = @($response.value) }
        else { $settings = @($response) }
    }
    $routed = @($settings | Where-Object {
            $_ -and $_.logs -and
            (@($_.logs | Where-Object { $_.category -eq 'SignInLogs' -and $_.enabled }).Count -ge 1) -and
            (@($_.logs | Where-Object { $_.category -eq 'AuditLogs' -and $_.enabled }).Count -ge 1)
        })
    if ($routed.Count -ge 1) {
        return New-CheckResult -Check 'EntraDiagnostics' -Passed $true -Informational `
            -Detail "tenant diagnostic setting '$($routed[0].name)' routes SignInLogs + AuditLogs to the LAW (G0 item 12)"
    }
    return New-CheckResult -Check 'EntraDiagnostics' -Passed $false -Informational `
        -Detail 'no tenant diagnostic setting routes both SignInLogs and AuditLogs yet - run G0 item 12 once, after L6 (informational only; does not block G0)'
}

function Test-Budget {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$BudgetName,
        [Parameter(Mandatory)][int]$BudgetAmount
    )
    $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/budgets/$BudgetName" +
        '?api-version=2023-05-01'
    $budget = Invoke-AzCli -Arguments @('rest', '--method', 'get', '--url', $url) -AllowFailure
    if (-not $budget) {
        return New-CheckResult -Check 'Budget' -Passed $false -Detail "budget '$BudgetName' not found (run 03-budget.ps1)"
    }
    if ([int]$budget.properties.amount -ne $BudgetAmount) {
        return New-CheckResult -Check 'Budget' -Passed $false -Detail "budget exists but amount is $($budget.properties.amount), expected $BudgetAmount"
    }
    return New-CheckResult -Check 'Budget' -Passed $true -Detail "`$$BudgetAmount/month budget in place"
}

# --- aggregation -----------------------------------------------------------------------

function Invoke-Main {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is consumed inside the check scriptblocks below; PSSA cannot see through scriptblock closures.')]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$DeployerAppName,
        [Parameter(Mandatory)][string]$VerifierAppName,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [string]$VerifierEnvironmentName = 'verify',
        [Parameter(Mandatory)][string]$BudgetName,
        [Parameter(Mandatory)][int]$BudgetAmount
    )
    $checks = @(
        @{ Name = 'CliLogin'; Run = { Test-CliLogin -SubscriptionId $SubscriptionId } }
        @{ Name = 'DeployerApp'; Run = { Test-DeployerApp -DeployerAppName $DeployerAppName } }
        @{ Name = 'Federation'; Run = { Test-Federation -DeployerAppName $DeployerAppName -Repository $Repository -EnvironmentName $EnvironmentName } }
        @{ Name = 'OwnerRole'; Run = { Test-OwnerRole -DeployerAppName $DeployerAppName -SubscriptionId $SubscriptionId } }
        @{ Name = 'GraphConsent'; Run = { Test-GraphConsent -DeployerAppName $DeployerAppName } }
        @{ Name = 'VerifierApp'; Run = { Test-VerifierApp -VerifierAppName $VerifierAppName -DeployerAppName $DeployerAppName -Repository $Repository -VerifierEnvironmentName $VerifierEnvironmentName } }
        @{ Name = 'FabricCapacity'; Run = { Test-FabricCapacity } }
        @{ Name = 'FabricSpAccess'; Run = { Test-FabricServicePrincipal -DeployerAppName $DeployerAppName } }
        @{ Name = 'Licenses'; Run = { Test-License } }
        @{ Name = 'Budget'; Run = { Test-Budget -SubscriptionId $SubscriptionId -BudgetName $BudgetName -BudgetAmount $BudgetAmount } }
        @{ Name = 'EntraDiagnostics'; Informational = $true; Run = { Test-EntraDiagnostic } }
    )
    $results = foreach ($check in $checks) {
        try {
            & $check.Run
        }
        catch {
            # ContainsKey, not $check.Informational: only EntraDiagnostics declares the key,
            # so reading it on the other ten hashtables is a terminating error under the
            # Set-StrictMode -Version Latest this script sets at line 73. That made the
            # CATCH BLOCK ITSELF throw - the gate crashed instead of recording a FAIL row,
            # on exactly the path that exists to turn a broken check into a reportable one.
            # Never fired only because no check had thrown yet (F49).
            $informational = $check.ContainsKey('Informational') -and [bool]$check.Informational
            New-CheckResult -Check $check.Name -Passed $false -Informational:$informational `
                -Detail "check errored: $($_.Exception.Message)"
        }
    }
    return @($results)
}

function Get-FailCount {
    param([AllowEmptyCollection()][object[]]$Results = @())
    return @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count
}

function Resolve-RepositoryInput {
    <# -Repository, then MLS_GITHUB_REPO / MLS_REPOSITORY, then a hard stop. Checking the
       upstream repo's federation state instead of your own would report a confident,
       meaningless PASS. #>
    param([AllowEmptyString()][string]$Value)
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    foreach ($name in @('MLS_GITHUB_REPO', 'MLS_REPOSITORY')) {
        $fromEnvironment = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) { return $fromEnvironment }
    }
    throw "No GitHub repository was supplied. Pass -Repository <owner>/<repo> (the repo you federated in 01-root-oidc.ps1) or set `$env:MLS_GITHUB_REPO. This script will not guess: auditing a repository you do not control would report a meaningless PASS."
}

if (-not $env:MLS_SKIP_MAIN) {
    $resolvedRepository = Resolve-RepositoryInput -Value $Repository
    $results = Invoke-Main -SubscriptionId $SubscriptionId -DeployerAppName $DeployerAppName `
        -VerifierAppName $VerifierAppName -Repository $resolvedRepository -EnvironmentName $EnvironmentName `
        -VerifierEnvironmentName $VerifierEnvironmentName -BudgetName $BudgetName -BudgetAmount $BudgetAmount
    $results | Format-Table -AutoSize -Wrap | Out-Host
    $failCount = Get-FailCount -Results $results
    if ($failCount -gt 0) {
        Write-Warning "G0 verification FAILED: $failCount of $($results.Count) checks failing."
        exit 1
    }
    Write-Verbose 'G0 verification passed: all checks green.'
    exit 0
}
