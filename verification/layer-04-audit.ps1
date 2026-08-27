#Requires -Version 7.0
<#
.SYNOPSIS
    L4 Verifier audit - Purview sensitivity labels. READ-ONLY.

.DESCRIPTION
    Implements the two master-plan Verify criteria owned by
    docs/runbooks/layers/L04.md section Validation cycle, and nothing else:

      V4.1  Get-Label returns the 4 labels with expected GUIDs recorded to
            verification/reports/.
      V4.2  Labels survive a kill/rebuild cycle (checked again at L11).

    V4.2 is a checkpoint comparison, not a second query: L04 owns the criterion, L11 owns
    the re-execution schedule, so layer-11-audit.ps1 runs this same script with
    -Checkpoint 'post-down' and again with -Checkpoint 'post-up'. Any GUID delta after
    down.ps1 means the teardown path touched tenant objects - stop-the-line.

    V4.3 is a supplementary criterion, NOT in the master plan's 43-row list (same
    convention as V6.5 / CP-9): the label policy that scopes the taxonomy to the demo
    groups exists and is scoped as L04.md:53 describes. Added closing F18 - a label
    with no published policy cannot be applied to anything and enforces nothing, and
    V4.1/V4.2 only ever checked label existence, so that gap was invisible to this
    audit until now. L04.md's own Failure mode 5 already anticipated this exact
    supplementary check (`Get-LabelPolicy | Select -Expand ExchangeLocation`).

    The S&C session is read-only: mls-verifier holds Exchange.ManageAsApp with the
    View-Only Configuration role (L04.md Preconditions), so Get-Label works and nothing
    else does.

.EXAMPLE
    ./layer-04-audit.ps1 -Organization contoso.onmicrosoft.com
#>
[CmdletBinding()]
param(
    [string]$Organization,
    [string]$VerifierAppId,
    [string]$CertificateThumbprint,
    [string[]]$ExpectedLabel = @('Public', 'Internal', 'Confidential', 'Export-Controlled'),
    [string]$LabelGuidPath,
    [ValidateSet('layer', 'post-down', 'post-up')][string]$Checkpoint = 'layer',
    [string]$ReportRoot,
    [switch]$NoRetry,
    [string]$ExpectedLabelPolicy = 'mls-demo-label-policy',
    [string[]]$ExpectedLabelPolicyScope = @('mls-flight-operations', 'mls-security-team', 'mls-finance', 'mls-executives')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'MlsAudit.psm1') -Force

function Get-LabelSnapshot {
    <# One read of the four labels, normalised to name -> guid. #>
    param([Parameter(Mandatory)][string[]]$ExpectedLabel)
    $labels = @(Get-MlsLabel)
    $relevant = @($labels | Where-Object { (Get-MlsProperty -InputObject $_ -Name 'DisplayName') -in $ExpectedLabel })
    $map = [ordered]@{}
    foreach ($label in ($relevant | Sort-Object { Get-MlsProperty -InputObject $_ -Name 'DisplayName' })) {
        $map["$(Get-MlsProperty -InputObject $label -Name 'DisplayName')"] = "$(Get-MlsProperty -InputObject $label -Name 'Guid')"
    }
    return $map
}

function Get-RecordedLabelGuid {
    <# The baseline recorded at first L4 run (labels.ps1 commits it via PR). #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $document = Get-MlsJsonFile -Path $Path -Purpose 'recorded label GUID baseline'
    $map = [ordered]@{}
    foreach ($property in $document.PSObject.Properties) { $map["$($property.Name)"] = "$($property.Value)" }
    return $map
}

function Test-LabelTaxonomy {
    <# V4.1 - exactly the four labels; GUIDs equal to the recorded baseline when one exists. #>
    param(
        [Parameter(Mandatory)][string[]]$ExpectedLabel,
        [AllowNull()]$Baseline,
        [Parameter(Mandatory)]$Context
    )
    $snapshot = Get-LabelSnapshot -ExpectedLabel $ExpectedLabel
    $Context.Evidence['labelGuids'] = $snapshot
    $comparison = Test-MlsSetEquality -Actual @($snapshot.Keys) -Expected $ExpectedLabel
    $describe = (@($snapshot.Keys) | ForEach-Object { "$_=$($snapshot[$_])" }) -join '; '
    if (-not $comparison.Equal) {
        return New-MlsCheckResult -Passed $false `
            -Observed "labels present: [$describe]; missing [$($comparison.Missing -join ', ')]; extra [$($comparison.Extra -join ', ')]" `
            -Detail 'Label replication across S&C endpoints can lag; the standard 30-minute window applies (L04.md V4.1).'
    }
    if ($null -eq $Baseline) {
        return New-MlsCheckResult -Passed $true -Observed $describe `
            -Detail 'No recorded baseline yet: these GUIDs are this run''s first-run record (the "recorded to verification/reports/" half of the criterion). They are in this report''s JSON sibling under evidence.labelGuids - commit them to verification/reports/label-guids.json so every later run compares.'
    }
    $mismatch = @($snapshot.Keys | Where-Object { $Baseline.Contains($_) -and $Baseline[$_] -ne $snapshot[$_] })
    $absent = @($snapshot.Keys | Where-Object { -not $Baseline.Contains($_) })
    if ($mismatch.Count -gt 0) {
        return New-MlsCheckResult -Passed $false `
            -Observed ("GUID drift: " + (($mismatch | ForEach-Object { "$_ recorded=$($Baseline[$_]) observed=$($snapshot[$_])" }) -join '; ')) `
            -Detail 'A changed GUID means a label was deleted and recreated, which only a G3 action could legitimately do. Do NOT re-baseline the JSON - escalate with Search-UnifiedAuditLog -Operations DeleteLabel (L04.md Rollback).' -Final
    }
    $detail = ''
    if ($absent.Count -gt 0) { $detail = "labels not present in the baseline file: $($absent -join ', ')" }
    return New-MlsCheckResult -Passed $true -Observed $describe -Detail $detail
}

function Test-LabelPersistence {
    <# V4.2 - the same read, compared at a named checkpoint against the recorded GUIDs.
       Persistence is binary, so there is nothing to wait for. #>
    param(
        [Parameter(Mandatory)][string[]]$ExpectedLabel,
        [AllowNull()]$Baseline,
        [Parameter(Mandatory)][string]$Checkpoint
    )
    if ($null -eq $Baseline) {
        return New-MlsCheckResult -Status 'SKIP' `
            -Observed "no recorded baseline at the '$Checkpoint' checkpoint" `
            -Detail 'V4.2 compares label GUIDs across checkpoints and needs verification/reports/label-guids.json, written on the first L4 run. Without it survival cannot be asserted, only label presence (V4.1).'
    }
    $snapshot = Get-LabelSnapshot -ExpectedLabel $ExpectedLabel
    $comparison = Test-MlsSetEquality -Actual @($snapshot.Keys) -Expected $ExpectedLabel
    $drift = @($snapshot.Keys | Where-Object { $Baseline.Contains($_) -and $Baseline[$_] -ne $snapshot[$_] })
    if ($comparison.Equal -and $drift.Count -eq 0) {
        return New-MlsCheckResult -Passed $true `
            -Observed "checkpoint '$Checkpoint': same 4 labels, same GUIDs as the recorded baseline" `
            -Detail 'L11 re-executes this criterion immediately after down.ps1 and again after up.ps1 (V11.2 invokes it by reference).'
    }
    return New-MlsCheckResult -Passed $false `
        -Observed "checkpoint '$Checkpoint': missing [$($comparison.Missing -join ', ')] extra [$($comparison.Extra -join ', ')] guid-drift [$($drift -join ', ')]" `
        -Detail 'Any delta post-down.ps1 means the teardown path touched tenant objects - a critical defect in down.ps1, stop-the-line (L04.md V4.2).' -Final
}

function Test-LabelPolicyScope {
    <#
        V4.3 - supplementary, not a master-plan criterion (L04.md's Validation cycle
        section and README.md's traceability-table header both say so explicitly - same
        convention CP-9's V6.5 uses). The policy named by $PolicyName exists and
        publishes exactly $ExpectedLabel, scoped to exactly $ExpectedScope. This is the
        check L04.md's own Failure mode 5 already promised
        (`Get-LabelPolicy | Select -Expand ExchangeLocation`) and is what makes F18's
        fix auditable: V4.1 only ever proved the labels exist, never that anyone could
        apply them.
    #>
    param(
        [Parameter(Mandatory)][string]$PolicyName,
        [Parameter(Mandatory)][string[]]$ExpectedLabel,
        [Parameter(Mandatory)][string[]]$ExpectedScope
    )
    $policy = Get-MlsLabelPolicy -Identity $PolicyName
    if ($null -eq $policy) {
        return New-MlsCheckResult -Passed $false `
            -Observed "label policy '$PolicyName' not found" `
            -Detail 'A published policy is what actually lets anyone apply a label - without it the four labels are directory objects with no protection action (L04.md Deploy procedure step 1; F18).'
    }
    $actualLabel = @(Get-MlsProperty -InputObject $policy -Name 'Labels')
    $actualScope = @(Get-MlsProperty -InputObject $policy -Name 'ExchangeLocation')
    $labelComparison = Test-MlsSetEquality -Actual $actualLabel -Expected $ExpectedLabel
    $scopeComparison = Test-MlsSetEquality -Actual $actualScope -Expected $ExpectedScope
    $describe = "Labels=[$($actualLabel -join ', ')] ExchangeLocation=[$($actualScope -join ', ')]"
    if (-not $labelComparison.Equal -or -not $scopeComparison.Equal) {
        return New-MlsCheckResult -Passed $false -Observed $describe `
            -Detail ("label policy scoping error (L04.md Failure mode 5): labels missing [$($labelComparison.Missing -join ', ')] extra [$($labelComparison.Extra -join ', ')]; " +
                "scope missing [$($scopeComparison.Missing -join ', ')] extra [$($scopeComparison.Extra -join ', ')]")
    }
    return New-MlsCheckResult -Passed $true -Observed $describe
}

function Invoke-Main {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is consumed inside the criterion scriptblocks; PSSA cannot see through scriptblock closures.')]
    param(
        [string]$Organization,
        [string]$VerifierAppId,
        [string]$CertificateThumbprint,
        [string[]]$ExpectedLabel = @('Public', 'Internal', 'Confidential', 'Export-Controlled'),
        [string]$LabelGuidPath,
        [string]$Checkpoint = 'layer',
        [string]$ReportRoot,
        [switch]$NoRetry,
        [switch]$SkipConnect,
        [string]$ExpectedLabelPolicy = 'mls-demo-label-policy',
        [string[]]$ExpectedLabelPolicyScope = @('mls-flight-operations', 'mls-security-team', 'mls-finance', 'mls-executives')
    )
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $organizationName = Resolve-MlsInput -Name 'Organization' -Value $Organization `
        -EnvironmentVariable @('TENANT_DOMAIN', 'MLS_TENANT_DOMAIN') `
        -Hint 'Connect-IPPSSession needs the tenant domain; the S&C endpoint has no other way to find the tenant.'
    $appId = Resolve-MlsInput -Name 'VerifierAppId' -Value $VerifierAppId -EnvironmentVariable @('MLS_VERIFIER_APP_ID') `
        -Hint 'App-only S&C auth for mls-verifier (Exchange.ManageAsApp + View-Only Configuration, granted at G0).'
    $thumbprint = Resolve-MlsInput -Name 'CertificateThumbprint' -Value $CertificateThumbprint -EnvironmentVariable @('MLS_VERIFIER_CERT') `
        -Hint 'Certificate thumbprint for the mls-verifier app-only S&C session.'
    $baselinePath = Resolve-MlsInput -Name 'LabelGuidPath' -Value $LabelGuidPath -EnvironmentVariable @('MLS_LABEL_GUID_PATH') `
        -DefaultValue (Join-Path -Path $repoRoot -ChildPath 'verification' -AdditionalChildPath 'reports', 'label-guids.json') `
        -Hint 'Recorded label GUID baseline.'

    $context = New-MlsAuditContext -Layer 4 -Title 'Purview sensitivity labels' `
        -ScriptName 'verification/layer-04-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry
    Add-MlsPreflight -Context $context -Name 'Organization' -Value $organizationName
    Add-MlsPreflight -Context $context -Name 'Checkpoint' -Value $Checkpoint
    Add-MlsPreflight -Context $context -Name 'Baseline file' -Value $baselinePath `
        -Status $(if (Test-Path -LiteralPath $baselinePath) { 'OK' } else { 'ABSENT' })

    if (-not $SkipConnect) {
        Connect-MlsCompliance -Organization $organizationName -AppId $appId -CertificateThumbprint $thumbprint
    }
    $baseline = Get-RecordedLabelGuid -Path $baselinePath

    Invoke-MlsCriterion -Context $context -Id 'V4.1' `
        -Description 'Get-Label returns the 4 labels with expected GUIDs recorded to verification/reports/' `
        -Command "Connect-IPPSSession -AppId <mls-verifier> -Organization $organizationName -CertificateThumbprint <thumbprint>`nGet-Label | Select-Object DisplayName, Guid | Where-Object DisplayName -in '$($ExpectedLabel -join "','")'" `
        -Expected "exactly 4 labels ($($ExpectedLabel -join ', ')); GUIDs equal to the recorded baseline when one exists" `
        -Test { Test-LabelTaxonomy -ExpectedLabel $ExpectedLabel -Baseline $baseline -Context $context } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V4.2' `
        -Description 'Labels survive a kill/rebuild cycle (checked again at L11)' `
        -Command "Get-Label  # re-read at checkpoint '$Checkpoint', compared against $baselinePath" `
        -Expected 'same 4 labels, same GUIDs as label-guids.json, at every checkpoint' -NoRetry `
        -Test { Test-LabelPersistence -ExpectedLabel $ExpectedLabel -Baseline $baseline -Checkpoint $Checkpoint } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V4.3' `
        -Description "Label policy exists, publishing the taxonomy to the demo groups (supplementary - L04.md Failure mode 5, F18)" `
        -Command "Connect-IPPSSession -AppId <mls-verifier> -Organization $organizationName -CertificateThumbprint <thumbprint>`nGet-LabelPolicy -Identity '$ExpectedLabelPolicy' | Select-Object Labels, ExchangeLocation" `
        -Expected "policy '$ExpectedLabelPolicy' exists; Labels == [$($ExpectedLabel -join ', ')]; ExchangeLocation == [$($ExpectedLabelPolicyScope -join ', ')]" `
        -Test { Test-LabelPolicyScope -PolicyName $ExpectedLabelPolicy -ExpectedLabel $ExpectedLabel -ExpectedScope $ExpectedLabelPolicyScope } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -Organization $Organization -VerifierAppId $VerifierAppId `
            -CertificateThumbprint $CertificateThumbprint -ExpectedLabel $ExpectedLabel `
            -LabelGuidPath $LabelGuidPath -Checkpoint $Checkpoint -ReportRoot $ReportRoot -NoRetry:$NoRetry `
            -ExpectedLabelPolicy $ExpectedLabelPolicy -ExpectedLabelPolicyScope $ExpectedLabelPolicyScope
    }
    catch {
        Write-MlsStatus -Message "layer-04-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
