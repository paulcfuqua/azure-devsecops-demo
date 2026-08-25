# Pester tests for verification/layer-11-audit.ps1 - az, gh and the child layer audits are
# all mocked; zero cloud calls and no child process is ever spawned.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-11-audit.ps1')
    Set-StrictMode -Off

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
            [string]$SubscriptionId = $script:Subscription
        )
        if ([string]::IsNullOrWhiteSpace($UpStartUtc)) { $UpStartUtc = [datetime]::UtcNow.AddMinutes(-42).ToString('o') }
        Invoke-Main -Phase $Phase -SubscriptionId $SubscriptionId -ResourceGroupPrefix 'mls-rg-' `
            -UpStartUtc $UpStartUtc -UpCompletedUtc $UpCompletedUtc -WallClockBudgetMinutes 60 `
            -Repository 'paulcfuqua/azure-devsecops' -FabricCapacityId '99999999-9999-9999-9999-999999999999' `
            -SqlDatabaseId '/subscriptions/s/rg/db' -IdleDailyCostBudget 0.17 -ChildAuditLayer @(1, 2, 3, 4, 5, 6, 7, 8, 9, 10) `
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

        $script:ResourceGroup = @()
        $script:FailingChildLayer = @()
        $script:CapacityState = 'Paused'
        $script:SqlStatus = 'Paused'
        $script:Usage = @([pscustomobject]@{ svc = 'OneLake storage'; cost = 0.02 }, [pscustomobject]@{ svc = 'LAW retention'; cost = 0.05 })

        Mock Invoke-MlsChildAudit {
            $layer = [int]([regex]::Match($ScriptPath, 'layer-(\d+)-audit').Groups[1].Value)
            $exitCode = if ($script:FailingChildLayer -contains $layer) { 1 } else { 0 }
            return [pscustomobject]@{
                ScriptPath = $ScriptPath
                ExitCode   = $exitCode
                Output     = @("L$layer audit finished with exit $exitCode")
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

        It 'fails V11.3 and names the failing layer' {
            $script:FailingChildLayer = @(6)
            $context = Invoke-AuditForTest -Phase 'Up' -NoRetry
            $row = Get-Row -Context $context -Id 'V11.3'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*L6=FAIL*'
        }

        It 'fails V11.4 when the rebuild took 60 minutes or more' {
            $context = Invoke-AuditForTest -Phase 'Up' -NoRetry `
                -UpStartUtc ([datetime]::UtcNow.AddMinutes(-95).ToString('o')) `
                -UpCompletedUtc ([datetime]::UtcNow.ToString('o'))
            $row = Get-Row -Context $context -Id 'V11.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*elapsed 95*'
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
                    if ($script:Calls -lt 2) { return @('mls-rg-platform') }
                    return @()
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
            $row.SleptSeconds | Should -Be 300
            $row.SleptSeconds | Should -BeLessThan (30 * 60)
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
                -UpStartUtc '' -UpCompletedUtc '' -WallClockBudgetMinutes 60 -Repository 'paulcfuqua/azure-devsecops' `
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
}
