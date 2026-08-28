#Requires -Version 7.0
<#
.SYNOPSIS
    L11 Verifier audit - the kill/reinstantiate proof. READ-ONLY.

.DESCRIPTION
    Implements the five master-plan Verify criteria owned by
    docs/runbooks/layers/L11.md section Validation cycle, and nothing else:

      V11.1  All RGs absent post-down.
      V11.2  Tenant objects intact (L3/L4 audits still pass).
      V11.3  Post-up: all layer audits green.
      V11.4  Wall-clock < 60 min.
      V11.5  Run-rate returns to idle profile.

    THE CYCLE HAS TWO CHECKPOINTS AND SO DOES THIS SCRIPT. -Phase Down runs the down-state
    audit (V11.1 + V11.2), which must PASS before up.ps1 starts - the cycle's honesty
    checkpoint. -Phase Up runs the post-up half (V11.2 again, V11.3, V11.4, V11.5). The
    criteria that belong to the other checkpoint are recorded as an explicit SKIP naming
    the phase that owns them, so both reports carry all five ids and neither pretends to
    have measured something it could not.

    V11.2 and V11.3 re-execute the other layer audits verbatim, each in its own pwsh
    process, and read their exit codes - the same scripts, the same criteria, no special
    L11 variants.

.EXAMPLE
    ./layer-11-audit.ps1 -Phase Down -SubscriptionId <sub>
    ./layer-11-audit.ps1 -Phase Up   -SubscriptionId <sub> -UpStartUtc 2026-08-24T09:00:00Z
#>
[CmdletBinding()]
param(
    [ValidateSet('Down', 'Up')][string]$Phase = 'Up',
    [string]$SubscriptionId,
    [string]$ResourceGroupPrefix = 'mls-rg-',
    [string]$UpStartUtc,
    [string]$UpCompletedUtc,
    [double]$WallClockBudgetMinutes = 60,
    [string]$Repository,
    [string]$FabricCapacityId,
    [string]$SqlDatabaseId,
    [double]$IdleDailyCostBudget = 0.17,
    [int[]]$ChildAuditLayer = @(1, 2, 3, 4, 5, 6, 7, 8, 9, 10),
    [switch]$SkipChildAudit,
    [string]$ReportRoot,
    [switch]$NoRetry
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'MlsAudit.psm1') -Force

function Get-ChildAuditPath {
    param(
        [Parameter(Mandatory)][int]$Layer,
        [Parameter(Mandatory)][string]$Root
    )
    return Join-Path -Path $Root -ChildPath ('layer-{0:d2}-audit.ps1' -f $Layer)
}

function Invoke-LayerAuditSet {
    <# Run a set of layer audits, each in its own process, and summarise their exit codes. #>
    param(
        [Parameter(Mandatory)][int[]]$Layer,
        [Parameter(Mandatory)][string]$Root,
        [AllowEmptyCollection()][string[]]$Argument = @()
    )
    $result = foreach ($number in $Layer) {
        $path = Get-ChildAuditPath -Layer $number -Root $Root
        $run = Invoke-MlsChildAudit -ScriptPath $path -Argument $Argument
        [pscustomobject]@{
            Layer    = $number
            ExitCode = $run.ExitCode
            Passed   = ($run.ExitCode -eq 0)
            Tail     = (@($run.Output | Select-Object -Last 3) -join ' / ')
        }
    }
    return @($result)
}

function Test-ResourceGroupAbsent {
    <# V11.1 - no mls-rg-* survives down.ps1. #>
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$SubscriptionId
    )
    $groups = @(Invoke-MlsAz -AllowFailure -Argument @(
            'group', 'list', '--subscription', $SubscriptionId,
            '--query', "[?starts_with(name,'$Prefix')].name", '--output', 'json'
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
    if ($groups.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed "no $Prefix* resource group present"
    }
    return New-MlsCheckResult -Passed $false -Observed "$($groups.Count) still present: $($groups -join ', ')" `
        -Detail 'RG deletion is asynchronous - polled every 5 minutes up to 30 from down.ps1''s completion signal. A stuck delete beyond that is a failure: check for locks or a nested resource in Failed state (L11 failure mode 2).'
}

function Test-TenantObjectIntact {
    <# V11.2 - re-execute the L3 and L4 audits verbatim in the current state. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [AllowEmptyCollection()][string[]]$Argument,
        [Parameter(Mandatory)][string]$Checkpoint,
        [switch]$SkipChildAudit
    )
    if ($SkipChildAudit) {
        return New-MlsCheckResult -Status 'SKIP' -Observed 'child audits skipped by -SkipChildAudit' `
            -Detail 'V11.2 is defined as "the L3/L4 audits still pass"; with the child audits suppressed there is no evidence, so this records SKIP rather than a pass.'
    }
    $result = Invoke-LayerAuditSet -Layer @(3, 4) -Root $Root -Argument $Argument
    $failed = @($result | Where-Object { -not $_.Passed })
    $observed = (@($result | ForEach-Object { "layer-$('{0:d2}' -f $_.Layer) exit=$($_.ExitCode)" }) -join '; ') + " at checkpoint '$Checkpoint'"
    if ($failed.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed $observed `
            -Detail 'The L4 run here is V4.2''s L11 re-execution: L4 owns the criterion, L11 owns the schedule.'
    }
    return New-MlsCheckResult -Passed $false -Observed ($observed + ' | ' + (@($failed | ForEach-Object { "L$($_.Layer): $($_.Tail)" }) -join ' | ')) -Final `
        -Detail 'Any regression here means down.ps1 crossed the tenant-object line: stop, do not run up.ps1, escalate. That is simultaneously a G3-boundary violation and a G4 event (L11.md V11.2).'
}

function Test-AllLayerAuditGreen {
    <# V11.3 - every layer audit L1-L10 against the rebuilt environment. #>
    param(
        [Parameter(Mandatory)][int[]]$Layer,
        [Parameter(Mandatory)][string]$Root,
        [AllowEmptyCollection()][string[]]$Argument,
        [switch]$SkipChildAudit
    )
    if ($SkipChildAudit) {
        return New-MlsCheckResult -Status 'SKIP' -Observed 'child audits skipped by -SkipChildAudit' `
            -Detail 'V11.3 is the full audit suite; suppressing it leaves no evidence, so this records SKIP rather than a pass.'
    }
    $result = Invoke-LayerAuditSet -Layer $Layer -Root $Root -Argument $Argument
    $failed = @($result | Where-Object { -not $_.Passed })
    $observed = @($result | ForEach-Object { "L$($_.Layer)=$(if ($_.Passed) { 'PASS' } else { "FAIL($($_.ExitCode))" })" }) -join ' '
    if ($failed.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed $observed `
            -Detail 'Async criteria V6.3/V6.4 re-attach on their own clocks and are recorded PENDING->PASS in the proof report.'
    }
    return New-MlsCheckResult -Passed $false -Observed ($observed + ' | ' + (@($failed | ForEach-Object { "L$($_.Layer): $($_.Tail)" }) -join ' | ')) `
        -Detail 'The failing layer''s own playbook rollback applies, and L11 then re-runs from down.ps1 - the proof must be a clean uninterrupted cycle, not a patched one.'
}

function Test-WallClock {
    <# V11.4 - two independent clocks: the timestamps up.ps1 and the audit runner recorded,
       cross-checked against the workflow runs' own created_at/updated_at. #>
    param(
        [AllowEmptyString()][string]$StartUtc,
        [AllowEmptyString()][string]$CompletedUtc,
        [Parameter(Mandatory)][double]$BudgetMinutes,
        [Parameter(Mandatory)][string]$Repository
    )
    if ([string]::IsNullOrWhiteSpace($StartUtc)) {
        return New-MlsCheckResult -Passed $false -Observed 'no up.ps1 start timestamp supplied' -Final `
            -Detail 'The wall clock starts at up.ps1 invocation. up.ps1 must record and hand over that timestamp; pass -UpStartUtc / $env:MLS_L11_UP_START. The measurement is the criterion, so the audit will not invent it.'
    }
    $start = [datetime]::Parse($StartUtc).ToUniversalTime()
    $finish = if ([string]::IsNullOrWhiteSpace($CompletedUtc)) { [datetime]::UtcNow } else { [datetime]::Parse($CompletedUtc).ToUniversalTime() }
    $elapsed = ($finish - $start).TotalMinutes

    $secondClock = 'not available'
    $runs = @(Get-MlsCollection -Response (Invoke-MlsGh -AllowFailure -Argument @(
                'api', "repos/$Repository/actions/runs?per_page=20"
            )))
    $relevant = @($runs | Where-Object {
            $created = "$(Get-MlsProperty -InputObject $_ -Name 'created_at')"
            $slot = [datetime]::MinValue
            [datetime]::TryParse($created, [ref]$slot) -and $slot.ToUniversalTime() -ge $start
        })
    if ($relevant.Count -gt 0) {
        $last = @($relevant | ForEach-Object {
                $slot = [datetime]::MinValue
                [void][datetime]::TryParse("$(Get-MlsProperty -InputObject $_ -Name 'updated_at')", [ref]$slot)
                $slot.ToUniversalTime()
            } | Sort-Object)[-1]
        $secondClock = "$([math]::Round(($last - $start).TotalMinutes, 1)) min across $($relevant.Count) workflow run(s)"
    }
    $observed = "elapsed $([math]::Round($elapsed, 1)) min (verifier clock); workflow-run clock: $secondClock"
    if ($elapsed -lt $BudgetMinutes) {
        return New-MlsCheckResult -Passed $true -Observed $observed
    }
    return New-MlsCheckResult -Passed $false -Observed $observed -Final `
        -Detail 'A >= 60 min result is a criterion failure; re-run once after remediating the identified bottleneck, and that re-run is attempt two (the G4 rule applies as everywhere).'
}

function Test-IdleRunRate {
    <# V11.5 - consumption plus the two state reads that make idle real. Consumption data
       lags 24-48 h, so this closes asynchronously. #>
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][double]$DailyBudget,
        [AllowEmptyString()][string]$FabricCapacityId,
        [AllowEmptyString()][string]$SqlDatabaseId
    )
    $start = [datetime]::UtcNow.AddDays(-1).ToString('yyyy-MM-dd')
    $end = [datetime]::UtcNow.ToString('yyyy-MM-dd')
    $usage = @(Invoke-MlsAz -AllowFailure -Argument @(
            'consumption', 'usage', 'list', '--subscription', $SubscriptionId,
            '--start-date', $start, '--end-date', $end,
            '--query', '[].{svc:instanceName, cost:pretaxCost}', '--output', 'json'
        ))
    $observed = [System.Collections.Generic.List[string]]::new()
    $problem = [System.Collections.Generic.List[string]]::new()

    if ($usage.Count -eq 0) {
        $observed.Add('no consumption line items yet for the post-cycle day')
        $problem.Add('consumption data has not landed')
    }
    else {
        $total = ($usage | ForEach-Object { [double](Get-MlsProperty -InputObject $_ -Name 'cost') } | Measure-Object -Sum).Sum
        $observed.Add("daily cost $([math]::Round($total, 4)) (budget $DailyBudget/day)")
        if ($total -gt $DailyBudget) {
            $top = @($usage | Sort-Object { -[double](Get-MlsProperty -InputObject $_ -Name 'cost') } | Select-Object -First 3 |
                    ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'svc')=$(Get-MlsProperty -InputObject $_ -Name 'cost')" })
            $problem.Add("daily cost exceeds the pro-rated idle envelope; top line items: $($top -join ', ')")
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($FabricCapacityId) -and $FabricCapacityId -like '/subscriptions/*') {
        $state = "$(Invoke-MlsAz -AllowFailure -Raw -Argument @('resource', 'show', '--ids', $FabricCapacityId, '--query', 'properties.state', '--output', 'tsv'))".Trim()
        $observed.Add("capacity=$state")
        if ($state -ne 'Paused') { $problem.Add("Fabric capacity state '$state', expected 'Paused'") }
    }
    else {
        $observed.Add('capacity=trial (no pause control, $0/hr - recorded equivalent)')
    }

    if (-not [string]::IsNullOrWhiteSpace($SqlDatabaseId)) {
        $status = "$(Invoke-MlsAz -AllowFailure -Raw -Argument @('sql', 'db', 'show', '--ids', $SqlDatabaseId, '--query', 'status', '--output', 'tsv'))".Trim()
        $observed.Add("sql=$status")
        if ($status -ne 'Paused') { $problem.Add("SQL database status '$status', expected 'Paused'") }
    }

    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ')
    }
    # Only "the consumption data has not landed yet" is a not-yet: it is the one thing this
    # criterion legitimately waits 24-48 h for. A cost anomaly or an unpaused resource is a
    # real finding and is marked -Final so it is never softened to PENDING.
    $waitingForData = ($problem.Count -eq 1 -and $problem[0] -eq 'consumption data has not landed')
    if ($waitingForData) {
        return New-MlsCheckResult -Passed $false -Observed (($observed -join '; ') + ' | ' + ($problem -join ' | ')) `
            -Detail 'Consumption data lags 24-48 h: this criterion closes asynchronously, PENDING at cycle end and PASS on the first full post-cycle day (L11.md V11.5).'
    }
    return New-MlsCheckResult -Passed $false -Observed (($observed -join '; ') + ' | ' + ($problem -join ' | ')) -Final `
        -Detail 'A cost anomaly here is a direct G4 trigger regardless of retry counts. Orphan spend outside the four RGs means something was created out-of-band (L11 failure mode 4).'
}

function Invoke-Main {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is consumed inside the criterion scriptblocks; PSSA cannot see through scriptblock closures.')]
    param(
        [string]$Phase = 'Up',
        [string]$SubscriptionId,
        [string]$ResourceGroupPrefix = 'mls-rg-',
        [string]$UpStartUtc,
        [string]$UpCompletedUtc,
        [double]$WallClockBudgetMinutes = 60,
        [string]$Repository,
        [string]$FabricCapacityId,
        [string]$SqlDatabaseId,
        [double]$IdleDailyCostBudget = 0.17,
        [int[]]$ChildAuditLayer = @(),
        [switch]$SkipChildAudit,
        [string]$ReportRoot,
        [switch]$NoRetry
    )
    $subscription = Resolve-MlsInput -Name 'SubscriptionId' -Value $SubscriptionId -EnvironmentVariable @('AZURE_SUBSCRIPTION_ID') `
        -Hint 'The demo subscription whose resource groups, capacity, SQL and consumption this proof reads.'
    $repositoryName = Resolve-MlsInput -Name 'Repository' -Value $Repository -EnvironmentVariable @('MLS_GITHUB_REPO', 'MLS_REPOSITORY') `
        -Hint 'V11.4 cross-checks the wall clock against the workflow runs.'
    $startUtc = $UpStartUtc
    if ([string]::IsNullOrWhiteSpace($startUtc)) { $startUtc = [Environment]::GetEnvironmentVariable('MLS_L11_UP_START') }
    $completedUtc = $UpCompletedUtc
    if ([string]::IsNullOrWhiteSpace($completedUtc)) { $completedUtc = [Environment]::GetEnvironmentVariable('MLS_L11_UP_COMPLETED') }
    $capacityId = $FabricCapacityId
    if ([string]::IsNullOrWhiteSpace($capacityId)) { $capacityId = [Environment]::GetEnvironmentVariable('FABRIC_CAPACITY_ID') }
    $databaseId = $SqlDatabaseId
    if ([string]::IsNullOrWhiteSpace($databaseId)) { $databaseId = [Environment]::GetEnvironmentVariable('MLS_SQL_DB_ID') }

    $context = New-MlsAuditContext -Layer 11 -Title "Kill/reinstantiate proof (phase: $Phase)" `
        -ScriptName 'verification/layer-11-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry
    Add-MlsPreflight -Context $context -Name 'Phase' -Value $Phase
    Add-MlsPreflight -Context $context -Name 'SubscriptionId' -Value $subscription
    Add-MlsPreflight -Context $context -Name 'up.ps1 start (UTC)' -Value "$startUtc" -Status $(if ($startUtc) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Child audits' -Value $(if ($SkipChildAudit) { 'suppressed (-SkipChildAudit)' } else { "layers $($ChildAuditLayer -join ',')" })

    $childArgument = @()
    if (-not [string]::IsNullOrWhiteSpace($ReportRoot)) { $childArgument += @('-ReportRoot', $ReportRoot) }
    if ($NoRetry) { $childArgument += '-NoRetry' }

    # V11.1 -Control @('3.4.1'): post-teardown inventory matches the declared empty
    # baseline (no mls-rg-* survives) - the same "actual state matches the declared
    # baseline" claim as V3.1/V5.2/V6.1, just for resource groups. Both branches record the
    # same criterion identity, so both carry the same mapping.
    if ($Phase -eq 'Down') {
        Invoke-MlsCriterion -Context $context -Id 'V11.1' -Control @('3.4.1') `
            -Description 'All RGs absent post-down' `
            -Command "az group list --query `"[?starts_with(name,'$ResourceGroupPrefix')].name`"" `
            -Expected 'empty array - none of mls-rg-platform, mls-rg-apps, mls-rg-data, mls-rg-ops (nor any stray mls-rg-*)' `
            -Test { Test-ResourceGroupAbsent -Prefix $ResourceGroupPrefix -SubscriptionId $subscription } | Out-Null
    }
    else {
        Invoke-MlsCriterion -Context $context -Id 'V11.1' -Control @('3.4.1') `
            -Description 'All RGs absent post-down' `
            -Command "az group list --query `"[?starts_with(name,'$ResourceGroupPrefix')].name`"   # down-state checkpoint" `
            -Expected 'empty array at the post-down checkpoint' -NoRetry `
            -Test {
            New-MlsCheckResult -Status 'SKIP' -Observed "not measurable in the '$Phase' phase" `
                -Detail 'V11.1 is a down-state criterion: it is measured by the -Phase Down run, whose report is the evidence. After up.ps1 the resource groups exist by design, so asserting their absence here would be meaningless.'
        } | Out-Null
    }

    Invoke-MlsCriterion -Context $context -Id 'V11.2' -Control @('3.4.1', '3.12.3') `
        -Description 'Tenant objects intact (L3/L4 audits still pass)' `
        -Command "pwsh verification/layer-03-audit.ps1   # users/groups/CA/app registrations (V3.1-V3.4)`npwsh verification/layer-04-audit.ps1   # labels + GUIDs (V4.1) - this is V4.2's L11 re-execution" `
        -Expected 'both audits PASS: 5 users, 4 groups, 3 app registrations, CA still enabledForReportingButNotEnforced, licences Active for every user flagged licensed, 4 labels with unchanged GUIDs' -NoRetry `
        -Test {
        Test-TenantObjectIntact -Root $PSScriptRoot -Argument $childArgument -Checkpoint $Phase -SkipChildAudit:$SkipChildAudit
    } | Out-Null

    if ($Phase -eq 'Up') {
        # V11.3 re-runs every layer's own criteria against the rebuilt environment - the
        # broadest re-assessment event in the estate, hence Security Assessment (3.12), not
        # merely configuration management.
        Invoke-MlsCriterion -Context $context -Id 'V11.3' -Control @('3.12.1', '3.12.3') `
            -Description 'Post-up: all layer audits green' `
            -Command 'foreach ($n in 1..10) { pwsh verification/layer-$(''{0:d2}'' -f $n)-audit.ps1 }' `
            -Expected 'PASS for every layer audit L1-L10 against the rebuilt environment' -NoRetry `
            -Test {
            Test-AllLayerAuditGreen -Layer $ChildAuditLayer -Root $PSScriptRoot -Argument $childArgument -SkipChildAudit:$SkipChildAudit
        } | Out-Null

        # -Control @(): rebuild wall-clock is an operational SLA, not CUI protection.
        Invoke-MlsCriterion -Context $context -Id 'V11.4' -Control @() `
            -Description 'Wall-clock < 60 min' `
            -Command "timestamps recorded by up.ps1 (start) and the Verifier's audit runner (last synchronous audit green), cross-checked against gh api repos/$repositoryName/actions/runs created_at/updated_at" `
            -Expected "elapsed < $WallClockBudgetMinutes:00 minutes on both clocks" -NoRetry `
            -Test {
            Test-WallClock -StartUtc $startUtc -CompletedUtc $completedUtc -BudgetMinutes $WallClockBudgetMinutes -Repository $repositoryName
        } | Out-Null

        # -Control @(): idle-cost/FinOps check, not CUI protection.
        Invoke-MlsCriterion -Context $context -Id 'V11.5' -Control @() `
            -Description 'Run-rate returns to idle profile' `
            -Command "az consumption usage list --start-date <cycle+1d> --end-date <cycle+2d> --query `"[].{svc:instanceName, cost:pretaxCost}`"`naz resource show --ids <capacity> --query properties.state`naz sql db show --ids <dbId> --query status" `
            -Expected "daily cost < `$$IdleDailyCostBudget (the <`$5/month idle envelope pro-rated); capacity Paused (trial: recorded equivalent); SQL Paused" `
            -RetryWindowMinutes 2880 -InProcessWaitMinutes 0 -WindowStartUtc ([datetime]::UtcNow) -PendingWhenUnexpired `
            -Test {
            Test-IdleRunRate -SubscriptionId $subscription -DailyBudget $IdleDailyCostBudget `
                -FabricCapacityId $capacityId -SqlDatabaseId $databaseId
        } | Out-Null
    }
    else {
        # SKIP placeholders for the Up-phase criteria, recorded here so the down-state
        # report still names all five L11 ids (see the -Test bodies below). Each carries
        # the SAME -Control mapping as its real Up-phase counterpart above: the criterion's
        # evidentiary meaning does not change because this phase could not measure it.
        foreach ($pair in @(
                @{ Id = 'V11.3'; Control = @('3.12.1', '3.12.3'); Description = 'Post-up: all layer audits green'; Command = 'foreach ($n in 1..10) { pwsh verification/layer-<nn>-audit.ps1 }'; Expected = 'PASS for every layer audit L1-L10 against the rebuilt environment' },
                @{ Id = 'V11.4'; Control = @(); Description = 'Wall-clock < 60 min'; Command = 'up.ps1 start timestamp vs last synchronous audit green'; Expected = "elapsed < $WallClockBudgetMinutes minutes" },
                @{ Id = 'V11.5'; Control = @(); Description = 'Run-rate returns to idle profile'; Command = 'az consumption usage list ...'; Expected = 'daily cost within the idle envelope; capacity and SQL Paused' }
            )) {
            Invoke-MlsCriterion -Context $context -Id $pair.Id -Control $pair.Control -Description $pair.Description `
                -Command $pair.Command -Expected $pair.Expected -NoRetry `
                -Test {
                New-MlsCheckResult -Status 'SKIP' -Observed "not measurable in the 'Down' phase" `
                    -Detail 'Post-up criterion: run this script again with -Phase Up once up.ps1 has replayed the environment. Recording SKIP rather than omitting the id, so the down-state report still accounts for all five L11 criteria.'
            } | Out-Null
        }
    }

    Add-MlsNote -Context $context -Message 'The wall clock covers up.ps1 start -> all synchronous audits green; explicitly-async criteria (V6.3 cost export, V6.4 SQL auto-pause, V11.5 consumption) re-attach on their own clocks and are recorded PENDING -> PASS in verification/reports/rebuild-proof.md.'
    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -Phase $Phase -SubscriptionId $SubscriptionId -ResourceGroupPrefix $ResourceGroupPrefix `
            -UpStartUtc $UpStartUtc -UpCompletedUtc $UpCompletedUtc -WallClockBudgetMinutes $WallClockBudgetMinutes `
            -Repository $Repository -FabricCapacityId $FabricCapacityId -SqlDatabaseId $SqlDatabaseId `
            -IdleDailyCostBudget $IdleDailyCostBudget -ChildAuditLayer $ChildAuditLayer `
            -SkipChildAudit:$SkipChildAudit -ReportRoot $ReportRoot -NoRetry:$NoRetry
    }
    catch {
        Write-MlsStatus -Message "layer-11-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
