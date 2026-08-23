# Pester tests for scripts/bootstrap/03-budget.ps1 - all az calls mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    $script:Sub = '00000000-0000-0000-0000-000000000000'
    $script:Email = 'sponsor@example.com'
    . (Join-Path $PSScriptRoot '..' '03-budget.ps1') -SubscriptionId $script:Sub -Email $script:Email
    Set-StrictMode -Off

    function New-MatchingBudget {
        param([int]$Amount = 75, [string]$Email = 'sponsor@example.com')
        $notifications = [ordered]@{}
        foreach ($threshold in @(50, 80, 100)) {
            $notifications["Actual_GreaterThan_${threshold}_Percent"] = [pscustomobject]@{
                enabled       = $true
                operator      = 'GreaterThan'
                threshold     = $threshold
                thresholdType = 'Actual'
                contactEmails = @($Email)
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
        param([switch]$WhatIf)
        Invoke-Main -SubscriptionId $script:Sub -Email $script:Email -BudgetName 'mls-monthly-budget' -Amount 75 -WhatIf:$WhatIf
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
    }

    Context '-WhatIf makes no mutating calls' {
        It 'budget absent: GET only' {
            Invoke-BudgetForTest -WhatIf | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -match 'rest --method (put|post|patch|delete)'
            }
            Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like 'rest --method get*'
            }
        }

        It 'budget drifted: still no PUT under -WhatIf' {
            $script:ExistingBudget = New-MatchingBudget -Amount 10
            Invoke-BudgetForTest -WhatIf | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -match 'rest --method (put|post|patch|delete)'
            }
        }
    }
}
