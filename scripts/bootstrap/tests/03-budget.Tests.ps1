# Pester tests for scripts/bootstrap/03-budget.ps1 - all az calls mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    $script:Sub = '00000000-0000-0000-0000-000000000000'
    $script:Email = 'sponsor@example.com'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '03-budget.ps1') -SubscriptionId $script:Sub -Email $script:Email
    Set-StrictMode -Off

    function New-MatchingBudget {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pure builder: returns an in-memory pscustomobject used as a mocked az response, and changes no state anywhere.')]
        param([int]$Amount = 75, [string]$Email = 'sponsor@example.com', [string]$ActionGroupResourceId = '')
        $notifications = [ordered]@{}
        foreach ($threshold in @(50, 80, 100)) {
            $notifications["Actual_GreaterThan_${threshold}_Percent"] = [pscustomobject]@{
                enabled       = $true
                operator      = 'GreaterThan'
                threshold     = $threshold
                thresholdType = 'Actual'
                contactEmails = @($Email)
                contactGroups = if ($ActionGroupResourceId) { @($ActionGroupResourceId) } else { @() }
            }
        }
        foreach ($threshold in @(50, 80)) {
            $notifications["Forecasted_GreaterThan_${threshold}_Percent"] = [pscustomobject]@{
                enabled       = $true
                operator      = 'GreaterThan'
                threshold     = $threshold
                thresholdType = 'Forecasted'
                contactEmails = @($Email)
                contactGroups = if ($ActionGroupResourceId) { @($ActionGroupResourceId) } else { @() }
            }
        }
        return [pscustomobject]@{
            name       = 'mls-monthly-budget'
            properties = [pscustomobject]@{
                category      = 'Cost'
                amount        = $Amount
                timeGrain     = 'Monthly'
                notifications = [pscustomobject]$notifications
            }
        }
    }

    function Invoke-BudgetForTest {
        # -AsWhatIf, not -WhatIf: a parameter literally named WhatIf on a function that
        # never calls ShouldProcess trips PSUseSupportsShouldProcess, and lint-ci fails
        # on any warning. It is still forwarded to Invoke-Main as -WhatIf.
        param([switch]$AsWhatIf, [string]$ActionGroupResourceId = '')
        Invoke-Main -SubscriptionId $script:Sub -Email $script:Email -BudgetName 'mls-monthly-budget' -Amount 75 `
            -ActionGroupResourceId $ActionGroupResourceId -WhatIf:$AsWhatIf
    }
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
}

Describe '03-budget' {
    BeforeEach {
        Mock Write-Status {}
        $script:ExistingBudget = $null
        $script:CapturedBudgetBody = $null
        Mock Invoke-AzCli {
            $joined = $Arguments -join ' '
            if ($joined -like 'rest --method get*') { return $script:ExistingBudget }
            if ($joined -like 'rest --method put*') {
                $file = ($Arguments[[array]::IndexOf($Arguments, '--body') + 1]).TrimStart('@')
                $script:CapturedBudgetBody = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
                return $script:CapturedBudgetBody
            }
            return $null
        }
    }

    Context 'budget absent' {
        It 'PUTs a $75 monthly budget with 50/80/100% alerts to the given email' {
            Invoke-BudgetForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like 'rest --method put*' -and
                ($Arguments -join ' ') -like '*Microsoft.Consumption/budgets/mls-monthly-budget*'
            }
            $props = $script:CapturedBudgetBody.properties
            $props.amount | Should -Be 75
            $props.timeGrain | Should -Be 'Monthly'
            $props.category | Should -Be 'Cost'
            foreach ($threshold in @(50, 80, 100)) {
                $note = $props.notifications."Actual_GreaterThan_${threshold}_Percent"
                $note.enabled | Should -BeTrue
                $note.threshold | Should -Be $threshold
                $note.thresholdType | Should -Be 'Actual'
                @($note.contactEmails) | Should -Contain $script:Email
            }
        }

        It 'alerts on forecast as well as actual spend' {
            # F15 (compliance/findings/2026-08-26-prepublication-review.md#f15): Actual-cost
            # data lags 8-24h, longer than it takes to burn a $200 credit against a
            # wallet-facing endpoint. Forecasted notifications close that gap.
            $body = Get-DesiredBudgetBody -Amount 75 -Email 'x@y.z'
            ($body.properties.notifications.Values | Where-Object thresholdType -eq 'Forecasted') |
                Should -Not -BeNullOrEmpty
        }

        It 'keeps the actual-spend notifications alongside the forecasted ones' {
            # Forecasted alerts supplement Actual; they must never replace them.
            $body = Get-DesiredBudgetBody -Amount 75 -Email 'x@y.z'
            $actual = @($body.properties.notifications.Values | Where-Object thresholdType -eq 'Actual')
            $forecasted = @($body.properties.notifications.Values | Where-Object thresholdType -eq 'Forecasted')
            $actual.Count | Should -Be 3
            $forecasted.Count | Should -Be 2
        }

        It 'starts the budget period on the first day of the current month (UTC)' {
            Invoke-BudgetForTest | Out-Null
            # ConvertFrom-Json parses ISO strings to [datetime]; normalize back to UTC.
            $start = ([datetime]$script:CapturedBudgetBody.properties.timePeriod.startDate).ToUniversalTime()
            $start.Year | Should -Be ([datetime]::UtcNow.Year)
            $start.Month | Should -Be ([datetime]::UtcNow.Month)
            $start.Day | Should -Be 1
            $start.Hour | Should -Be 0
        }
    }

    Context 'budget already matches (idempotent re-run)' {
        It 'issues no PUT' {
            $script:ExistingBudget = New-MatchingBudget
            Invoke-BudgetForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -match 'rest --method (put|post|patch|delete)'
            }
        }
    }

    Context 'budget exists but drifts' {
        It 'updates when the amount differs' {
            $script:ExistingBudget = New-MatchingBudget -Amount 50
            Invoke-BudgetForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like 'rest --method put*'
            }
            $script:CapturedBudgetBody.properties.amount | Should -Be 75
        }

        It 'updates when the alert email differs' {
            $script:ExistingBudget = New-MatchingBudget -Email 'someone.else@example.com'
            Invoke-BudgetForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like 'rest --method put*'
            }
        }

        It 'updates when a notification threshold is missing' {
            $budget = New-MatchingBudget
            $budget.properties.notifications.PSObject.Properties.Remove('Actual_GreaterThan_80_Percent')
            $script:ExistingBudget = $budget
            Invoke-BudgetForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like 'rest --method put*'
            }
        }

        It 'updates when a forecasted notification threshold is missing' {
            $budget = New-MatchingBudget
            $budget.properties.notifications.PSObject.Properties.Remove('Forecasted_GreaterThan_80_Percent')
            $script:ExistingBudget = $budget
            Invoke-BudgetForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like 'rest --method put*'
            }
        }
    }

    Context 'F17 (Task 19) -ActionGroupResourceId shares one page-out path with security alerting' {
        # 03-budget.ps1 runs at G0, which precedes L6 on every infra-up.yml pass -- the
        # action group this param would reference (platform/main.bicep's
        # alertActionGroup, Task 19) does not exist yet the first time this script
        # runs. -ActionGroupResourceId defaults to '' for exactly that reason: these
        # tests cover both the default no-op (first G0 run, backward compatible) and
        # the supplementary re-run once L6 has deployed.
        BeforeAll {
            $script:Ag = '/subscriptions/s/resourceGroups/mls-rg-platform/providers/Microsoft.Insights/actionGroups/mls-obs-demo-ag'
        }

        It 'omits contactGroups when no action group id is supplied (the first G0 run, before L6 exists)' {
            Invoke-BudgetForTest | Out-Null
            $notifications = $script:CapturedBudgetBody.properties.notifications
            foreach ($name in $notifications.PSObject.Properties.Name) {
                @($notifications.$name.contactGroups) | Should -BeNullOrEmpty
            }
        }

        It 'adds the action group to every notification''s contactGroups when supplied' {
            Invoke-BudgetForTest -ActionGroupResourceId $script:Ag | Out-Null
            $notifications = $script:CapturedBudgetBody.properties.notifications
            foreach ($name in $notifications.PSObject.Properties.Name) {
                @($notifications.$name.contactGroups) | Should -Contain $script:Ag
            }
        }

        It 'keeps contactEmails alongside contactGroups -- additive, not a replacement' {
            Invoke-BudgetForTest -ActionGroupResourceId $script:Ag | Out-Null
            $notifications = $script:CapturedBudgetBody.properties.notifications
            foreach ($name in $notifications.PSObject.Properties.Name) {
                @($notifications.$name.contactEmails) | Should -Contain $script:Email
            }
        }

        It 'is idempotent once the existing budget already carries the action group' {
            $script:ExistingBudget = New-MatchingBudget -ActionGroupResourceId $script:Ag
            Invoke-BudgetForTest -ActionGroupResourceId $script:Ag | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -match 'rest --method (put|post|patch|delete)'
            }
        }

        It 'updates (re-runs the PUT) when the existing budget predates the action group and one is now supplied' {
            $script:ExistingBudget = New-MatchingBudget
            Invoke-BudgetForTest -ActionGroupResourceId $script:Ag | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like 'rest --method put*'
            }
        }
    }

    Context '-WhatIf makes no mutating calls' {
        It 'budget absent: GET only' {
            Invoke-BudgetForTest -AsWhatIf | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -match 'rest --method (put|post|patch|delete)'
            }
            Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like 'rest --method get*'
            }
        }

        It 'budget drifted: still no PUT under -WhatIf' {
            $script:ExistingBudget = New-MatchingBudget -Amount 10
            Invoke-BudgetForTest -AsWhatIf | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -match 'rest --method (put|post|patch|delete)'
            }
        }
    }
}
