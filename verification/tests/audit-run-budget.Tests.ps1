# An audit that runs out of time must still file a report.
#
# L2 declares three criteria at the standard 30-minute retry window. The per-criterion
# window was bounded; the RUN was not, so the worst case was 90 minutes inside a job whose
# timeout-minutes is 60. There was never any margin - V2.3 legitimately waits out the NIST
# assignment's own 30-minute compliance scan, so one unexpected failure anywhere else was
# enough to reach the runner's limit. The job was killed mid-criterion and uploaded
# nothing at all: not the report, not the transcript, not the reason (F58).
#
# The fix is a run-level budget that clamps each criterion to the time actually left. That
# budget only works while it stays SMALLER than the job timeout that kills it, and those
# two numbers live in different files. This is what keeps them related.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowDir = Join-Path $script:RepoRoot '.github' 'workflows'
    $script:ActionFile = Join-Path $script:RepoRoot '.github' 'actions' 'layer-audit' 'action.yml'

    # What the job needs AFTER the last retry gives up: write the Markdown and JSON
    # reports, echo the transcript, upload the artifact, post the step summary.
    $script:ReportMarginMinutes = 10

    function Get-MlsActionBudgetDefault {
        <# The `run-budget-minutes` default declared by the layer-audit action. #>
        $action = Get-Content -LiteralPath $script:ActionFile -Raw
        $match = [regex]::Match($action, "run-budget-minutes:[\s\S]*?default:\s*'(\d+)'")
        if (-not $match.Success) { return 0 }
        return [int]$match.Groups[1].Value
    }

    function Get-MlsAuditJob {
        <#
            Every job in .github/workflows that runs the layer-audit action, with the
            job's timeout-minutes and each audit step's effective run budget.

            Text parsing, not a YAML parser: it matches how the rest of verification/tests
            reads these files, and the shapes it must recognise are fixed by this repo's
            own conventions (jobs at two spaces, steps at eight).
        #>
        $jobs = [System.Collections.Generic.List[object]]::new()
        foreach ($file in (Get-ChildItem -Path $script:WorkflowDir -Filter '*.yml' -File)) {
            $lines = Get-Content -LiteralPath $file.FullName
            $inJobs = $false
            $starts = [System.Collections.Generic.List[int]]::new()
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^jobs:\s*$') { $inJobs = $true; continue }
                if ($inJobs -and $lines[$i] -match '^[A-Za-z]') { $inJobs = $false }
                if ($inJobs -and $lines[$i] -match '^  [A-Za-z0-9_.-]+:\s*$') { $starts.Add($i) }
            }
            $starts.Add($lines.Count)

            for ($s = 0; $s -lt $starts.Count - 1; $s++) {
                $from = $starts[$s]
                $to = $starts[$s + 1]
                $block = $lines[$from..($to - 1)]
                $text = $block -join "`n"
                if ($text -notmatch 'actions/layer-audit') { continue }

                $timeout = if ($text -match '(?m)^    timeout-minutes:\s*(\d+)') { [int]$Matches[1] } else { $null }

                # One entry per audit STEP, because a job may hold more than one.
                $budgets = [System.Collections.Generic.List[object]]::new()
                for ($i = 0; $i -lt $block.Count; $i++) {
                    if ($block[$i] -notmatch 'uses:\s*\./\.github/actions/layer-audit') { continue }
                    # The step's own `with:` runs until the next step (a line starting "- ").
                    $end = $block.Count
                    for ($j = $i + 1; $j -lt $block.Count; $j++) {
                        if ($block[$j] -match '^\s*- ') { $end = $j; break }
                    }
                    $stepTail = ($block[$i..($end - 1)]) -join "`n"
                    # `if:` is declared before `uses:`, so look back to the step's start.
                    $start = 0
                    for ($j = $i; $j -ge 0; $j--) {
                        if ($block[$j] -match '^\s*- ') { $start = $j; break }
                    }
                    $stepText = ($block[$start..($end - 1)]) -join "`n"
                    $budget = if ($stepTail -match "run-budget-minutes:\s*['`"]?(\d+)") { [int]$Matches[1] } else { $null }
                    $budgets.Add([pscustomobject]@{
                            Budget    = $budget
                            Guarded   = ($stepText -match '(?m)^\s*if:\s*')
                            Line      = $from + $i + 1
                        })
                }

                $jobs.Add([pscustomobject]@{
                        File     = $file.Name
                        Job      = $block[0].Trim().TrimEnd(':')
                        Timeout  = $timeout
                        Steps    = $budgets
                    })
            }
        }
        return $jobs
    }
}

Describe 'the audit always has time left to write its report' {

    It 'finds the audit jobs at all' {
        # A parser that silently matches nothing would make every assertion below vacuous -
        # the mirror this repo does not accept as a test.
        @(Get-MlsAuditJob).Count | Should -BeGreaterThan 5 -Because 'most layers run a layer-audit step'
    }

    It 'every job that runs an audit declares a timeout' {
        $missing = @(Get-MlsAuditJob | Where-Object { $null -eq $_.Timeout } |
                ForEach-Object { "$($_.File):$($_.Job)" })
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'a run budget is only meaningful against a known job timeout'
    }

    It 'the action default and the module default are the same number' {
        # Two files, one value. If they drift, a workflow that sets nothing gets a budget
        # the test below was never checking (CLAUDE.md: every value has one source).
        $actionDefault = Get-MlsActionBudgetDefault
        $actionDefault | Should -BeGreaterThan 0 -Because 'the action must declare a default budget'

        $module = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'verification' 'MlsAudit.psm1') -Raw
        $moduleMatch = [regex]::Match($module, '\$script:DefaultRunBudgetMinutes\s*=\s*(\d+)')
        $moduleMatch.Success | Should -BeTrue -Because 'the module must declare a default budget'
        [int]$moduleMatch.Groups[1].Value | Should -Be $actionDefault -Because 'the action passes its default through to the module as an env var'
    }

    It 'every audit step leaves the report margin inside its job timeout' {
        $default = Get-MlsActionBudgetDefault

        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($job in Get-MlsAuditJob) {
            foreach ($step in $job.Steps) {
                $budget = if ($null -eq $step.Budget) { $default } else { $step.Budget }
                if (($budget + $script:ReportMarginMinutes) -gt $job.Timeout) {
                    $offender.Add("$($job.File):$($step.Line) budget $budget + margin $($script:ReportMarginMinutes) > timeout $($job.Timeout)")
                }
            }
        }
        $offender -join '; ' | Should -BeNullOrEmpty -Because 'the runner kills the job at timeout-minutes, and a killed audit reports nothing'
    }

    It 'a job running more than one audit guards each of them' {
        # Steps run sequentially, so two UNCONDITIONAL audits share one timeout and the
        # per-step check above would not see it. L6 has two and they are mutually
        # exclusive on verify_only; an unguarded pair would not be.
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($job in (Get-MlsAuditJob | Where-Object { $_.Steps.Count -gt 1 })) {
            foreach ($step in ($job.Steps | Where-Object { -not $_.Guarded })) {
                $offender.Add("$($job.File):$($step.Line)")
            }
        }
        $offender -join ', ' | Should -BeNullOrEmpty -Because 'two audits that can both run share one job timeout'
    }
}

Describe 'the run budget actually clamps a criterion' {

    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'verification' 'MlsAudit.psm1') -Force
    }

    It 'reads the budget from MLS_AUDIT_RUN_BUDGET_MINUTES' {
        $env:MLS_AUDIT_RUN_BUDGET_MINUTES = '7'
        try {
            $context = New-MlsAuditContext -Layer 2 -Title 't' -ScriptName 's' -ReportRoot $TestDrive
            $context.RunBudgetMinutes | Should -Be 7
            ($context.DeadlineUtc - $context.StartedUtc).TotalMinutes | Should -BeGreaterThan 6.9
        }
        finally { Remove-Item Env:\MLS_AUDIT_RUN_BUDGET_MINUTES -ErrorAction SilentlyContinue }
    }

    It 'ignores a junk budget rather than deadlining immediately' {
        # An unset-variable expansion produces an empty string, and "0 minutes of budget"
        # would silently turn every retry off - a failure that looks like a pass.
        foreach ($junk in @('', '   ', 'abc', '0', '-5')) {
            $env:MLS_AUDIT_RUN_BUDGET_MINUTES = $junk
            try {
                $context = New-MlsAuditContext -Layer 2 -Title 't' -ScriptName 's' -ReportRoot $TestDrive
                $context.RunBudgetMinutes | Should -BeGreaterThan 0 -Because "'$junk' is not a budget"
            }
            finally { Remove-Item Env:\MLS_AUDIT_RUN_BUDGET_MINUTES -ErrorAction SilentlyContinue }
        }
    }

    It 'stops retrying when the run deadline has passed, and says why' {
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'
        $context = New-MlsAuditContext -Layer 2 -Title 't' -ScriptName 's' -ReportRoot $TestDrive `
            -RetryWindowMinutes 30 -PollIntervalSeconds 1 -RunBudgetMinutes 30
        # The run has already used its whole budget.
        $context.DeadlineUtc = [datetime]::UtcNow.AddMinutes(-1)

        $row = Invoke-MlsCriterion -Context $context -Id 'V2.1' -Description 'would retry forever' `
            -Command 'c' -Expected 'e' -Test { New-MlsCheckResult -Passed $false -Observed 'not yet' }

        $row.Status | Should -Be 'FAIL'
        $row.Attempt | Should -Be 1 -Because 'the check still runs once; only the waiting is skipped'
        Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 0
        $row.Detail | Should -Match 'run budget exhausted' -Because 'a truncated window must never read like a completed one'
    }

    It 'leaves a criterion its full window while budget remains' {
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'
        $context = New-MlsAuditContext -Layer 2 -Title 't' -ScriptName 's' -ReportRoot $TestDrive `
            -RetryWindowMinutes 30 -PollIntervalSeconds 600 -RunBudgetMinutes 45

        $script:calls = 0
        $row = Invoke-MlsCriterion -Context $context -Id 'V2.2' -Description 'lags then passes' `
            -Command 'c' -Expected 'e' -Test {
            $script:calls++
            New-MlsCheckResult -Passed ($script:calls -gt 1) -Observed "call $script:calls"
        }

        $row.Status | Should -Be 'PASS'
        Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 1 `
            -Because 'a healthy run must still wait out genuine propagation'
        $row.Detail | Should -Not -Match 'run budget exhausted'
    }
}

Describe 'a unit test cannot reach the network by accident' {
    # Every test file here claims "every transport is mocked; zero cloud calls", and that
    # claim was enforced by nothing. A mock declared `-ModuleName 'MlsAudit'` intercepts
    # calls from INSIDE the module and not from a dot-sourced audit script, so the mock looks
    # present, the test looks meaningful, and the transport quietly runs for real - which is
    # how three tests read live tenant data before a Graph 404 naming a fixture-only user
    # gave it away (F74).

    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'verification' 'MlsAudit.psm1') -Force
    }

    It 'refuses an az call while Pester is loaded' {
        InModuleScope 'MlsAudit' {
            { Assert-MlsTransportAllowed -FilePath 'az' -Description 'az account show' } |
                Should -Throw '*Refusing a live transport call*'
        }
    }

    It 'names the usual cause, because the usual cause is a mis-scoped mock' {
        InModuleScope 'MlsAudit' {
            $message = try { Assert-MlsTransportAllowed -FilePath 'gh' -Description 'gh api repos/o/r'; '' }
            catch { $_.Exception.Message }
            $message | Should -BeLike '*-ModuleName*'
        }
    }

    It 'allows a local process, which is not a network call' {
        # The bounded runner spawns pwsh in its own tests. A guard that blocked those would
        # get switched off rather than trusted.
        InModuleScope 'MlsAudit' {
            { Assert-MlsTransportAllowed -FilePath 'pwsh' -Description 'pwsh -Command x' } | Should -Not -Throw
        }
    }

    It 'allows a deliberate live call when the caller says so out loud' {
        InModuleScope 'MlsAudit' {
            $env:MLS_ALLOW_LIVE_TRANSPORT = '1'
            try {
                { Assert-MlsTransportAllowed -FilePath 'az' -Description 'az account show' } | Should -Not -Throw
            }
            finally { Remove-Item Env:\MLS_ALLOW_LIVE_TRANSPORT -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'a transport call cannot outlive its timeout' {

    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'verification' 'MlsAudit.psm1') -Force
    }

    # Deliberately NOT mocked. The defect was that `& az ...` had no ceiling at all, so a
    # test that mocks the process proves nothing about the thing that failed: L2's job was
    # killed with the az process still live ("Terminate orphan process: pid (3399)
    # (python3)"). These run a real child process and really wait for it.

    It 'kills a command that outlives the timeout and says so' {
        InModuleScope 'MlsAudit' {
            $started = [datetime]::UtcNow
            $run = Invoke-MlsBoundedNativeCommand -FilePath 'pwsh' -TimeoutSeconds 2 `
                -Argument @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30')
            $elapsed = ([datetime]::UtcNow - $started).TotalSeconds

            $run.TimedOut | Should -BeTrue
            $elapsed | Should -BeLessThan 25 -Because 'the point is that it returns instead of hanging'
        }
    }

    It 'returns stdout and the exit code when the command finishes' {
        InModuleScope 'MlsAudit' {
            $run = Invoke-MlsBoundedNativeCommand -FilePath 'pwsh' -TimeoutSeconds 60 `
                -Argument @('-NoProfile', '-NonInteractive', '-Command', 'Write-Output hello')
            $run.TimedOut | Should -BeFalse
            $run.ExitCode | Should -Be 0
            $run.StdOut.Trim() | Should -Be 'hello'
        }
    }

    It 'captures stderr instead of discarding it' {
        # The old call ended in `2>$null`, so a failing az could only ever report an exit
        # code and the reason was thrown away.
        InModuleScope 'MlsAudit' {
            $run = Invoke-MlsBoundedNativeCommand -FilePath 'pwsh' -TimeoutSeconds 60 `
                -Argument @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Error.WriteLine(''boom'')')
            $run.StdErr | Should -Match 'boom'
        }
    }

    It 'propagates a non-zero exit code' {
        InModuleScope 'MlsAudit' {
            $run = Invoke-MlsBoundedNativeCommand -FilePath 'pwsh' -TimeoutSeconds 60 `
                -Argument @('-NoProfile', '-NonInteractive', '-Command', 'exit 3')
            $run.TimedOut | Should -BeFalse
            $run.ExitCode | Should -Be 3
        }
    }

    It 'passes an argument containing spaces and quotes through as ONE argument' {
        # Start-Process -ArgumentList joins the array with spaces and quotes nothing, so
        # V2.1's own query - `--query "children[?contains(id, '<sub>')].displayName"` - would
        # have arrived as two arguments. This is the shape of the real call.
        $echoArgs = Join-Path $TestDrive 'echo-args.ps1'
        Set-Content -LiteralPath $echoArgs -Value '$args.Count; $args[0]' -Encoding utf8
        $query = "children[?contains(id, 'abc')].displayName"

        InModuleScope 'MlsAudit' -Parameters @{ ScriptFile = $echoArgs; Query = $query } {
            $run = Invoke-MlsBoundedNativeCommand -FilePath 'pwsh' -TimeoutSeconds 60 `
                -Argument @('-NoProfile', '-NonInteractive', '-File', $ScriptFile, $Query)
            $run.TimedOut | Should -BeFalse
            $lines = @($run.StdOut -split "`r?`n" | Where-Object { $_ -ne '' })
            $lines[0] | Should -Be '1' -Because 'the query must not be split on its spaces'
            $lines[1] | Should -Be $Query
        }
    }

    It 'a timed-out az throws even under -AllowFailure' {
        # -AllowFailure means "this command may legitimately come back empty-handed". A hang
        # means we never found out, and reporting "not there" for "could not tell" is the
        # confusion F57 was about.
        InModuleScope 'MlsAudit' {
            Mock Invoke-MlsBoundedNativeCommand { [pscustomobject]@{ TimedOut = $true; ExitCode = -1; StdOut = ''; StdErr = '' } }
            Mock Assert-MlsCommand {}
            { Invoke-MlsAz -Argument @('account', 'show') -AllowFailure } |
                Should -Throw -ExpectedMessage '*did not return within*'
        }
    }
}

Describe 'a layer cannot declare more patience than its run budget' {

    # The run budget (F58) stops an over-patient audit from being KILLED. It does not stop it
    # from being over-patient: a layer whose criteria sum past the budget still gets its last
    # checks truncated, and a truncated window is a half-measured answer.
    #
    # This is the arithmetic nobody did. L2 declared three criteria at the inherited
    # 30-minute default - 90 minutes inside a 60-minute job. L3 declares four, none of them
    # explicit: two hours. Every one of those windows was inherited rather than chosen, which
    # is why right-sizing the DEFAULT was the fix and not right-sizing L2 (F59).

    BeforeAll {
        $script:ModuleText = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'verification' 'MlsAudit.psm1') -Raw

        function Get-MlsDefaultWindow {
            $m = [regex]::Match($script:ModuleText, '\$script:StandardRetryWindowMinutes\s*=\s*([\d.]+)')
            if (-not $m.Success) { return -1 }
            return [double]$m.Groups[1].Value
        }

        function Get-MlsLayerWindowPlan {
            <#
                For each verification/layer-NN-audit.ps1, the in-process wait each criterion
                can actually block for:
                  -InProcessWaitMinutes N  -> N   (the 24 h criteria pass 0 and record PENDING)
                  -NoRetry                 -> 0
                  -RetryWindowMinutes N    -> N
                  otherwise                -> the module default
            #>
            $default = Get-MlsDefaultWindow
            $out = [System.Collections.Generic.List[object]]::new()
            foreach ($file in (Get-ChildItem -Path (Join-Path $script:RepoRoot 'verification') -Filter 'layer-*-audit.ps1' -File)) {
                $text = Get-Content -LiteralPath $file.FullName -Raw
                $calls = $text -split 'Invoke-MlsCriterion' | Select-Object -Skip 1
                $total = 0.0
                $count = 0
                $max = 0.0
                $implicitCount = 0
                foreach ($call in $calls) {
                    # A criterion's arguments end at the pipe that consumes its result.
                    $seg = ($call -split '\|\s*Out-Null')[0]
                    $count++
                    # DECLARED and NUMERIC are different questions. V6.4 passes
                    # `-RetryWindowMinutes $SqlIdleWindowMinutes` - a variable, so its window
                    # is chosen but not readable here. Treating "not a literal" as "not
                    # declared" reported a properly-declared criterion as an orphan.
                    $declared = $seg -match '-InProcessWaitMinutes\b' -or
                    $seg -match '-RetryWindowMinutes\b' -or
                    $seg -match '-NoRetry\b'
                    if (-not $declared) { $implicitCount++ }

                    $window = if ($seg -match '-InProcessWaitMinutes\s+([\d.]+)') { [double]$Matches[1] }
                    elseif ($seg -match '-NoRetry\b') { 0.0 }
                    elseif ($seg -match '-RetryWindowMinutes\s+([\d.]+)') { [double]$Matches[1] }
                    elseif ($declared) { $null }
                    else { $default }

                    if ($null -ne $window) {
                        $total += $window
                        if ($window -gt $max) { $max = $window }
                    }
                }
                $out.Add([pscustomobject]@{
                        File               = $file.Name
                        Criteria           = $count
                        TotalWindowMinutes = $total
                        MaxWindowMinutes   = $max
                        Implicit           = $implicitCount
                    })
            }
            return $out
        }
    }

    It 'reads a plausible default window' {
        Get-MlsDefaultWindow | Should -BeGreaterThan 0
    }

    It 'finds criteria in every layer audit' {
        $layers = @(Get-MlsLayerWindowPlan)
        $layers.Count | Should -BeGreaterThan 8
        @($layers | Where-Object { $_.Criteria -eq 0 }) | Should -BeNullOrEmpty -Because 'a layer audit with no criteria would make this vacuous'
    }

    It 'no single criterion may declare more patience than the whole run has' {
        # NOT the sum. Propagation is shared wall clock: once the first criterion has waited
        # out a 45-minute Entra window, the objects the next three read have had 45 minutes
        # too, so summing the declared windows overstates the realistic cost. What is never
        # defensible is ONE criterion that can consume the entire budget and starve the rest.
        $budget = Get-MlsActionBudgetDefault
        $offender = @(Get-MlsLayerWindowPlan |
                Where-Object { $_.MaxWindowMinutes -gt $budget } |
                ForEach-Object { "$($_.File): a criterion declares $($_.MaxWindowMinutes) min > run budget $budget" })
        $offender -join '; ' | Should -BeNullOrEmpty `
            -Because 'a criterion that can eat the whole budget leaves the rest of the layer unmeasured'
    }

    It 'no criterion inherits its patience silently' {
        # The original defect in one line: 19 of 47 criteria took a 30-minute window nobody
        # chose for them, because it was the default. Every criterion now states what it
        # waits for and why - a value taken from that layer's runbook, not from whatever
        # default happened to be in the module (F59).
        $orphan = @(Get-MlsLayerWindowPlan | Where-Object { $_.Implicit -gt 0 } |
                ForEach-Object { "$($_.File): $($_.Implicit) criteria with no declared window" })
        $orphan -join '; ' | Should -BeNullOrEmpty `
            -Because 'inheriting patience is how a synchronous check got a 30-minute window'
    }

    It 'the default window is short enough that patience must be opted into' {
        # The specific number is a judgement call; that it is SHORT is the design. A default
        # long enough to hide an unconsidered criterion is the defect this test exists for.
        Get-MlsDefaultWindow | Should -BeLessOrEqual 10 `
            -Because 'a criterion that genuinely needs longer must say so explicitly'
    }
}

Describe 'no test fixture commits a GUID the allowlist does not cover' {
    # V1.3 sweeps the repository and fails on any GUID not on the reviewed allowlist. A test
    # fixture is a committed file, so a GUID-shaped literal in one is a hit like any other -
    # which is how three "realistic-looking" ids added to make an L1 test honest promptly
    # made V1.3 red (F68). Generate them instead of committing them.

    It 'every committed GUID is on the reviewed allowlist' {
        $pattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $allowlist = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'verification' 'guid-allowlist.txt') -Raw
        $allowed = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in [regex]::Matches($allowlist, $pattern)) { $null = $allowed.Add($m.Value.ToLowerInvariant()) }

        Push-Location $script:RepoRoot
        try {
            $hits = @(git grep -hoIE $pattern -- '.' ':!docs' ':!*.lock' 2>$null)
        }
        finally { Pop-Location }

        $hits.Count | Should -BeGreaterThan 0 -Because 'a sweep that finds nothing would make this vacuous'
        $orphan = @($hits | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique |
                Where-Object { -not $allowed.Contains($_) })
        $orphan -join ', ' | Should -BeNullOrEmpty `
            -Because 'V1.3 fails the live audit on exactly this; catching it here costs a second instead of a deploy'
    }
}
