#Requires -Version 7.0
<#
.SYNOPSIS
    L1 Verifier audit - repo skeleton, OIDC wiring, up/down pipelines. READ-ONLY.

.DESCRIPTION
    Implements the four master-plan Verify criteria owned by docs/runbooks/layers/L01.md
    section Validation cycle, and nothing else:

      V1.1  Actions run using OIDC succeeds (az account show inside the runner matches
            the demo sub) - read independently from the run/job conclusions.
      V1.2  gh api repos/{repo} shows secret scanning + push protection enabled.
      V1.3  No committed IDs (grep audit) - the three real GUIDs, plus a generic GUID
            sweep against a reviewed allowlist.
      V1.4  Federated credential subject matches repo:<owner>/<repo>.

    Runs as mls-verifier with its dedicated GitHub read token (spec F8), never the
    deployer's context, and never writes: GitHub reads go through gh's read-only command
    set, Entra reads through Graph GET.

.EXAMPLE
    ./layer-01-audit.ps1
    # inputs default from the environment: MLS_VERIFIER_GH_TOKEN/GH_TOKEN, MLS_REPOSITORY,
    # AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID, FABRIC_CAPACITY_ID

.EXAMPLE
    ./layer-01-audit.ps1 -Repository paulcfuqua/azure-devsecops-demo -NoRetry
#>
[CmdletBinding()]
param(
    [string]$Repository,
    [string]$WorkflowFile = 'infra-up.yml',
    [string]$OidcJobName = 'oidc-login',
    [string]$DeployerAppName = 'mls-github-deployer',
    [string]$EnvironmentName = 'demo',
    [string]$RepoRoot,
    [string]$GuidAllowlistPath,
    [string]$ReportRoot,
    [switch]$NoRetry
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'MlsAudit.psm1') -Force

$script:GuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

function Get-AllowedGuid {
    <# Reviewed allowlist of GUIDs that may legitimately appear in the repo (L01 V1.3:
       "matches only on the committed allowlist (e.g. label GUIDs recorded by L4)"). #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowEmptyString()][string]$AllowlistPath
    )
    $allowed = [System.Collections.Generic.List[string]]::new()
    $sources = @()
    if (-not [string]::IsNullOrWhiteSpace($AllowlistPath)) { $sources += $AllowlistPath }
    $sources += (Join-Path -Path $RepoRoot -ChildPath 'verification' -AdditionalChildPath 'guid-allowlist.txt')
    $sources += (Join-Path -Path $RepoRoot -ChildPath 'verification' -AdditionalChildPath 'reports', 'label-guids.json')
    foreach ($source in $sources) {
        if (-not (Test-Path -LiteralPath $source)) { continue }
        $text = Get-Content -LiteralPath $source -Raw
        foreach ($match in [regex]::Matches($text, $script:GuidPattern)) { $allowed.Add($match.Value.ToLowerInvariant()) }
    }
    return @($allowed | Sort-Object -Unique)
}

function Test-OidcRoundTrip {
    <# V1.1 - the login job's own "Assert subscription" step fails the run when
       az account show differs from vars.AZURE_SUBSCRIPTION_ID, so the run/job
       conclusions are the independent signal available to a read-only Verifier. #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$WorkflowFile,
        [Parameter(Mandatory)][string]$OidcJobName
    )
    $runs = @(Invoke-MlsGh -Argument @(
            'run', 'list', '--repo', $Repository, '--workflow', $WorkflowFile,
            '--limit', '1', '--json', 'databaseId,conclusion,status,createdAt'
        ))
    if ($runs.Count -eq 0 -or $null -eq $runs[0]) {
        return New-MlsCheckResult -Passed $false -Observed "no runs found for workflow $WorkflowFile" `
            -Detail 'The L1 deploy step dispatches infra-up.yml with mode=oidc-smoke; the Verifier only reads the result.'
    }
    $run = $runs[0]
    $runId = Get-MlsProperty -InputObject $run -Name 'databaseId'
    $conclusion = Get-MlsProperty -InputObject $run -Name 'conclusion'
    $jobs = @(Get-MlsCollection -Response (Invoke-MlsGh -Argument @('api', "repos/$Repository/actions/runs/$runId/jobs")))
    $oidcJob = @($jobs | Where-Object { (Get-MlsProperty -InputObject $_ -Name 'name') -eq $OidcJobName })
    $jobConclusion = if ($oidcJob.Count -ge 1) { Get-MlsProperty -InputObject $oidcJob[0] -Name 'conclusion' } else { '(job absent)' }
    $observed = "run $runId conclusion=$conclusion; job $OidcJobName conclusion=$jobConclusion"
    $passed = ($conclusion -eq 'success' -and $jobConclusion -eq 'success')
    $detail = ''
    if (-not $passed -and $jobConclusion -eq '(job absent)') {
        $detail = "The run carries no job named '$OidcJobName'; the OIDC login job is what proves the token exchange landed in the demo subscription."
    }
    return New-MlsCheckResult -Passed $passed -Observed $observed -Detail $detail
}

function Test-SecretScanning {
    <# V1.2 - read-your-writes, single query, no retry (L01.md). #>
    param([Parameter(Mandatory)][string]$Repository)
    $repo = Invoke-MlsGh -Argument @('api', "repos/$Repository")
    $analysis = Get-MlsProperty -InputObject $repo -Name 'security_and_analysis'
    $secretScanning = Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $analysis -Name 'secret_scanning') -Name 'status'
    $pushProtection = Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $analysis -Name 'secret_scanning_push_protection') -Name 'status'
    $observed = "{`"ss`":`"$secretScanning`",`"pp`":`"$pushProtection`"}"
    return New-MlsCheckResult -Passed ($secretScanning -eq 'enabled' -and $pushProtection -eq 'enabled') -Observed $observed -Final
}

function Test-CommittedIdentifier {
    <# V1.3 - two greps: the three real GUIDs (values injected from the Verifier's own
       environment, never from the repo) and a generic GUID sweep with an allowlist. #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowEmptyCollection()][string[]]$SecretValue = @(),
        [AllowEmptyCollection()][string[]]$AllowedGuid = @()
    )
    $genericPattern = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    $generic = Invoke-MlsGit -WorkingDirectory $RepoRoot -Argument @(
        'grep', '-inIE', $genericPattern, '--', ':!docs', ':!*.lock'
    )
    if ($generic.ExitCode -gt 1) {
        return New-MlsCheckResult -Passed $false -Observed "git grep failed with exit code $($generic.ExitCode)" `
            -Detail 'V1.3 greps a fresh clone of main; a non-zero-non-one exit means the grep itself failed.'
    }
    $unexpected = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $generic.Line) {
        foreach ($match in [regex]::Matches($line, $genericPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            if ($match.Value.ToLowerInvariant() -notin $AllowedGuid) { $unexpected.Add("$line") }
        }
    }
    if ($unexpected.Count -gt 0) {
        return New-MlsCheckResult -Passed $false -Observed ("$($unexpected.Count) non-allowlisted GUID hit(s): " + (($unexpected | Select-Object -First 5) -join ' | ')) `
            -Detail 'Allowlist sources: verification/guid-allowlist.txt and verification/reports/label-guids.json.' -Final
    }

    $values = @($SecretValue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($values.Count -eq 0) {
        return New-MlsCheckResult -Status 'SKIP' `
            -Observed 'generic GUID sweep clean; specific-GUID sweep not run' `
            -Detail 'AZURE_TENANT_ID / AZURE_SUBSCRIPTION_ID / FABRIC_CAPACITY_ID are absent from the Verifier environment, so the half of V1.3 that greps the three real identifiers could not run (L01.md Deferred validation names exactly this half). Export them and re-run.'
    }
    $specific = Invoke-MlsGit -WorkingDirectory $RepoRoot -Argument @('grep', '-inIE', ($values -join '|'))
    if ($specific.ExitCode -eq 1) {
        return New-MlsCheckResult -Passed $true -Observed "no matches for either sweep ($($values.Count) identifier(s) checked, generic sweep clean)"
    }
    if ($specific.ExitCode -gt 1) {
        return New-MlsCheckResult -Passed $false -Observed "git grep failed with exit code $($specific.ExitCode)"
    }
    return New-MlsCheckResult -Passed $false -Observed ("committed identifier(s) found: " + (($specific.Line | Select-Object -First 5) -join ' | ')) `
        -Detail 'A real tenant/subscription/capacity GUID is committed. Rotate what leaked before scrubbing history (L01 failure mode 4).' -Final
}

function Test-FederatedCredential {
    <# V1.4 - Graph read as mls-verifier (Directory.Read.All). #>
    param(
        [Parameter(Mandatory)][string]$DeployerAppName,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$EnvironmentName
    )
    $applications = @(Get-MlsCollection -Response (Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$DeployerAppName'"))
    if ($applications.Count -eq 0) {
        return New-MlsCheckResult -Passed $false -Observed "application '$DeployerAppName' not found in the directory" `
            -Detail 'The federated credential lives on the deployer app registration created by scripts/bootstrap/01-root-oidc.ps1 (G0).'
    }
    $applicationId = Get-MlsProperty -InputObject $applications[0] -Name 'id'
    $credentials = @(Get-MlsCollection -Response (Invoke-MlsGraph -Uri "https://graph.microsoft.com/v1.0/applications/$applicationId/federatedIdentityCredentials"))
    $expectedSubject = "repo:${Repository}:environment:$EnvironmentName"
    $expectedIssuer = 'https://token.actions.githubusercontent.com'
    $observedPairs = @($credentials | ForEach-Object {
            "$(Get-MlsProperty -InputObject $_ -Name 'name')=$(Get-MlsProperty -InputObject $_ -Name 'issuer')|$(Get-MlsProperty -InputObject $_ -Name 'subject')"
        })
    $match = @($credentials | Where-Object {
            (Get-MlsProperty -InputObject $_ -Name 'issuer') -eq $expectedIssuer -and
            (Get-MlsProperty -InputObject $_ -Name 'subject') -eq $expectedSubject
        })
    if ($match.Count -ge 1) {
        return New-MlsCheckResult -Passed $true -Observed "issuer=$expectedIssuer; subject=$expectedSubject"
    }
    return New-MlsCheckResult -Passed $false -Observed ("no credential matching the expected subject. present: " + ($observedPairs -join ' ; ')) `
        -Detail 'Do not widen the subject to a branch wildcard to make this pass (L01 failure mode 1) - re-run 01-root-oidc.ps1 under the human login.'
}

function Invoke-Main {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is consumed inside the criterion scriptblocks; PSSA cannot see through scriptblock closures.')]
    param(
        [string]$Repository,
        [string]$WorkflowFile = 'infra-up.yml',
        [string]$OidcJobName = 'oidc-login',
        [string]$DeployerAppName = 'mls-github-deployer',
        [string]$EnvironmentName = 'demo',
        [string]$RepoRoot,
        [string]$GuidAllowlistPath,
        [string]$ReportRoot,
        [switch]$NoRetry
    )
    $repositoryName = Resolve-MlsInput -Name 'Repository' -Value $Repository -EnvironmentVariable @('MLS_GITHUB_REPO', 'MLS_REPOSITORY') `
        -Hint 'The public monorepo the L1 control plane lives in.'
    $githubToken = Resolve-MlsInput -Name 'GitHubToken' -Value '' -EnvironmentVariable @('MLS_VERIFIER_GH_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN') `
        -Hint "The Verifier's own GitHub read token (spec F8); the audit must never run in the deployer's context."
    $root = Resolve-MlsInput -Name 'RepoRoot' -Value $RepoRoot -EnvironmentVariable @('MLS_REPO_ROOT') `
        -DefaultValue (Split-Path -Path $PSScriptRoot -Parent) -Hint 'Working tree the V1.3 grep audit runs against.'

    $context = New-MlsAuditContext -Layer 1 -Title 'Repo skeleton, OIDC wiring, up/down pipelines' `
        -ScriptName 'verification/layer-01-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry
    Add-MlsPreflight -Context $context -Name 'Repository' -Value $repositoryName
    Add-MlsPreflight -Context $context -Name 'GitHub token' -Value "present ($($githubToken.Length) chars, value never logged)"
    Add-MlsPreflight -Context $context -Name 'Working tree' -Value $root

    $secretValue = @($env:AZURE_TENANT_ID, $env:AZURE_SUBSCRIPTION_ID, $env:FABRIC_CAPACITY_ID |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Add-MlsPreflight -Context $context -Name 'Identifiers for the V1.3 specific sweep' `
        -Value "$($secretValue.Count) of 3 available (values never logged)" `
        -Status $(if ($secretValue.Count -eq 3) { 'OK' } else { 'PARTIAL' })
    $allowedGuid = @(Get-AllowedGuid -RepoRoot $root -AllowlistPath $GuidAllowlistPath)
    Add-MlsPreflight -Context $context -Name 'GUID allowlist entries' -Value "$($allowedGuid.Count)"

    Invoke-MlsCriterion -Context $context -Id 'V1.1' -Control @('3.5.2') `
        -Description 'Actions run using OIDC succeeds (az account show inside the runner matches the demo sub)' `
        -Command "gh run list --workflow $WorkflowFile --limit 1 --json databaseId,conclusion`ngh api repos/$repositoryName/actions/runs/<databaseId>/jobs --jq '.jobs[] | select(.name==`"$OidcJobName`") | .conclusion'" `
        -Expected "run conclusion == 'success' and job '$OidcJobName' conclusion == 'success'" `
        -Test { Test-OidcRoundTrip -Repository $repositoryName -WorkflowFile $WorkflowFile -OidcJobName $OidcJobName } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V1.2' -Control @('3.4.2') `
        -Description 'gh api repos/{repo} shows secret scanning + push protection enabled' `
        -Command "gh api repos/$repositoryName --jq '.security_and_analysis | {ss: .secret_scanning.status, pp: .secret_scanning_push_protection.status}'" `
        -Expected '{"ss":"enabled","pp":"enabled"}' -NoRetry `
        -Test { Test-SecretScanning -Repository $repositoryName } | Out-Null

    # -Control @(): confirms no tenant/subscription/capacity identifier or generic GUID is
    # committed to the repo. That is infrastructure-identifier hygiene, not CUI protection -
    # these are not Controlled Unclassified Information and 800-171 has no "do not commit
    # environment identifiers" requirement, so this criterion evidences none of the 110.
    Invoke-MlsCriterion -Context $context -Id 'V1.3' -Control @() `
        -Description 'No committed IDs (grep audit)' `
        -Command "git grep -inIE '<AZURE_TENANT_ID|AZURE_SUBSCRIPTION_ID|FABRIC_CAPACITY_ID>'`ngit grep -inIE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' -- ':!docs' ':!*.lock'" `
        -Expected 'first sweep: zero matches (exit code 1). second sweep: matches only on the reviewed allowlist' -NoRetry `
        -Test { Test-CommittedIdentifier -RepoRoot $root -SecretValue $secretValue -AllowedGuid $allowedGuid } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V1.4' -Control @('3.5.1', '3.5.2') `
        -Description 'Federated credential subject matches repo:<owner>/<repo>' `
        -Command "GET https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$DeployerAppName'`nGET https://graph.microsoft.com/v1.0/applications/<id>/federatedIdentityCredentials" `
        -Expected "Issuer == https://token.actions.githubusercontent.com; Subject == repo:${repositoryName}:environment:$EnvironmentName" `
        -Test { Test-FederatedCredential -DeployerAppName $DeployerAppName -Repository $repositoryName -EnvironmentName $EnvironmentName } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -Repository $Repository -WorkflowFile $WorkflowFile -OidcJobName $OidcJobName `
            -DeployerAppName $DeployerAppName -EnvironmentName $EnvironmentName -RepoRoot $RepoRoot `
            -GuidAllowlistPath $GuidAllowlistPath -ReportRoot $ReportRoot -NoRetry:$NoRetry
    }
    catch {
        Write-MlsStatus -Message "layer-01-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
