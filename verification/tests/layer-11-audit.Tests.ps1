# Pester tests for verification/layer-11-audit.ps1 - az, gh and the child layer audits are
# all mocked; zero cloud calls and no child process is ever spawned.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-11-audit.ps1')
    # No Set-StrictMode -Off: the audit scripts set -Version Latest and CI runs them
    # that way, so the harness must not relax the language mode it is testing (F49).

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l11-$([guid]::NewGuid().ToString('n'))"
    $script:Subscription = '22222222-2222-2222-2222-222222222222'
    $script:EnvironmentVariable = @('AZURE_SUBSCRIPTION_ID', 'MLS_L11_UP_START', 'MLS_L11_UP_COMPLETED',
        'FABRIC_CAPACITY_ID', 'MLS_SQL_DB_ID', 'MLS_REPOSITORY')
    $script:SavedEnvironment = @{}
    foreach ($name in $script:EnvironmentVariable) { $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

    function Get-Row {
        param($Context, [string]$Id)
        return @($Context.Criterion | Where-Object { $_.Id -eq $Id })[0]
    }

    function Invoke-AuditForTest {
        param(
            [string]$Phase = 'Up',
            [switch]$NoRetry,
            [switch]$SkipChildAudit,
            [string]$UpStartUtc = '',
            [string]$UpCompletedUtc = '',
            [string]$SubscriptionId = $script:Subscription,
            # Defaults to the full set, so every existing test keeps asserting the whole
            # claim. A test that narrows it is testing the narrowing.
            [string[]]$ChildAuditLayer = @('1', '2', '3', '4', '5', '6', '7', '8', '9', '10')
        )
        if ([string]::IsNullOrWhiteSpace($UpStartUtc)) { $UpStartUtc = [datetime]::UtcNow.AddMinutes(-42).ToString('o') }
        Invoke-Main -Phase $Phase -SubscriptionId $SubscriptionId -ResourceGroupPrefix 'mls-rg-' `
            -UpStartUtc $UpStartUtc -UpCompletedUtc $UpCompletedUtc -WallClockBudgetMinutes 180 `
            -Repository 'paulcfuqua/azure-devsecops-demo' -FabricCapacityId '99999999-9999-9999-9999-999999999999' `
            -SqlDatabaseId '/subscriptions/s/rg/db' -IdleDailyCostBudget 0.17 -ChildAuditLayer $ChildAuditLayer `
            -SkipChildAudit:$SkipChildAudit -ReportRoot $script:ReportRoot -NoRetry:$NoRetry
    }
}

AfterAll {
    foreach ($name in $script:EnvironmentVariable) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnvironment[$name]) }
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:ReportRoot) {
        Remove-Item -LiteralPath $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'layer-11-audit' {
    BeforeEach {
        foreach ($name in $script:EnvironmentVariable) { [Environment]::SetEnvironmentVariable($name, $null) }
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'

        # mls-rg-identity SURVIVES the teardown by design - it holds the managed identity
        # the AWS trust policy pins its sub to, and infra-down.yml deletes four groups by
        # name and cannot reach it. An empty list is not the correct down-state.
        $script:ResourceGroup = @('mls-rg-identity')
        $script:FailingChildLayer = @()
        $script:BlindChildLayer = @()
        $script:FilteredChildLayer = @()
        $script:NoReportChildLayer = @()
        $script:CapacityState = 'Paused'
        $script:BlindChildLayer = @()
        $script:FilteredChildLayer = @()
        $script:SqlStatus = 'Paused'
        $script:Usage = @([pscustomobject]@{ svc = 'OneLake storage'; cost = 0.02 }, [pscustomobject]@{ svc = 'LAW retention'; cost = 0.05 })

        # THE AUDITS EMIT THREE DISTINCT NON-ZERO CODES AND THEY MEAN DIFFERENT THINGS:
        # 1 a criterion genuinely FAILed, 2 the audit COULD NOT START (a required input was
        # missing), 3 it was filtered to a diagnostic. This mock only ever produced 0 and 1,
        # which is why nothing caught F227 - the case where every child exits 2 had no test
        # because the fixture could not express it.
        # THE CHILD'S REPORT IS PART OF ITS ANSWER NOW. V11.3 reads what each child OBSERVED
        # from the JSON report it wrote, not only its exit code - an exit 0 over eight SKIPs
        # (the L8 child, 2026-09-25) is not a green layer. So a child that reaches a verdict
        # here writes a REAL report through the real engine (New-MlsAuditContext,
        # Invoke-MlsCriterion, Write-MlsReport) and prints the "report: <path>" line every
        # audit prints, and its exit code is whatever Get-MlsExitCode makes of those rows.
        # The fixture supplies what each criterion SAW; the classification under test is the
        # audit's own.
        #
        # $script:ChildRows[<layer>] overrides the rows for one layer; each row is
        # @{ Id; Result } where Result is what the criterion's -Test returns.
        $script:ChildRows = @{}
        $script:ChildLaunch = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-MlsChildAudit {
            $layer = [int]([regex]::Match($ScriptPath, 'layer-(\d+)-audit').Groups[1].Value)
            $script:ChildLaunch.Add([pscustomobject]@{ Layer = $layer; Environment = $Environment }) | Out-Null
            if ($script:BlindChildLayer -contains $layer) {
                return [pscustomobject]@{ ScriptPath = $ScriptPath; ExitCode = 2
                    Output = @("layer-$('{0:d2}' -f $layer)-audit could not start: Required input 'SubscriptionId' was not supplied.") }
            }
            if ($script:FilteredChildLayer -contains $layer) {
                return [pscustomobject]@{ ScriptPath = $ScriptPath; ExitCode = 3
                    Output = @("L$layer run was FILTERED with -OnlyCriterion; no verdict.") }
            }
            if ($script:NoReportChildLayer -contains $layer) {
                return [pscustomobject]@{ ScriptPath = $ScriptPath; ExitCode = 0
                    Output = @("L$layer audit finished with exit 0") }
            }
            $rows = if ($script:ChildRows.ContainsKey($layer)) { @($script:ChildRows[$layer]) }
            elseif ($script:FailingChildLayer -contains $layer) {
                @(
                    @{ Id = "V$layer.1"; Result = (New-MlsCheckResult -Passed $true -Observed 'as declared') },
                    @{ Id = "V$layer.2"; Result = (New-MlsCheckResult -Passed $false -Final -Observed 'value differs from the declared baseline') }
                )
            }
            else {
                @(
                    @{ Id = "V$layer.1"; Result = (New-MlsCheckResult -Passed $true -Observed 'as declared') },
                    @{ Id = "V$layer.2"; Result = (New-MlsCheckResult -Passed $true -Observed 'as declared') }
                )
            }
            $child = New-MlsAuditContext -Layer $layer -Title 'fixture child' -ReportRoot $script:ReportRoot -NoRetry
            foreach ($row in $rows) {
                $answer = $row.Result
                Invoke-MlsCriterion -Context $child -Id $row.Id -Control @() -Description 'fixture' -Command 'fixture' `
                    -Expected 'fixture' -NoRetry -Test { $answer }.GetNewClosure() | Out-Null
            }
            $written = Write-MlsReport -Context $child -Timestamp ([guid]::NewGuid().ToString('n'))
            return [pscustomobject]@{
                ScriptPath = $ScriptPath
                ExitCode   = (Get-MlsExitCode -Context $child)
                Output     = @("L$layer audit finished", "report: $($written.MarkdownPath)")
            }
        }

        Mock Invoke-MlsAz {
            $joined = $Argument -join ' '
            if ($joined -like 'group list*') { return $script:ResourceGroup }
            if ($joined -like 'consumption usage list*') { return $script:Usage }
            if ($joined -like 'resource show*') { return $script:CapacityState }
            if ($joined -like 'sql db show*') { return $script:SqlStatus }
            throw "unexpected az call: $joined"
        }

        Mock Invoke-MlsGh {
            return [pscustomobject]@{ workflow_runs = @(
                    [pscustomobject]@{ name = 'infra-up'; created_at = [datetime]::UtcNow.AddMinutes(-40).ToString('o'); updated_at = [datetime]::UtcNow.AddMinutes(-5).ToString('o') }
                )
            }
        }
    }

    Context 'the down-state checkpoint' {
        It 'measures V11.1 and V11.2 and records the post-up criteria as explicit SKIPs' {
            $context = Invoke-AuditForTest -Phase 'Down'
            @($context.Criterion).Id | Should -Be @('V11.1', 'V11.2', 'V11.3', 'V11.4', 'V11.5')
            (Get-Row -Context $context -Id 'V11.1').Status | Should -Be 'PASS'
            (Get-Row -Context $context -Id 'V11.2').Status | Should -Be 'PASS'
            foreach ($id in @('V11.3', 'V11.4', 'V11.5')) {
                (Get-Row -Context $context -Id $id).Status | Should -Be 'SKIP'
                (Get-Row -Context $context -Id $id).Detail | Should -BeLike '*Phase Up*'
            }
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 're-executes only the L3 and L4 audits for the tenant-object check' {
            Invoke-AuditForTest -Phase 'Down' | Out-Null
            Should -Invoke Invoke-MlsChildAudit -Exactly -Times 2
            Should -Invoke Invoke-MlsChildAudit -Exactly -Times 1 -ParameterFilter { $ScriptPath -like '*layer-03-audit.ps1' }
            Should -Invoke Invoke-MlsChildAudit -Exactly -Times 1 -ParameterFilter { $ScriptPath -like '*layer-04-audit.ps1' }
        }

        It 'fails V11.1 when a resource group survived down.ps1' {
            $script:ResourceGroup = @('mls-rg-apps')
            $context = Invoke-AuditForTest -Phase 'Down' -NoRetry
            $row = Get-Row -Context $context -Id 'V11.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*mls-rg-apps*'
            Get-MlsExitCode -Context $context | Should -Be 1
        }

        It 'records V11.2 as UNOBSERVABLE - not stop-the-line - when a child audit cannot start' {
            # F227. On the 2026-09-21 rebuild every child exited 2 because the job carried no
            # env: block, and V11.2 announced that the teardown had crossed the tenant-object
            # line - a G3 violation and a G4 event - over a missing environment variable, on
            # an estate whose L3 and L4 audits had both passed minutes earlier.
            $script:BlindChildLayer = @(3, 4)
            $context = Invoke-AuditForTest -Phase 'Down' -NoRetry
            $row = Get-Row -Context $context -Id 'V11.2'
            # FAIL, not SKIP: a SKIP would exit 0 and let the workflow print "PASS - no
            # criterion FAILed" over a rebuild proof that proved nothing. Red and true.
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike 'UNOBSERVABLE:*'
            $row.Observed | Should -BeLike '*exit=2*'
            $row.Detail | Should -BeLike '*UNOBSERVABLE, not failed*'
            $row.Detail | Should -Not -BeLike '*crossed the tenant-object line*'
            # THE SAFETY PROPERTY, asserted directly rather than inferred from the status:
            # a rebuild proof that could not run its child audits must not exit 0, because
            # the workflow prints "PASS - no criterion FAILed" on 0 and nobody investigates
            # green.
            Get-MlsExitCode -Context $context | Should -Not -Be 0
        }

        It 'still fails V11.2 when a child genuinely regresses alongside one that is blind' {
            # A blind sibling must never MASK a real failure. This is the direction that
            # matters: the fix makes "could not look" stop meaning "broken", and it must not
            # also make "broken" start meaning "could not look".
            $script:BlindChildLayer = @(3)
            $script:FailingChildLayer = @(4)
            $context = Invoke-AuditForTest -Phase 'Down' -NoRetry
            $row = Get-Row -Context $context -Id 'V11.2'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*crossed the tenant-object line*'
        }

        It 'fails V11.2 - stop the line - when the L4 label audit regresses in the down state' {
            $script:FailingChildLayer = @(4)
            $context = Invoke-AuditForTest -Phase 'Down' -NoRetry
            $row = Get-Row -Context $context -Id 'V11.2'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*crossed the tenant-object line*'
        }
    }

    Context 'the post-up checkpoint' {
        It 'records V11.2-V11.5 as PASS and V11.1 as a phase SKIP' {
            $context = Invoke-AuditForTest -Phase 'Up'
            (Get-Row -Context $context -Id 'V11.1').Status | Should -Be 'SKIP'
            (Get-Row -Context $context -Id 'V11.1').Detail | Should -BeLike '*down-state criterion*'
            foreach ($id in @('V11.2', 'V11.3', 'V11.4', 'V11.5')) {
                (Get-Row -Context $context -Id $id).Status | Should -Be 'PASS'
            }
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 're-runs every layer audit L1-L10 for V11.3' {
            Invoke-AuditForTest -Phase 'Up' | Out-Null
            # 10 for V11.3 plus the 2 that V11.2 re-executes.
            Should -Invoke Invoke-MlsChildAudit -Exactly -Times 12
        }

        It 'records V11.3 as UNOBSERVABLE when child audits could not start, naming the layers' {
            $script:BlindChildLayer = @(1, 2, 5)
            $context = Invoke-AuditForTest -Phase 'Up' -NoRetry
            $row = Get-Row -Context $context -Id 'V11.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike 'UNOBSERVABLE:*'
            $row.Observed | Should -BeLike '*L1=UNOBSERVABLE(2)*'
            $row.Observed | Should -BeLike '*L2=UNOBSERVABLE(2)*'
            $row.Observed | Should -BeLike '*L5=UNOBSERVABLE(2)*'
            $row.Observed | Should -BeLike '*L3=PASS*'
            $row.Detail | Should -BeLike '*env:*'
        }

        It 'treats a FILTERED child run (exit 3) as no verdict rather than a failure' {
            # -OnlyCriterion exits 3 by design: SKIP does not fail a run, so without a code of
            # its own a filtered run would be indistinguishable from a full green one. It is
            # not a pass and it is not a failure.
            $script:FilteredChildLayer = @(7)
            $context = Invoke-AuditForTest -Phase 'Up' -NoRetry
            $row = Get-Row -Context $context -Id 'V11.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*L7=UNOBSERVABLE(3)*'
        }

        It 'records V11.3 as a DIAGNOSTIC when the child-audit set was narrowed' {
            # PAID FOR 2026-09-22. Run with -ChildAuditLayer 3,4 the criterion examined two
            # of ten layers and reported PASS under the title "all layer audits green". The
            # evidence line was honest; the verdict was not, and a reader scanning a
            # criterion table reads verdicts.
            $context = Invoke-AuditForTest -Phase 'Up' -NoRetry -ChildAuditLayer @('3', '4')
            $row = Get-Row -Context $context -Id 'V11.3'
            $row.Status | Should -Be 'SKIP'
            $row.Observed | Should -BeLike '*DIAGNOSTIC*'
            $row.Observed | Should -BeLike '*examined 2 of 10*'
            $row.Detail | Should -BeLike '*never examined layers*'
        }

        It 'still FAILS V11.3 when a layer inside a narrowed set is broken' {
            # Narrowing removes the right to claim the whole; it does not excuse what was
            # actually seen to be broken. Without this, narrowing would launder a failure
            # into a SKIP - a worse bug than the one being fixed.
            $script:FailingChildLayer = @(4)
            $context = Invoke-AuditForTest -Phase 'Up' -NoRetry -ChildAuditLayer @('3', '4')
            $row = Get-Row -Context $context -Id 'V11.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*L4=FAIL*'
        }

        It 'fails V11.3 and names the failing layer' {
            $script:FailingChildLayer = @(6)
            $context = Invoke-AuditForTest -Phase 'Up' -NoRetry
            $row = Get-Row -Context $context -Id 'V11.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*L6=FAIL*'
        }
    }

    Context 'V11.3 counts what a child OBSERVED, not only how it exited' {
        It 'never counts a child that SKIPped every criterion as PASS' {
            # PAID FOR 2026-09-25. The L8 child SKIPped 8 of 8 (no environment URL, no eval
            # artifact, no MCP server), exited 0, and V11.3 recorded L8=PASS. SKIP does not
            # fail a run, so the exit code was right about "nothing failed" and wrong about
            # everything a reader took from it.
            $script:ChildRows = @{
                8 = @(
                    @{ Id = 'V8.1'; Result = (New-MlsCheckResult -Status 'SKIP' -Observed 'no deployed environment to compare against') },
                    @{ Id = 'V8.2'; Result = (New-MlsCheckResult -Status 'SKIP' -Observed 'no eval artifact') },
                    @{ Id = 'V8.6'; Result = (New-MlsCheckResult -Status 'SKIP' -Observed 'no deployed MCP server to ask') }
                )
            }
            $context = Invoke-AuditForTest -Phase 'Up' -NoRetry
            $row = Get-Row -Context $context -Id 'V11.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike 'UNOBSERVABLE:*'
            $row.Observed | Should -Not -BeLike '*L8=PASS*'
            $row.Observed | Should -BeLike '*L8=UNOBSERVABLE(0)*0 of 3 observed*3 SKIP*'
            $row.Unobservable | Should -BeTrue
            Get-MlsExitCode -Context $context | Should -Not -Be 0
        }

        It 'applies the same rule to V11.2: an all-SKIP tenant audit supports no claim that tenant objects are intact' {
            $script:ChildRows = @{
                4 = @(@{ Id = 'V4.1'; Result = (New-MlsCheckResult -Status 'SKIP' -Observed 'no Security & Compliance session') })
            }
            $context = Invoke-AuditForTest -Phase 'Down' -NoRetry
            $row = Get-Row -Context $context -Id 'V11.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike 'UNOBSERVABLE:*L4=UNOBSERVABLE(0)*'
            $row.Detail | Should -Not -BeLike '*crossed the tenant-object line*'
        }

        It 'names genuinely failing layers apart from layers that could not look' {
            # L7's criterion FAILed because an input never arrived - the audit said so with
            # -Unobservable. L6's FAILed on a value it read. Only one of those is a broken layer.
            $script:ChildRows = @{
                6 = @(
                    @{ Id = 'V6.1'; Result = (New-MlsCheckResult -Passed $true -Observed 'sku as declared') },
                    @{ Id = 'V6.7'; Result = (New-MlsCheckResult -Passed $false -Final -Observed 'mls-cost-ingest-demo-func reports 0 functions') }
                )
                7 = @(
                    @{ Id = 'V7.1'; Result = (New-MlsCheckResult -Passed $false -Final -Unobservable -Observed 'no deploy manifest supplied') },
                    @{ Id = 'V7.6'; Result = (New-MlsCheckResult -Passed $true -Observed 'rows=1200') }
                )
            }
            $context = Invoke-AuditForTest -Phase 'Up' -NoRetry
            $row = Get-Row -Context $context -Id 'V11.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike 'FAILING: L6; UNOBSERVABLE: L7 --*'
            $row.Observed | Should -BeLike '*L6=FAIL(1)`[V6.7`]*'
            $row.Observed | Should -BeLike '*L7=UNOBSERVABLE(1)`[unobservable V7.1`]*'
        }

        It 'treats the UNOBSERVABLE text convention in a child row as unobservable' {
            # L5 and L8 already write "UNOBSERVABLE: ..." into Observed; that is the child
            # saying it could not look, and it must read that way here too.
            $script:ChildRows = @{
                5 = @(
                    @{ Id = 'V5.1'; Result = (New-MlsCheckResult -Passed $true -Observed 'workspace present') },
                    @{ Id = 'V5.5'; Result = (New-MlsCheckResult -Passed $false -Final -Observed 'UNOBSERVABLE: the SQL analytics endpoint could not be read') }
                )
            }
            $context = Invoke-AuditForTest -Phase 'Up' -NoRetry
            (Get-Row -Context $context -Id 'V11.3').Observed | Should -BeLike 'UNOBSERVABLE:*L5=UNOBSERVABLE(1)`[unobservable V5.5`]*'
        }

        It 'still passes a layer whose own design SKIPs some criteria alongside real passes' {
            # L4's V4.2 and L1's V1.5 SKIP by design and their layers sign off; one SKIP next
            # to observed PASSes is not a blind layer.
            $script:ChildRows = @{
                4 = @(
                    @{ Id = 'V4.1'; Result = (New-MlsCheckResult -Passed $true -Observed '4 labels, GUIDs unchanged') },
                    @{ Id = 'V4.2'; Result = (New-MlsCheckResult -Status 'SKIP' -Observed 'no recorded baseline at the layer checkpoint') }
                )
            }
            $context = Invoke-AuditForTest -Phase 'Up' -NoRetry
            $row = Get-Row -Context $context -Id 'V11.3'
            $row.Status | Should -Be 'PASS'
            $row.Observed | Should -BeLike '*L4=PASS(0)`[1/2`]*'
        }

        It 'does not take exit 0 as a pass when the child left no readable report' {
            $script:NoReportChildLayer = @(9)
            $context = Invoke-AuditForTest -Phase 'Up' -NoRetry
            $row = Get-Row -Context $context -Id 'V11.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*L9=UNOBSERVABLE(0)`[no readable report`]*'
        }

        It 'keeps every layer, and each failing criterion, readable in the written report' {
            # PAID FOR 2026-09-25: the V11.3 Observed line carried every child's console tail
            # and the report cut it off after L2, hiding which criteria failed in L5-L10.
            $long = 'x' * 400
            $script:ChildRows = @{}
            foreach ($n in 1..10) {
                $script:ChildRows[$n] = @(
                    @{ Id = "V$n.1"; Result = (New-MlsCheckResult -Passed $true -Observed $long) },
                    @{ Id = "V$n.2"; Result = (New-MlsCheckResult -Passed $false -Final -Observed "L$n broke: $long") },
                    @{ Id = "V$n.3"; Result = (New-MlsCheckResult -Passed $false -Final -Unobservable -Observed "no input for L$n") }
                )
            }
            $context = Invoke-AuditForTest -Phase 'Up' -NoRetry
            $written = Write-MlsReport -Context $context -Timestamp ([guid]::NewGuid().ToString('n'))
            $markdown = Get-Content -LiteralPath $written.MarkdownPath -Raw
            $v113 = @(($markdown -split "`n") | Where-Object { $_ -like '- **Observed:** FAILING:*' })
            $v113.Count | Should -Be 1
            $v113[0] | Should -Not -BeLike '*(truncated)*'
            foreach ($n in 1..10) {
                $v113[0] | Should -BeLike "*L$n=FAIL(1)``[V$n.2``]*"
                # The per-criterion evidence survives in full in the notes.
                $markdown | Should -BeLike "*V11.3 child L$n FAIL*V$n.2 FAIL - L$n broke*V$n.3 FAIL, unobservable - no input for L$n*"
            }
        }

        It 'hands every child the rebuild start instant, so event windows cover the rebuild' {
            $start = [datetime]::UtcNow.AddMinutes(-170).ToString('yyyy-MM-ddTHH:mm:ssZ')
            Invoke-AuditForTest -Phase 'Up' -NoRetry -UpStartUtc $start | Out-Null
            $script:ChildLaunch.Count | Should -Be 12
            foreach ($launch in $script:ChildLaunch) {
                $launch.Environment['MLS_REBUILD_START_UTC'] | Should -Be $start
            }
        }
    }

    Context 'the post-up checkpoint: clocks and run-rate' {

        It 'fails V11.4 when the rebuild took 180 minutes or more' {
            # THE GATE MOVED, SO THIS MOVED. 95 minutes used to fail and now passes: the
            # budget was raised from 60 to 180 by sponsor decision 2026-09-22, after two
            # measured cycles missed 60 (87 min on 09-03, 152.2 on 09-21). A test left at
            # the old number would have gone green by accident and stopped meaning
            # anything, which is worse than going red.
            $context = Invoke-AuditForTest -Phase 'Up' -NoRetry `
                -UpStartUtc ([datetime]::UtcNow.AddMinutes(-195).ToString('o')) `
                -UpCompletedUtc ([datetime]::UtcNow.ToString('o'))
            $row = Get-Row -Context $context -Id 'V11.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*elapsed 195*'
        }

        It 'passes V11.4 at the real measured rebuild time, which the old gate failed' {
            # 152.2 minutes is what the 2026-09-21 rebuild actually took. Under the old
            # 60-minute gate it was a FAIL; under 180 it passes with ~28 minutes of margin.
            # Pinned so the new number is anchored to the measurement that justified it
            # rather than to a round figure someone liked.
            $context = Invoke-AuditForTest -Phase 'Up' -NoRetry `
                -UpStartUtc ([datetime]::UtcNow.AddMinutes(-152).ToString('o')) `
                -UpCompletedUtc ([datetime]::UtcNow.ToString('o'))
            (Get-Row -Context $context -Id 'V11.4').Status | Should -Be 'PASS'
        }

        It 'cites both clocks for V11.4' {
            $context = Invoke-AuditForTest -Phase 'Up'
            (Get-Row -Context $context -Id 'V11.4').Observed | Should -BeLike '*workflow-run clock*'
        }

        It 'fails V11.5 when the SQL database is still Online and the run-rate is not idle' {
            $script:SqlStatus = 'Online'
            $script:Usage = @([pscustomobject]@{ svc = 'SQL Database'; cost = 4.20 })
            $context = Invoke-AuditForTest -Phase 'Up' -NoRetry
            $row = Get-Row -Context $context -Id 'V11.5'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*exceeds the pro-rated idle envelope*'
            $row.Detail | Should -BeLike '*direct G4 trigger*'
        }

        It 'records V11.5 as PENDING while consumption data has not landed yet' {
            $script:Usage = @()
            $context = Invoke-AuditForTest -Phase 'Up'
            $row = Get-Row -Context $context -Id 'V11.5'
            $row.Status | Should -Be 'PENDING'
            $row.SleptSeconds | Should -Be 0
            Get-MlsExitCode -Context $context | Should -Be 0
        }
    }

    Context 'retry' {
        It 'retries V11.1 while an RG delete is still in flight, without sleeping the whole window' {
            $script:Calls = 0
            Mock Invoke-MlsAz {
                $joined = $Argument -join ' '
                if ($joined -like 'group list*') {
                    $script:Calls++
                    if ($script:Calls -lt 2) { return @('mls-rg-platform', 'mls-rg-identity') }
                    return @('mls-rg-identity')
                }
                if ($joined -like 'consumption usage list*') { return $script:Usage }
                if ($joined -like 'resource show*') { return 'Paused' }
                if ($joined -like 'sql db show*') { return 'Paused' }
                throw "unexpected az call: $joined"
            }
            $context = Invoke-AuditForTest -Phase 'Down'
            $row = Get-Row -Context $context -Id 'V11.1'
            $row.Status | Should -Be 'PASS'
            $row.Attempt | Should -Be 2
            # One poll interval, not the whole window - asserted against the row's own
            # cadence rather than a literal, so right-sizing the defaults (F59) cannot
            # silently turn this into a test of a constant nobody re-checked.
            $row.SleptSeconds | Should -Be $row.PollIntervalSecond
            $row.SleptSeconds | Should -BeLessThan ($row.RetryWindowMinutes * 60)
            Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 1
        }
    }

    Context 'a check that throws' {
        It 'records V11.1 as FAIL and still evaluates V11.2' {
            Mock Invoke-MlsAz { throw 'az group list failed with exit code 1 (SubscriptionNotFound).' }
            $context = Invoke-AuditForTest -Phase 'Down' -NoRetry
            @($context.Criterion).Count | Should -Be 5
            (Get-Row -Context $context -Id 'V11.1').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V11.1').Observed | Should -BeLike '*SubscriptionNotFound*'
            (Get-Row -Context $context -Id 'V11.2').Status | Should -Be 'PASS'
        }
    }

    Context 'missing input' {
        It 'refuses to run without a subscription id' {
            { Invoke-AuditForTest -SubscriptionId '' } | Should -Throw '*SubscriptionId*'
        }

        It 'fails V11.4 rather than inventing a start time when up.ps1 recorded none' {
            $context = Invoke-Main -Phase 'Up' -SubscriptionId $script:Subscription -ResourceGroupPrefix 'mls-rg-' `
                -UpStartUtc '' -UpCompletedUtc '' -WallClockBudgetMinutes 180 -Repository 'paulcfuqua/azure-devsecops-demo' `
                -ChildAuditLayer @(1) -ReportRoot $script:ReportRoot -NoRetry
            $row = Get-Row -Context $context -Id 'V11.4'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*MLS_L11_UP_START*'
        }

        It 'records V11.2 and V11.3 as SKIP when the child audits are suppressed' {
            $context = Invoke-AuditForTest -Phase 'Up' -SkipChildAudit
            (Get-Row -Context $context -Id 'V11.2').Status | Should -Be 'SKIP'
            (Get-Row -Context $context -Id 'V11.3').Status | Should -Be 'SKIP'
            Should -Invoke Invoke-MlsChildAudit -Exactly -Times 0
        }
    }

    Context 'V11.1 - the resource group that must SURVIVE the teardown' {
        # mls-rg-identity holds mls-aws-demo-id, the managed identity the AWS trust
        # policy's `sub` condition is pinned to. infra-down.yml deletes four groups BY
        # NAME and cannot reach it.
        #
        # V11.1 used to assert that NO mls-rg-* survives, so a CORRECT teardown would have
        # failed it - reporting that the teardown had not worked when it had worked exactly
        # as designed. The group was created 2026-09-16 and nothing has torn down since, so
        # the contradiction had never been exercised.

        It 'PASSES when the four are gone and the survivor remains' {
            $script:ResourceGroup = @('mls-rg-identity')
            (Get-Row -Context (Invoke-AuditForTest -Phase 'Down') -Id 'V11.1').Status |
                Should -Be 'PASS'
        }

        It 'FAILS when a teardown-scoped group is still present' {
            $script:ResourceGroup = @('mls-rg-identity', 'mls-rg-apps')
            $row = Get-Row -Context (Invoke-AuditForTest -Phase 'Down' -NoRetry) -Id 'V11.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*mls-rg-apps*'
        }

        It 'FAILS when the survivor itself is gone, and says that is the worse outcome' {
            # The direction nothing checked before. Nothing in the Azure deploy path can
            # recreate this group: the AWS trust policy pins a sub that would no longer
            # exist, so the cross-cloud link would be permanently broken.
            $script:ResourceGroup = @()
            $row = Get-Row -Context (Invoke-AuditForTest -Phase 'Down' -NoRetry) -Id 'V11.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*must SURVIVE*'
            $row.Detail | Should -BeLike '*cross-cloud*'
        }

        It 'does not treat the survivor as licence for any stray group' {
            # The exclusion is a NAMED list, not a pattern. An exclusion broad enough to be
            # convenient is broad enough to hide a stranded, billable resource group.
            $script:ResourceGroup = @('mls-rg-identity', 'mls-rg-something-unexpected')
            (Get-Row -Context (Invoke-AuditForTest -Phase 'Down' -NoRetry) -Id 'V11.1').Status |
                Should -Be 'FAIL'
        }
    }

    Context 'the two SurvivingResourceGroup defaults must agree' {
        # The value lives twice: once on the script param block (what CI passes through)
        # and once on Invoke-Main (what the harness and any direct caller get). If they
        # drift, one path reports the designed survivor as a stranded resource group and
        # the other does not - and which one you hit depends on how the audit was invoked.
        It 'declares the same survivors in the param block and in Invoke-Main' {
            $path = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-11-audit.ps1'
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)

            $scriptParam = $ast.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'SurvivingResourceGroup' }
            $invokeMain = $ast.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Main'
                }, $true)[0]
            $functionParam = $invokeMain.Body.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq 'SurvivingResourceGroup' }

            $scriptParam | Should -Not -BeNullOrEmpty
            $functionParam | Should -Not -BeNullOrEmpty

            $extract = {
                param($p)
                @($p.DefaultValue.FindAll({
                            param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
                        }, $true) | ForEach-Object { $_.Value })
            }
            $scriptDefault = & $extract $scriptParam
            $functionDefault = & $extract $functionParam
            $functionDefault | Should -Be $scriptDefault
            $scriptDefault | Should -Contain 'mls-rg-identity'
        }
    }
}
