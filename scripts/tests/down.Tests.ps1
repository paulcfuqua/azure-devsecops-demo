# Pester tests for scripts/down.ps1 - `gh` is mocked ENTIRELY; zero network calls,
# zero GitHub writes, and nothing here can delete anything. The single seam is
# Invoke-Gh, so a mock on it makes a real dispatch structurally impossible.
#
# The tests that matter most are the ones about the MANIFEST and the LINE: this
# script is gate-free by design, so the only protection an operator has is that it
# tells the truth about the blast radius before it acts.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'down.ps1')
    Set-StrictMode -Off

    $script:Repo = 'paulcfuqua/azure-devsecops'
    $script:RealNamingFile = Join-Path -Path $PSScriptRoot -ChildPath '..' `
        -AdditionalChildPath '../infra/bicep/naming.bicep'
    $script:DownScript = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'down.ps1'

    # -AsWhatIf, not -WhatIf: a parameter literally named WhatIf on a function that
    # already declares SupportsShouldProcess collides with the common parameter.
    function Invoke-DownForTest {
        param(
            [switch]$AsWhatIf,
            [switch]$SkipFabric,
            [switch]$NoWatch,
            [string]$Repository = $script:Repo,
            [string]$NamingFile = $script:RealNamingFile
        )
        Invoke-Main -Repository $Repository -NamingFile $NamingFile `
            -SkipFabric:$SkipFabric -NoWatch:$NoWatch `
            -TimeoutMinutes 1 -PollSeconds 1 -WhatIf:$AsWhatIf
    }

    function New-GhResult {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds the in-memory record that stands in for one gh invocation. It is a test fixture: it changes no system state, and adding ShouldProcess would make every mocked call prompt.')]
        param([int]$ExitCode = 0, [string]$Json = '')
        return [pscustomobject]@{ ExitCode = $ExitCode; Output = @($Json) }
    }

    function Test-DispatchedWorkflow {
        param([object[]]$Arguments)
        return ($Arguments -join ' ') -like 'workflow run*'
    }
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
}

Describe 'down.ps1' {
    BeforeEach {
        $script:DemoVariables = @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID')
        $script:EnvironmentExists = $true
        $script:AuthExitCode = 0
        $script:Dispatched = $false
        $script:ViewCalls = 0
        $script:RunStatuses = @('in_progress', 'completed')
        $script:RunConclusion = 'success'
        $script:Jobs = @(
            @{ name = 'delete the four demo resource groups'; status = 'completed'; conclusion = 'success' }
            @{ name = 'preflight (demo environment guard)'; status = 'completed'; conclusion = 'success' }
            @{ name = 'Fabric items + capacity pause'; status = 'completed'; conclusion = 'success' }
            @{ name = 'remove the cost-export definition'; status = 'completed'; conclusion = 'success' }
        )

        Mock Get-Command { [pscustomobject]@{ Name = 'gh' } } -ParameterFilter { $Name -eq 'gh' }
        Mock Start-Sleep { }
        Mock Write-Status { }
        Mock Out-Host { }

        Mock Invoke-Gh {
            $joined = $Arguments -join ' '

            if ($joined -like 'auth status*') { return New-GhResult -ExitCode $script:AuthExitCode -Json 'auth detail' }

            if ($joined -like 'repo view*') {
                return New-GhResult -Json (@{ nameWithOwner = $script:Repo } | ConvertTo-Json -Compress)
            }

            if ($joined -like 'api repos/*environments/demo/variables*') {
                if (-not $script:EnvironmentExists) { return New-GhResult -ExitCode 1 -Json '' }
                $payload = @{ variables = @($script:DemoVariables | ForEach-Object { @{ name = $_ } }) }
                return New-GhResult -Json ($payload | ConvertTo-Json -Depth 5 -Compress)
            }

            if ($joined -like 'workflow run*') {
                $script:Dispatched = $true
                return New-GhResult
            }

            if ($joined -like 'run list*') {
                $id = if ($script:Dispatched) { 7002 } else { 7001 }
                return New-GhResult -Json ("[{`"databaseId`":$id}]")
            }

            if ($joined -like 'run view*') {
                $index = [Math]::Min($script:ViewCalls, $script:RunStatuses.Count - 1)
                $status = $script:RunStatuses[$index]
                $script:ViewCalls++
                $payload = @{
                    status     = $status
                    conclusion = if ($status -eq 'completed') { $script:RunConclusion } else { $null }
                    createdAt  = '2026-08-24T10:00:00Z'
                    updatedAt  = '2026-08-24T10:14:00Z'
                    url        = "https://github.com/$script:Repo/actions/runs/7002"
                    jobs       = $script:Jobs
                }
                return New-GhResult -Json ($payload | ConvertTo-Json -Depth 6 -Compress)
            }

            return New-GhResult
        }
    }

    Context 'preflight - refuses before it dispatches' {
        It 'fails actionably when gh is not installed' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'gh' }
            { Invoke-DownForTest } | Should -Throw '*GitHub CLI*not on PATH*'
            Should -Invoke Invoke-Gh -Times 0 -ParameterFilter { Test-DispatchedWorkflow -Arguments $Arguments }
        }

        It 'fails actionably when gh is not authenticated' {
            $script:AuthExitCode = 1
            { Invoke-DownForTest } | Should -Throw '*gh auth login*'
        }

        It 'refuses a teardown that would skip every stage and still report success' {
            $script:DemoVariables = @('AZURE_CLIENT_ID')
            { Invoke-DownForTest } | Should -Throw '*SKIP every stage*'
            Should -Invoke Invoke-Gh -Times 0 -ParameterFilter { Test-DispatchedWorkflow -Arguments $Arguments }
        }

        It 'explains that a silent no-op teardown is the most expensive failure' {
            $script:DemoVariables = @('AZURE_CLIENT_ID')
            $message = ''
            try { Invoke-DownForTest } catch { $message = $_.Exception.Message }
            $message | Should -BeLike '*deletes nothing*'
            $message | Should -BeLike '*gh variable set AZURE_TENANT_ID --env demo*'
        }

        It 'does not require FABRIC_CAPACITY_ID, matching infra-down.yml own guard' {
            { Invoke-DownForTest } | Should -Not -Throw
        }

        It 'fails when the demo environment does not exist' {
            $script:EnvironmentExists = $false
            # No backticks in the pattern: -like treats one as an escape character.
            { Invoke-DownForTest } | Should -Throw '*has no*GitHub environment*'
        }
    }

    Context 'names come from naming.bicep, never hardcoded' {
        It 'reads the company prefix out of the real naming.bicep' {
            Get-CompanyPrefix -Path $script:RealNamingFile | Should -Be 'mls'
        }

        It 'refuses rather than guessing when naming.bicep is absent' {
            { Get-CompanyPrefix -Path (Join-Path $TestDrive 'nope.bicep') } |
                Should -Throw '*does not exist*'
        }

        It 'refuses rather than guessing when the prefix cannot be parsed' {
            $broken = Join-Path $TestDrive 'broken.bicep'
            Set-Content -LiteralPath $broken -Value 'var somethingElse = 42'
            { Get-CompanyPrefix -Path $broken } | Should -Throw '*Could not parse*'
        }

        It 'stops before dispatch when the names cannot be resolved' {
            $broken = Join-Path $TestDrive 'broken.bicep'
            Set-Content -LiteralPath $broken -Value 'var somethingElse = 42'
            { Invoke-DownForTest -NamingFile $broken } | Should -Throw '*Could not parse*'
            Should -Invoke Invoke-Gh -Times 0 -ParameterFilter { Test-DispatchedWorkflow -Arguments $Arguments }
        }
    }

    Context 'the manifest - "frictionless but never surprising"' {
        It 'names exactly the four demo resource groups, prefix-resolved' {
            $manifest = Get-TeardownManifest -Prefix 'mls'
            $manifest.ResourceGroups | Should -Be @(
                'mls-rg-platform', 'mls-rg-apps', 'mls-rg-data', 'mls-rg-ops'
            )
        }

        It 'uses whatever prefix naming.bicep declares, not a literal mls' {
            $manifest = Get-TeardownManifest -Prefix 'acme'
            $manifest.ResourceGroups[0] | Should -Be 'acme-rg-platform'
        }

        It 'lists the Fabric workspace items and the capacity pause' {
            $what = @((Get-TeardownManifest -Prefix 'mls').Deletes | ForEach-Object { $_.What })
            ($what -join ' ') | Should -BeLike '*Fabric workspace ITEMS*'
            ($what -join ' ') | Should -BeLike '*capacity pause*'
        }

        It 'says the workspace SHELL survives, in the same breath as deleting its items' {
            $items = @((Get-TeardownManifest -Prefix 'mls').Deletes |
                    Where-Object { $_.What -like '*workspace ITEMS*' })
            $items[0].Detail | Should -BeLike '*shell and its role grants survive*'
        }

        It 'lists the cost-export definition, resolved from the prefix' {
            $what = @((Get-TeardownManifest -Prefix 'mls').Deletes | ForEach-Object { $_.What })
            ($what -join ' ') | Should -BeLike '*mls-cost-daily*'
        }

        It 'drops the Fabric stages under -SkipFabric but keeps the RG deletes' {
            $manifest = Get-TeardownManifest -Prefix 'mls' -SkipFabric
            ($manifest.Deletes | ForEach-Object { $_.What }) -join ' ' | Should -Not -BeLike '*Fabric*'
            @($manifest.ResourceGroups).Count | Should -Be 4
        }

        It 'spells out everything that survives, so nobody is surprised either way' {
            $survives = (Get-TeardownManifest -Prefix 'mls').Survives -join ' '
            foreach ($expected in @(
                    'Entra', 'Purview labels', 'workspace SHELL', 'capacity itself',
                    'Management group', 'budget', 'OIDC federation', 'Copilot Studio')) {
                $survives | Should -BeLike "*$expected*"
            }
        }

        It 'prints the manifest BEFORE dispatching, not after' {
            $script:SawManifest = $false
            Mock Write-TeardownManifest { $script:SawManifest = $true }
            Mock Invoke-Gh {
                if (($Arguments -join ' ') -like 'workflow run*') {
                    $script:ManifestPrintedFirst = $script:SawManifest
                    $script:Dispatched = $true
                }
                return New-GhResult -Json '[{"databaseId":7002}]'
            } -ParameterFilter { ($Arguments -join ' ') -like 'workflow run*' }

            Invoke-DownForTest -NoWatch | Out-Null
            $script:ManifestPrintedFirst | Should -BeTrue
        }

        It 'returns the resource groups it named, so a caller can assert on them' {
            (Invoke-DownForTest -NoWatch).ResourceGroups | Should -Contain 'mls-rg-data'
        }
    }

    Context 'the line this script cannot cross' {
        It 'contains no code path to a tenant object' {
            $source = Get-Content -LiteralPath $script:DownScript -Raw
            # Every G3-scoped teardown lives in infra/*/teardown.ps1. If this script
            # ever references one, the structural separation is gone.
            $source | Should -Not -Match 'infra/entra/teardown'
            $source | Should -Not -Match 'infra/purview/teardown'
            $source | Should -Not -Match 'infra/policy/teardown'
            $source | Should -Not -Match 'Remove-MgUser|Remove-Label|Remove-AzManagementGroup'
        }

        It 'never calls az or the Azure PowerShell modules itself' {
            $source = Get-Content -LiteralPath $script:DownScript -Raw
            $source | Should -Not -Match '&\s+az\s'
            $source | Should -Not -Match 'Connect-AzAccount'
        }

        It 'reaches GitHub only through the single mocked seam' {
            $source = Get-Content -LiteralPath $script:DownScript -Raw
            ([regex]::Matches($source, '&\s+gh\s+@Arguments')).Count | Should -Be 1
        }

        It 'has no confirmation prompt - gate-free is the design, not an oversight' {
            $source = Get-Content -LiteralPath $script:DownScript -Raw
            $source | Should -Not -Match 'Read-Host'
            $source | Should -Not -Match 'ConfirmImpact'
        }
    }

    Context 'dispatch' {
        It 'dispatches infra-down.yml against the resolved repository' {
            Invoke-DownForTest | Out-Null
            Should -Invoke Invoke-Gh -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like "workflow run infra-down.yml --repo $script:Repo*"
            }
        }

        It 'passes skip_fabric through' {
            Invoke-DownForTest -SkipFabric | Out-Null
            Should -Invoke Invoke-Gh -Times 1 -ParameterFilter { ($Arguments -join ' ') -like '*skip_fabric=true*' }
        }

        It 'defaults skip_fabric to false' {
            Invoke-DownForTest | Out-Null
            Should -Invoke Invoke-Gh -Times 1 -ParameterFilter { ($Arguments -join ' ') -like '*skip_fabric=false*' }
        }
    }

    Context '-WhatIf' {
        It 'prints what would be deleted and dispatches nothing' {
            $result = Invoke-DownForTest -AsWhatIf
            $result.WhatIfOnly | Should -BeTrue
            $result.Conclusion | Should -Be 'whatif'
            Should -Invoke Invoke-Gh -Times 0 -ParameterFilter { Test-DispatchedWorkflow -Arguments $Arguments }
        }

        It 'still names the four resource groups, which is the point of the rehearsal' {
            (Invoke-DownForTest -AsWhatIf).ResourceGroups | Should -Be @(
                'mls-rg-platform', 'mls-rg-apps', 'mls-rg-data', 'mls-rg-ops'
            )
        }

        It 'never polls a run it did not start' {
            Invoke-DownForTest -AsWhatIf | Out-Null
            Should -Invoke Invoke-Gh -Times 0 -ParameterFilter { ($Arguments -join ' ') -like 'run view*' }
        }
    }

    Context 'watching the teardown' {
        It 'polls until the run reports completed' {
            $script:RunStatuses = @('queued', 'in_progress', 'completed')
            (Invoke-DownForTest).Conclusion | Should -Be 'success'
            Should -Invoke Invoke-Gh -Times 3 -ParameterFilter { ($Arguments -join ' ') -like 'run view*' }
        }

        It 'waits for a NEW run id rather than reporting the previous run' {
            (Invoke-DownForTest).RunId | Should -Be 7002
        }

        It 'surfaces every teardown stage' {
            @((Invoke-DownForTest).Stages).Count | Should -Be 4
        }

        It 'orders the stages like the runbook, not alphabetically' {
            $order = @((Invoke-DownForTest).Stages | ForEach-Object { $_.Stage })
            $order[0] | Should -BeLike 'preflight*'
            $order[1] | Should -BeLike 'Fabric items*'
            $order[2] | Should -BeLike 'remove the cost-export*'
            $order[3] | Should -BeLike 'delete the four*'
        }

        It 'reports a failing teardown as failure - a stranded RG keeps costing money' {
            $script:RunConclusion = 'failure'
            (Invoke-DownForTest).Conclusion | Should -Be 'failure'
        }

        It 'returns immediately with -NoWatch' {
            (Invoke-DownForTest -NoWatch).Conclusion | Should -Be 'dispatched'
            Should -Invoke Invoke-Gh -Times 0 -ParameterFilter { ($Arguments -join ' ') -like 'run view*' }
        }

        It 'reports the elapsed time even though teardown is not on the rebuild clock' {
            (Invoke-DownForTest).Elapsed | Should -BeOfType [timespan]
        }
    }
}
