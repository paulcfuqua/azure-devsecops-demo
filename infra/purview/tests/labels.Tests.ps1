# Pester tests for infra/purview/labels.ps1 - S&C cmdlets stubbed + mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'

    # ExchangeOnlineManagement is not loaded in tests: define local stand-ins for the
    # six S&C cmdlets the script uses, then Mock them per scenario.
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
    function Get-LabelPolicy {
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Identity)
        throw "stub Get-LabelPolicy called without a mock (Identity: $Identity)"
    }
    function New-LabelPolicy {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Stand-in for the ExchangeOnlineManagement cmdlet of the same name, which labels.ps1 calls by that exact name. The stub must keep the real name and signature so Pester can Mock it, and it changes no state at all - the body is deliberately empty.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'The parameters exist to mirror the real S&C cmdlet signature so that labels.ps1 binds against it and Should -Invoke -ParameterFilter can inspect $Name/$Labels/$ExchangeLocation. An empty body that uses nothing is the point of the stub.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Name,
            [string[]]$Labels,
            [string[]]$ExchangeLocation
        )
    }
    function Set-LabelPolicy {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Stand-in for the ExchangeOnlineManagement cmdlet of the same name, which labels.ps1 calls by that exact name. The stub must keep the real name and signature so Pester can Mock it, and it changes no state at all - the body is deliberately empty.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'The parameters exist to mirror the real S&C cmdlet signature so that labels.ps1 binds against it and Should -Invoke -ParameterFilter can inspect the Add/Remove sets. An empty body that uses nothing is the point of the stub.')]
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Identity,
            [string[]]$AddLabel,
            [string[]]$RemoveLabel,
            [string[]]$AddExchangeLocation,
            [string[]]$RemoveExchangeLocation
        )
    }

    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'labels.ps1')
    # No Set-StrictMode -Off: the script under test sets -Version Latest and CI runs it
    # that way, so the harness must not relax the language mode it is testing (F49).

    # Prefixed, and derived from the script's own naming.bicep parse rather than
    # written out here: F32. A test carrying its own copy of the bare generic names
    # would stay green against a regression that recreated an adopter's labels.
    $script:Prefix = Get-CompanyPrefix
    $script:ExpectedNames = @((Get-LabelTaxonomy -Prefix $script:Prefix).Name)
    # The demo groups L04.md:53 says the policy scopes the labels to - same four groups
    # infra/entra/manifest.json's groups[].displayName defines.
    # 'All', NOT FOUR GROUP NAMES (F121). The policy was published to four demo groups
    # and never could be: `-ExchangeLocation` takes a RECIPIENT, and L3 creates pure
    # SECURITY groups - mailEnabled=False, no mail address - which Security & Compliance
    # cannot resolve however correct the name is. The first real L4 run failed with
    # `The specified recipient "mls-flight-operations" couldn't be found`, and these
    # tests pinned the scope that could never be achieved, so they would have failed
    # their own fix. See Get-LabelPolicyScope for why All was chosen over changing L3.
    $script:ExpectedGroups = @('All')
    $script:ExpectedPolicyName = Get-LabelPolicyName -Prefix $script:Prefix

    function Get-MatchingLabelGetMock {
        <# A Get-Label mock where every label in the taxonomy already exists, unchanged. #>
        return {
            $wanted = Get-LabelTaxonomy -Prefix $script:Prefix | Where-Object { $_.Name -eq $Identity }
            if (-not $wanted) { throw "The Label $Identity doesn't exist" }
            return [pscustomobject]@{ Name = $wanted.Name; DisplayName = $wanted.DisplayName; Tooltip = $wanted.Tooltip }
        }
    }
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
        Mock New-LabelPolicy {}
        Mock Set-LabelPolicy {}
        # Default: no policy published yet. Contexts that care about policy drift/match
        # override this; contexts that only test label behaviour leave it as-is.
        Mock Get-LabelPolicy { throw "The label policy $Identity doesn't exist" }
    }

    Context 'taxonomy definition' {
        It 'defines exactly the four labels, lowest to highest sensitivity' {
            $taxonomy = Get-LabelTaxonomy -Prefix $script:Prefix
            @($taxonomy).Name | Should -Be $script:ExpectedNames
            foreach ($label in $taxonomy) {
                $label.DisplayName | Should -Not -BeNullOrEmpty
                $label.Tooltip | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'label names are prefixed, never the bare words (F32)' {
        # The defect this closes: Get-LabelTaxonomy returned the literal 'Public',
        # 'Internal', 'Confidential' and 'Export-Controlled'. Against an adopter with
        # an existing Microsoft Purview taxonomy, the update-on-drift path below is
        # not a create - it silently rewrites their production 'Confidential' label's
        # tooltip with demo text, in CI, under -Confirm:$false.
        It 'prefixes every label name and every display name, and uses no bare generic word' {
            $taxonomy = Get-LabelTaxonomy -Prefix $script:Prefix
            @($taxonomy).Count | Should -Be 4
            foreach ($label in $taxonomy) {
                $label.Name | Should -BeLike "$($script:Prefix)-*"
                $label.DisplayName | Should -BeLike "$($script:Prefix)-*"
            }
            foreach ($bare in @('Public', 'Internal', 'Confidential', 'Export-Controlled')) {
                @($taxonomy).Name | Should -Not -Contain $bare
                @($taxonomy).DisplayName | Should -Not -Contain $bare
            }
        }

        It 'reads the prefix out of infra/bicep/naming.bicep rather than hardcoding it' {
            $namingPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'bicep', 'naming.bicep'
            Get-CompanyPrefix -Path $namingPath | Should -Be $script:Prefix
            { Get-CompanyPrefix -Path (Join-Path -Path $PSScriptRoot -ChildPath 'no-such-naming.bicep') } |
                Should -Throw '*naming.bicep*'
        }

        It 'prefixes the published policy name too' {
            Get-LabelPolicyName -Prefix $script:Prefix | Should -BeLike "$($script:Prefix)-*"
        }

        It 'Initialize-SensitivityLabel declares ConfirmImpact High on the function that calls ShouldProcess' {
            # ConfirmImpact does not propagate from caller to callee, so declaring it
            # on Invoke-Main would do nothing. Writing a tenant-level sensitivity
            # label is high-impact and an interactive operator must be asked.
            $attribute = (Get-Item 'Function:\Initialize-SensitivityLabel').ScriptBlock.Attributes |
                Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
            $attribute | Should -Not -BeNullOrEmpty
            $attribute.SupportsShouldProcess | Should -BeTrue
            $attribute.ConfirmImpact | Should -Be 'High'
        }
    }

    Context 'label policy scope definition' {
        It 'names the policy and scopes it to All, the only recipient L3 makes addressable' {
            Get-LabelPolicyName -Prefix $script:Prefix | Should -Be $script:ExpectedPolicyName
            # -Prefix, because the scope now derives it: a hand-kept list of fully
            # qualified names published the policy to groups that exist in no renamed
            # tenant (F94).
            Get-LabelPolicyScope -Prefix $script:Prefix | Should -Be $script:ExpectedGroups
        }
    }

    Context 'no labels exist yet' {
        BeforeEach {
            Mock Get-Label { throw "The Label $Identity doesn't exist" }
        }

        It 'creates all four labels' {
            $result = Invoke-Main -Confirm:$false
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
                $wanted = Get-LabelTaxonomy -Prefix $script:Prefix | Where-Object { $_.Name -eq $Identity }
                if (-not $wanted) { throw "The Label $Identity doesn't exist" }
                return [pscustomobject]@{
                    Name        = $wanted.Name
                    DisplayName = $wanted.DisplayName
                    Tooltip     = $wanted.Tooltip
                }
            }
        }

        It 'creates and updates nothing' {
            $result = Invoke-Main -Confirm:$false
            Should -Invoke New-Label -Exactly -Times 0
            Should -Invoke Set-Label -Exactly -Times 0
            foreach ($name in $script:ExpectedNames) { $result.$name | Should -Be 'Unchanged' }
        }
    }

    Context 'one label drifted' {
        BeforeEach {
            Mock Get-Label {
                $wanted = Get-LabelTaxonomy -Prefix $script:Prefix | Where-Object { $_.Name -eq $Identity }
                if (-not $wanted) { throw "The Label $Identity doesn't exist" }
                $tooltip = $wanted.Tooltip
                if ($Identity -eq "$($script:Prefix)-confidential") { $tooltip = 'stale tooltip' }
                return [pscustomobject]@{
                    Name        = $wanted.Name
                    DisplayName = $wanted.DisplayName
                    Tooltip     = $tooltip
                }
            }
        }

        It 'updates only the drifted label in place' {
            $result = Invoke-Main -Confirm:$false
            Should -Invoke New-Label -Exactly -Times 0
            Should -Invoke Set-Label -Exactly -Times 1 -ParameterFilter { $Identity -eq "$($script:Prefix)-confidential" }
            $result."$($script:Prefix)-confidential" | Should -Be 'Updated'
            $result."$($script:Prefix)-public" | Should -Be 'Unchanged'
        }
    }

    Context 'mixed: some exist, some do not' {
        BeforeEach {
            Mock Get-Label {
                if ($Identity -in @("$($script:Prefix)-public", "$($script:Prefix)-internal")) {
                    $wanted = Get-LabelTaxonomy -Prefix $script:Prefix | Where-Object { $_.Name -eq $Identity }
                    return [pscustomobject]@{ Name = $wanted.Name; DisplayName = $wanted.DisplayName; Tooltip = $wanted.Tooltip }
                }
                throw "The Label $Identity doesn't exist"
            }
        }

        It 'creates only the missing ones' {
            $result = Invoke-Main -Confirm:$false
            Should -Invoke New-Label -Exactly -Times 2
            Should -Invoke New-Label -Exactly -Times 1 -ParameterFilter { $Name -eq "$($script:Prefix)-confidential" }
            Should -Invoke New-Label -Exactly -Times 1 -ParameterFilter { $Name -eq "$($script:Prefix)-export-controlled" }
            $result."$($script:Prefix)-public" | Should -Be 'Unchanged'
            $result."$($script:Prefix)-export-controlled" | Should -Be 'Created'
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
                $wanted = Get-LabelTaxonomy -Prefix $script:Prefix | Where-Object { $_.Name -eq $Identity }
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
            { Invoke-Main -Confirm:$false } | Should -Throw '*Connect-IPPSSession*'
            Should -Invoke New-Label -Exactly -Times 0
            Should -Invoke New-LabelPolicy -Exactly -Times 0
        }
    }

    # --- label policy publish step (F18) ------------------------------------------------
    # labels.ps1 created the four-label taxonomy but never published a policy scoping it
    # to anyone - a label nobody can apply enforces nothing. These assert the publish step
    # is actually wired into Invoke-Main (not merely present as dead code somewhere in the
    # file), is idempotent the same way Initialize-SensitivityLabel is, and is scoped to
    # the exact groups L04.md:53 names.

    Context 'label policy: not yet published' {
        BeforeEach {
            Mock Get-Label { throw "The Label $Identity doesn't exist" }
            Mock Get-LabelPolicy { throw "The label policy $Identity doesn't exist" }
        }

        It 'publishes one policy, naming all four labels, scoped to All' {
            $result = Invoke-Main -Confirm:$false
            Should -Invoke New-LabelPolicy -Exactly -Times 1 -ParameterFilter {
                $Name -eq $script:ExpectedPolicyName -and
                -not (Compare-Object $Labels $script:ExpectedNames) -and
                -not (Compare-Object $ExchangeLocation $script:ExpectedGroups)
            }
            Should -Invoke Set-LabelPolicy -Exactly -Times 0
            $result.LabelPolicy | Should -Be 'Created'
        }
    }

    Context 'label policy: already published and matches (idempotent replay)' {
        BeforeEach {
            Mock Get-Label (Get-MatchingLabelGetMock)
            Mock Get-LabelPolicy {
                return [pscustomobject]@{
                    Identity         = $Identity
                    Labels           = $script:ExpectedNames
                    ExchangeLocation = $script:ExpectedGroups
                }
            }
        }

        It 'creates and updates nothing' {
            $result = Invoke-Main -Confirm:$false
            Should -Invoke New-LabelPolicy -Exactly -Times 0
            Should -Invoke Set-LabelPolicy -Exactly -Times 0
            $result.LabelPolicy | Should -Be 'Unchanged'
        }
    }

    Context 'label policy: scope has drifted (published policy is scoped to nobody)' {
        BeforeEach {
            Mock Get-Label (Get-MatchingLabelGetMock)
            Mock Get-LabelPolicy {
                return [pscustomobject]@{
                    Identity         = $Identity
                    Labels           = $script:ExpectedNames
                    ExchangeLocation = @()
                }
            }
        }

        It 'adds the missing scope to the existing policy, in place - never recreates it' {
            $result = Invoke-Main -Confirm:$false
            Should -Invoke New-LabelPolicy -Exactly -Times 0
            Should -Invoke Set-LabelPolicy -Exactly -Times 1 -ParameterFilter {
                $Identity -eq $script:ExpectedPolicyName -and
                $AddExchangeLocation -contains 'All' -and
                $AddExchangeLocation.Count -eq 1 -and
                $null -eq $RemoveExchangeLocation -and
                $null -eq $AddLabel -and
                $null -eq $RemoveLabel
            }
            $result.LabelPolicy | Should -Be 'Updated'
        }
    }

    Context 'label policy: scope has drifted (published policy has an extra, unexpected group)' {
        BeforeEach {
            Mock Get-Label (Get-MatchingLabelGetMock)
            Mock Get-LabelPolicy {
                return [pscustomobject]@{
                    Identity         = $Identity
                    Labels           = $script:ExpectedNames
                    ExchangeLocation = $script:ExpectedGroups + @('mls-contractors')
                }
            }
        }

        It 'removes only the unexpected group, in place' {
            $result = Invoke-Main -Confirm:$false
            Should -Invoke Set-LabelPolicy -Exactly -Times 1 -ParameterFilter {
                $RemoveExchangeLocation -contains 'mls-contractors' -and
                $RemoveExchangeLocation.Count -eq 1 -and
                $null -eq $AddExchangeLocation
            }
            $result.LabelPolicy | Should -Be 'Updated'
        }
    }

    Context 'label policy: labels list has drifted (published policy is missing a label)' {
        BeforeEach {
            Mock Get-Label (Get-MatchingLabelGetMock)
            Mock Get-LabelPolicy {
                return [pscustomobject]@{
                    Identity         = $Identity
                    Labels           = @($script:ExpectedNames | Select-Object -First 3)
                    ExchangeLocation = $script:ExpectedGroups
                }
            }
        }

        It 'adds only the missing label to the existing policy, in place' {
            $result = Invoke-Main -Confirm:$false
            Should -Invoke New-LabelPolicy -Exactly -Times 0
            Should -Invoke Set-LabelPolicy -Exactly -Times 1 -ParameterFilter {
                $AddLabel -contains "$($script:Prefix)-export-controlled" -and
                $AddLabel.Count -eq 1 -and
                $null -eq $RemoveLabel -and
                $null -eq $AddExchangeLocation -and
                $null -eq $RemoveExchangeLocation
            }
            $result.LabelPolicy | Should -Be 'Updated'
        }
    }

    Context '-WhatIf makes no mutating policy calls' {
        It 'with no policy present, neither New-LabelPolicy nor Set-LabelPolicy runs' {
            Mock Get-Label { throw "The Label $Identity doesn't exist" }
            Mock Get-LabelPolicy { throw "The label policy $Identity doesn't exist" }
            $result = Invoke-Main -WhatIf
            Should -Invoke New-LabelPolicy -Exactly -Times 0
            Should -Invoke Set-LabelPolicy -Exactly -Times 0
            $result.LabelPolicy | Should -Be 'WhatIf'
        }

        It 'with a drifted policy, Set-LabelPolicy does not run either' {
            Mock Get-Label (Get-MatchingLabelGetMock)
            Mock Get-LabelPolicy {
                return [pscustomobject]@{ Identity = $Identity; Labels = $script:ExpectedNames; ExchangeLocation = @('mls-flight-operations') }
            }
            Invoke-Main -WhatIf | Out-Null
            Should -Invoke Set-LabelPolicy -Exactly -Times 0
        }
    }

    Context 'publishes a label policy, not just the labels (minimum bar)' {
        It 'calls New-LabelPolicy or Set-LabelPolicy somewhere in the script' {
            $script = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'labels.ps1') -Raw
            $script | Should -Match 'New-LabelPolicy|Set-LabelPolicy'
        }
    }
}
