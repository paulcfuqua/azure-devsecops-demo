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
         (User.ReadWrite.All, Group.ReadWrite.All, Application.ReadWrite.All,
         Policy.ReadWrite.ConditionalAccess, Directory.Read.All - checked via
         appRoleAssignments, which only exist after consent).
      6. Verifier app (mls-verifier) exists AND holds its OWN federated credential on the
         `environment:<VerifierEnvironmentName>` subject, DISTINCT from the deployer's
         (2026-08-26 findings F6/F7 - an app registration existing is not proof the
         identity can authenticate, and a subject shared with the deployer would let a
         verify job mint the Owner-capable deployer's token instead of this one's).
      7. Fabric capacity reachable via the Fabric REST API (trial or F2). The
         "service principals can use Fabric APIs" toggle itself is portal-verified
         (spec F2) - this check runs under the human's token.
      8. Licenses: an M365 E5 sku (SPE_E5 or ENTERPRISEPREMIUM) and EMS E5
         (EMSPREMIUM) present with at least one unit consumed.
      9. $75/month budget exists.

    Prints a pass/fail table and exits nonzero if any check fails ("G0 complete" per
    docs/runbooks/g0-bootstrap.md section D means: all rows PASS).

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

$script:GraphConsentedRoles = [ordered]@{
    'User.ReadWrite.All'                 = '741f803b-c850-494e-b5df-cde7c675a1ca'
    'Group.ReadWrite.All'                = '62a82d76-70ea-41e2-9197-370581804d09'
    'Application.ReadWrite.All'          = '1bfefb4e-e0b5-418b-a88f-73c46d2cc8e9'
    'Policy.ReadWrite.ConditionalAccess' = '01c0a623-fc9b-48e9-b794-0756f8e8f067'
    'Directory.Read.All'                 = '7ab1d382-f21e-4acd-a863-ba3e13f7da61'
}
$script:M365E5Skus = @('SPE_E5', 'ENTERPRISEPREMIUM') # Microsoft 365 E5 / Office 365 E5 trial
$script:EmsE5Sku = 'EMSPREMIUM'

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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructs an in-memory result row; no system state is changed (script is read-only by contract).')]
    param(
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][bool]$Passed,
        [string]$Detail = ''
    )
    $status = 'FAIL'
    if ($Passed) { $status = 'PASS' }
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
    if ($subjects -contains $expectedSubject) {
        return New-CheckResult -Check 'Federation' -Passed $true -Detail 'environment subject present'
    }
    return New-CheckResult -Check 'Federation' -Passed $false -Detail "missing subject: $expectedSubject"
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
        return New-CheckResult -Check 'GraphConsent' -Passed $true -Detail 'all 5 application permissions consented'
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
    $active = @($capacities | Where-Object { $_ -and $_.state -eq 'Active' })
    if ($active.Count -ge 1) {
        $names = ($active | ForEach-Object { $_.displayName }) -join ', '
        return New-CheckResult -Check 'FabricCapacity' -Passed $true -Detail "active capacity: $names (SP API toggle is portal-verified)"
    }
    if ($capacities.Count -ge 1) {
        return New-CheckResult -Check 'FabricCapacity' -Passed $true -Detail "capacity present but not Active (state: $(($capacities | ForEach-Object { $_.state }) -join ', ')) - paused F2 is expected between deploys"
    }
    return New-CheckResult -Check 'FabricCapacity' -Passed $false -Detail 'no Fabric capacity visible (start the trial or run 02-fabric-capacity.ps1 -Mode F2)'
}

function Test-License {
    $response = Invoke-AzCli -Arguments @(
        'rest', '--method', 'get',
        '--url', 'https://graph.microsoft.com/v1.0/subscribedSkus'
    ) -AllowFailure
    $skus = @()
    if ($response -and $response.PSObject.Properties.Name -contains 'value') { $skus = @($response.value) }
    if ($skus.Count -eq 0) {
        return New-CheckResult -Check 'Licenses' -Passed $false -Detail 'no subscribed SKUs visible (activate the M365 E5 + EMS E5 trials)'
    }
    $m365 = @($skus | Where-Object { $script:M365E5Skus -contains $_.skuPartNumber -and [int]$_.consumedUnits -ge 1 })
    $ems = @($skus | Where-Object { $_.skuPartNumber -eq $script:EmsE5Sku -and [int]$_.consumedUnits -ge 1 })
    $missing = @()
    if ($m365.Count -eq 0) { $missing += "M365 E5 ($($script:M365E5Skus -join ' or '))" }
    if ($ems.Count -eq 0) { $missing += "EMS E5 ($($script:EmsE5Sku))" }
    if ($missing.Count -eq 0) {
        return New-CheckResult -Check 'Licenses' -Passed $true -Detail 'M365 E5 + EMS E5 present with assigned seats'
    }
    return New-CheckResult -Check 'Licenses' -Passed $false -Detail "missing/unassigned: $($missing -join '; ')"
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
        @{ Name = 'Licenses'; Run = { Test-License } }
        @{ Name = 'Budget'; Run = { Test-Budget -SubscriptionId $SubscriptionId -BudgetName $BudgetName -BudgetAmount $BudgetAmount } }
    )
    $results = foreach ($check in $checks) {
        try {
            & $check.Run
        }
        catch {
            New-CheckResult -Check $check.Name -Passed $false -Detail "check errored: $($_.Exception.Message)"
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
