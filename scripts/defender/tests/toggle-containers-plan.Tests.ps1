# Pester tests for scripts/defender/toggle-containers-plan.ps1 - every az call mocked;
# zero cloud calls, and in particular zero Defender plan writes (each one is a G2 spend
# increase, and this suite runs on every push).

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    $script:Sub = '11111111-2222-3333-4444-555555555555'
    # -Disable only selects a parameter set so the dot-source can bind; MLS_SKIP_MAIN
    # stops the script body before anything runs.
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'toggle-containers-plan.ps1') -Disable
    Set-StrictMode -Off

    $script:SavedSubscription = [Environment]::GetEnvironmentVariable('AZURE_SUBSCRIPTION_ID')

    function Invoke-ToggleForTest {
        # -AsWhatIf, not -WhatIf: a parameter literally named WhatIf on a function that
        # never calls ShouldProcess trips PSUseSupportsShouldProcess, and lint-ci fails on
        # any warning. It is forwarded to Invoke-Main as -WhatIf (same convention as
        # scripts/bootstrap/tests/03-budget.Tests.ps1).
        param(
            [ValidateSet('Standard', 'Free')][string]$DesiredTier = 'Standard',
            [string]$SubscriptionId = '',
            [switch]$AsWhatIf
        )
        $target = if ($SubscriptionId) { $SubscriptionId } else { $script:Sub }
        Invoke-Main -DesiredTier $DesiredTier -PlanName 'Containers' -SubscriptionId $target -WhatIf:$AsWhatIf
    }
}

AfterAll {
    [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', $script:SavedSubscription)
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
}

Describe 'toggle-containers-plan' {
    BeforeEach {
        $script:Banner = [System.Collections.Generic.List[string]]::new()
        Mock Write-Status { $script:Banner.Add("$Message") }

        # The plan's tier as ARM would report it; the write flips it, so a read-back sees
        # what a real one would.
        $script:Tier = 'Free'
        $script:WriteCall = [System.Collections.Generic.List[string]]::new()

        Mock Invoke-AzCli {
            $joined = $Arguments -join ' '
            if ($joined -like 'security pricing show*') {
                if ([string]::IsNullOrWhiteSpace($script:Tier)) { return $null }
                return [pscustomobject]@{ name = 'Containers'; pricingTier = $script:Tier }
            }
            if ($joined -like 'security pricing create*') {
                $script:WriteCall.Add($joined)
                $script:Tier = $Arguments[[array]::IndexOf($Arguments, '--tier') + 1]
                return [pscustomobject]@{ name = 'Containers'; pricingTier = $script:Tier }
            }
            if ($joined -like 'account show*') { return [pscustomobject]@{ id = $script:Sub } }
            throw "unexpected az call: $joined"
        }
    }

    Context 'enabling (G2)' {
        It 'writes tier Standard and reports the change' {
            $result = Invoke-ToggleForTest -DesiredTier 'Standard'
            $result.Changed | Should -BeTrue
            $result.Previous | Should -Be 'Free'
            $result.Tier | Should -Be 'Standard'
            @($script:WriteCall).Count | Should -Be 1
            $script:WriteCall[0] | Should -BeLike '*security pricing create --name Containers --tier Standard*'
        }

        It 'targets the subscription explicitly on every call' {
            Invoke-ToggleForTest -DesiredTier 'Standard' | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 3 -ParameterFilter {
                ($Arguments -join ' ') -like "*--subscription $($script:Sub)*"
            }
        }

        It 'states the cost delta and the leave-it-Off requirement before writing' {
            Invoke-ToggleForTest -DesiredTier 'Standard' | Out-Null
            $banner = $script:Banner -join "`n"
            $banner | Should -BeLike '*GATE G2 - SPEND INCREASE*'
            $banner | Should -BeLike '*USD 0.29/day*'
            $banner | Should -BeLike "*MUST LEAVE THIS PLAN 'Off'*"
            $banner | Should -BeLike '*failure mode 2*'
        }

        It 'reminds the operator to disable once the write lands' {
            Invoke-ToggleForTest -DesiredTier 'Standard' | Out-Null
            ($script:Banner -join "`n") | Should -BeLike '*REMINDER*Run -Disable before the demo cycle closes*'
        }

        It 'is idempotent: an already-enabled plan issues no write' {
            $script:Tier = 'Standard'
            $result = Invoke-ToggleForTest -DesiredTier 'Standard'
            $result.Changed | Should -BeFalse
            @($script:WriteCall).Count | Should -Be 0
            ($script:Banner -join "`n") | Should -BeLike '*already at tier*'
        }

        It 'still shows the G2 banner when it no-ops, because the run rate is still being carried' {
            $script:Tier = 'Standard'
            Invoke-ToggleForTest -DesiredTier 'Standard' | Out-Null
            ($script:Banner -join "`n") | Should -BeLike '*GATE G2 - SPEND INCREASE*'
        }

        It 'writes when the plan has never been configured' {
            $script:Tier = ''
            $result = Invoke-ToggleForTest -DesiredTier 'Standard'
            $result.Changed | Should -BeTrue
            @($script:WriteCall).Count | Should -Be 1
        }
    }

    Context 'disabling' {
        It 'writes tier Free and calls it a spend decrease needing no gate' {
            $script:Tier = 'Standard'
            $result = Invoke-ToggleForTest -DesiredTier 'Free'
            $result.Changed | Should -BeTrue
            $result.Tier | Should -Be 'Free'
            $script:WriteCall[0] | Should -BeLike '*--tier Free*'
            ($script:Banner -join "`n") | Should -BeLike '*no gate applies*'
        }

        It 'is idempotent: an already-disabled plan issues no write' {
            $result = Invoke-ToggleForTest -DesiredTier 'Free'
            $result.Changed | Should -BeFalse
            @($script:WriteCall).Count | Should -Be 0
        }
    }

    Context '-WhatIf' {
        It 'issues no write and says what it would have done' {
            $result = Invoke-ToggleForTest -DesiredTier 'Standard' -AsWhatIf
            $result.WhatIf | Should -BeTrue
            $result.Changed | Should -BeFalse
            $result.Tier | Should -Be 'Free'
            @($script:WriteCall).Count | Should -Be 0
            ($script:Banner -join "`n") | Should -BeLike '*(-WhatIf) Would set Defender*'
        }

        It 'still prints the G2 banner under -WhatIf' {
            Invoke-ToggleForTest -DesiredTier 'Standard' -AsWhatIf | Out-Null
            ($script:Banner -join "`n") | Should -BeLike '*USD 0.29/day*'
        }
    }

    Context 'the write did not land' {
        It 'throws instead of reporting success when the read-back disagrees' {
            Mock Invoke-AzCli {
                $joined = $Arguments -join ' '
                if ($joined -like 'security pricing show*') { return [pscustomobject]@{ pricingTier = 'Free' } }
                if ($joined -like 'security pricing create*') { return [pscustomobject]@{ pricingTier = 'Standard' } }
                throw "unexpected az call: $joined"
            }
            { Invoke-ToggleForTest -DesiredTier 'Standard' } | Should -Throw "*still reads tier 'Free'*"
        }
    }

    Context 'subscription resolution' {
        It 'prefers the explicit id' {
            [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', 'from-environment')
            Resolve-SubscriptionId -SubscriptionId 'explicit' | Should -Be 'explicit'
        }

        It 'falls back to the environment, then to the current az login' {
            [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', 'from-environment')
            Resolve-SubscriptionId -SubscriptionId '' | Should -Be 'from-environment'
            [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', $null)
            Resolve-SubscriptionId -SubscriptionId '' | Should -Be $script:Sub
        }

        It 'fails with an actionable message when there is no subscription anywhere' {
            [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', $null)
            Mock Invoke-AzCli { return $null }
            { Resolve-SubscriptionId -SubscriptionId '' } | Should -Throw '*Pass -SubscriptionId*'
        }
    }
}
