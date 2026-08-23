# Pester tests for scripts/bootstrap/02-fabric-capacity.ps1 - all az calls mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    $script:Sub = '00000000-0000-0000-0000-000000000000'
    . (Join-Path $PSScriptRoot '..' '02-fabric-capacity.ps1')
    Set-StrictMode -Off

    function Invoke-F2ForTest {
        param([switch]$WhatIf)
        Invoke-Main -Mode 'F2' -SubscriptionId $script:Sub -ResourceGroup 'mls-rg-platform' `
            -CapacityName 'mlsfabricdemo' -Location 'eastus2' -AdminUpn @('admin@contoso.example') `
            -DeployerAppName 'mls-github-deployer' -WhatIf:$WhatIf
    }
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
}

Describe '02-fabric-capacity' {
    BeforeEach {
        Mock Write-Status {}
        Mock Invoke-AzCli {
            $joined = $Arguments -join ' '
            if ($joined -like 'rest --method get*') { return $script:ExistingCapacity }
            if ($joined -like 'rest --method put*') { return $script:CreatedCapacity }
            if ($joined -like 'rest --method post*') { return $null } # suspend
            return $null
        }
        $script:ExistingCapacity = $null
        $script:CreatedCapacity = [pscustomobject]@{
            name       = 'mlsfabricdemo'
            properties = [pscustomobject]@{ state = 'Active' }
        }
    }

    Context 'Trial mode (default)' {
        It 'prints manual steps and never calls az at all' {
            $result = Invoke-Main -Mode 'Trial' -SubscriptionId '' -ResourceGroup 'mls-rg-platform' `
                -CapacityName 'mlsfabricdemo' -Location 'eastus2' -AdminUpn @() -DeployerAppName 'mls-github-deployer'
            $result.Mode | Should -Be 'Trial'
            $result.Capacity | Should -BeNullOrEmpty
            Should -Invoke Invoke-AzCli -Exactly -Times 0
        }

        It 'mentions the deployer app, the SP-API toggle, the capacity ID variable, and the no-pause trial note' {
            Mock Write-Status {} -ParameterFilter { $true }
            Invoke-Main -Mode 'Trial' -SubscriptionId '' -ResourceGroup 'mls-rg-platform' `
                -CapacityName 'mlsfabricdemo' -Location 'eastus2' -AdminUpn @() -DeployerAppName 'mls-github-deployer' | Out-Null
            Should -Invoke Write-Status -ParameterFilter { $Message -like '*mls-github-deployer*' }
            Should -Invoke Write-Status -ParameterFilter { $Message -like '*Service principals can use Fabric APIs*' }
            Should -Invoke Write-Status -ParameterFilter { $Message -like '*FABRIC_CAPACITY_ID*' }
            Should -Invoke Write-Status -ParameterFilter { $Message -like '*NO pause/suspend control*' }
        }
    }

    Context 'F2 mode - capacity absent' {
        It 'creates the capacity then suspends it (paused F2)' {
            Invoke-F2ForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like 'rest --method put*' -and
                ($Arguments -join ' ') -like '*Microsoft.Fabric/capacities/mlsfabricdemo*'
            }
            Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like 'rest --method post*' -and
                ($Arguments -join ' ') -like '*mlsfabricdemo/suspend*'
            }
        }

        It 'requires -SubscriptionId and -AdminUpn' {
            { Invoke-Main -Mode 'F2' -SubscriptionId '' -ResourceGroup 'rg' -CapacityName 'c' `
                    -Location 'l' -AdminUpn @('a@b.c') -DeployerAppName 'd' } | Should -Throw '*SubscriptionId*'
            { Invoke-Main -Mode 'F2' -SubscriptionId $script:Sub -ResourceGroup 'rg' -CapacityName 'c' `
                    -Location 'l' -AdminUpn @() -DeployerAppName 'd' } | Should -Throw '*AdminUpn*'
        }
    }

    Context 'F2 mode - capacity already exists (idempotent)' {
        It 'when already Paused issues no mutations at all' {
            $script:ExistingCapacity = [pscustomobject]@{
                name       = 'mlsfabricdemo'
                properties = [pscustomobject]@{ state = 'Paused' }
            }
            Invoke-F2ForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -match 'rest --method (put|post|patch|delete)'
            }
        }

        It 'when Active suspends it but does not recreate it' {
            $script:ExistingCapacity = [pscustomobject]@{
                name       = 'mlsfabricdemo'
                properties = [pscustomobject]@{ state = 'Active' }
            }
            Invoke-F2ForTest | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -like 'rest --method put*'
            }
            Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like 'rest --method post*' -and
                ($Arguments -join ' ') -like '*suspend*'
            }
        }
    }

    Context '-WhatIf makes no mutating calls' {
        It 'F2 mode with capacity absent performs the GET only' {
            Invoke-F2ForTest -WhatIf | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -match 'rest --method (put|post|patch|delete)'
            }
            Should -Invoke Invoke-AzCli -Exactly -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like 'rest --method get*'
            }
        }

        It 'F2 mode with an Active capacity does not suspend under -WhatIf' {
            $script:ExistingCapacity = [pscustomobject]@{
                name       = 'mlsfabricdemo'
                properties = [pscustomobject]@{ state = 'Active' }
            }
            Invoke-F2ForTest -WhatIf | Out-Null
            Should -Invoke Invoke-AzCli -Exactly -Times 0 -ParameterFilter {
                ($Arguments -join ' ') -match 'rest --method (put|post|patch|delete)'
            }
        }
    }
}
