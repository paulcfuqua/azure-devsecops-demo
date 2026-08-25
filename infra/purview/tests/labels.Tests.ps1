# Pester tests for infra/purview/labels.ps1 - S&C cmdlets stubbed + mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'

    # ExchangeOnlineManagement is not loaded in tests: define local stand-ins for the
    # three S&C cmdlets the script uses, then Mock them per scenario.
    function Get-Label {
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Identity)
        throw "stub Get-Label called without a mock (Identity: $Identity)"
    }
    function New-Label {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Stand-in for the ExchangeOnlineManagement cmdlet of the same name, which labels.ps1 calls by that exact name. The stub must keep the real name and signature so Pester can Mock it, and it changes no state at all - the body is deliberately empty.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'The parameters exist to mirror the real S&C cmdlet signature so that labels.ps1 binds against it and Should -Invoke -ParameterFilter can inspect $Name/$DisplayName/$Tooltip. An empty body that uses nothing is the point of the stub.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Name,
            [string]$DisplayName,
            [string]$Tooltip
        )
    }
    function Set-Label {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Stand-in for the ExchangeOnlineManagement cmdlet of the same name, which labels.ps1 calls by that exact name. The stub must keep the real name and signature so Pester can Mock it, and it changes no state at all - the body is deliberately empty.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'The parameters exist to mirror the real S&C cmdlet signature so that labels.ps1 binds against it and Should -Invoke -ParameterFilter can inspect $Identity/$DisplayName/$Tooltip. An empty body that uses nothing is the point of the stub.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Identity,
            [string]$DisplayName,
            [string]$Tooltip
        )
    }

    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'labels.ps1')
    Set-StrictMode -Off

    $script:ExpectedNames = @('Public', 'Internal', 'Confidential', 'Export-Controlled')
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
}

Describe 'labels' {
    BeforeEach {
        Mock Write-Status {}
        Mock Test-IppSession { $true }
        Mock New-Label {}
        Mock Set-Label {}
    }

    Context 'taxonomy definition' {
        It 'defines exactly the four labels, lowest to highest sensitivity' {
            $taxonomy = Get-LabelTaxonomy
            @($taxonomy).Name | Should -Be $script:ExpectedNames
            foreach ($label in $taxonomy) {
                $label.DisplayName | Should -Not -BeNullOrEmpty
                $label.Tooltip | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'no labels exist yet' {
        BeforeEach {
            Mock Get-Label { throw "The Label $Identity doesn't exist" }
        }

        It 'creates all four labels' {
            $result = Invoke-Main
            Should -Invoke New-Label -Exactly -Times 4
            foreach ($expected in $script:ExpectedNames) {
                Should -Invoke New-Label -Exactly -Times 1 -ParameterFilter { $Name -eq $expected }
                $result.$expected | Should -Be 'Created'
            }
            Should -Invoke Set-Label -Exactly -Times 0
        }
    }

    Context 'all labels already exist and match (idempotent replay)' {
        BeforeEach {
            Mock Get-Label {
                $wanted = Get-LabelTaxonomy | Where-Object { $_.Name -eq $Identity }
                if (-not $wanted) { throw "The Label $Identity doesn't exist" }
                return [pscustomobject]@{
                    Name        = $wanted.Name
                    DisplayName = $wanted.DisplayName
                    Tooltip     = $wanted.Tooltip
                }
            }
        }

        It 'creates and updates nothing' {
            $result = Invoke-Main
            Should -Invoke New-Label -Exactly -Times 0
            Should -Invoke Set-Label -Exactly -Times 0
            foreach ($name in $script:ExpectedNames) { $result.$name | Should -Be 'Unchanged' }
        }
    }

    Context 'one label drifted' {
        BeforeEach {
            Mock Get-Label {
                $wanted = Get-LabelTaxonomy | Where-Object { $_.Name -eq $Identity }
                if (-not $wanted) { throw "The Label $Identity doesn't exist" }
                $tooltip = $wanted.Tooltip
                if ($Identity -eq 'Confidential') { $tooltip = 'stale tooltip' }
                return [pscustomobject]@{
                    Name        = $wanted.Name
                    DisplayName = $wanted.DisplayName
                    Tooltip     = $tooltip
                }
            }
        }

        It 'updates only the drifted label in place' {
            $result = Invoke-Main
            Should -Invoke New-Label -Exactly -Times 0
            Should -Invoke Set-Label -Exactly -Times 1 -ParameterFilter { $Identity -eq 'Confidential' }
            $result.Confidential | Should -Be 'Updated'
            $result.Public | Should -Be 'Unchanged'
        }
    }

    Context 'mixed: some exist, some do not' {
        BeforeEach {
            Mock Get-Label {
                if ($Identity -in @('Public', 'Internal')) {
                    $wanted = Get-LabelTaxonomy | Where-Object { $_.Name -eq $Identity }
                    return [pscustomobject]@{ Name = $wanted.Name; DisplayName = $wanted.DisplayName; Tooltip = $wanted.Tooltip }
                }
                throw "The Label $Identity doesn't exist"
            }
        }

        It 'creates only the missing ones' {
            $result = Invoke-Main
            Should -Invoke New-Label -Exactly -Times 2
            Should -Invoke New-Label -Exactly -Times 1 -ParameterFilter { $Name -eq 'Confidential' }
            Should -Invoke New-Label -Exactly -Times 1 -ParameterFilter { $Name -eq 'Export-Controlled' }
            $result.Public | Should -Be 'Unchanged'
            $result.'Export-Controlled' | Should -Be 'Created'
        }
    }

    Context '-WhatIf makes no mutating calls' {
        It 'with no labels present, neither New-Label nor Set-Label runs' {
            Mock Get-Label { throw "The Label $Identity doesn't exist" }
            $result = Invoke-Main -WhatIf
            Should -Invoke New-Label -Exactly -Times 0
            Should -Invoke Set-Label -Exactly -Times 0
            foreach ($name in $script:ExpectedNames) { $result.$name | Should -Be 'WhatIf' }
        }

        It 'with a drifted label, Set-Label does not run either' {
            Mock Get-Label {
                $wanted = Get-LabelTaxonomy | Where-Object { $_.Name -eq $Identity }
                if (-not $wanted) { throw 'missing' }
                return [pscustomobject]@{ Name = $wanted.Name; DisplayName = $wanted.DisplayName; Tooltip = 'stale' }
            }
            Invoke-Main -WhatIf | Out-Null
            Should -Invoke Set-Label -Exactly -Times 0
        }
    }

    Context 'session guard' {
        It 'fails clearly when Connect-IPPSSession has not been run' {
            Mock Test-IppSession { throw 'Security & Compliance cmdlets not found. Run Connect-IPPSSession first.' }
            { Invoke-Main } | Should -Throw '*Connect-IPPSSession*'
            Should -Invoke New-Label -Exactly -Times 0
        }
    }
}
