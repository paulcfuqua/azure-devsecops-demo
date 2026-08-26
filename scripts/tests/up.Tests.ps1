# Pester tests for scripts/up.ps1 - `gh` is mocked ENTIRELY; zero network calls,
# zero GitHub writes. The single seam is Invoke-Gh: nothing in the script reaches
# the CLI except through it, so a mock on that function makes a real dispatch
# structurally impossible from these tests.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'up.ps1')
    Set-StrictMode -Off

    $script:Repo = 'paulcfuqua/azure-devsecops-demo'

    # Every test writes its up-clock record here, never into the real
    # verification/reports/: a unit test must not leave evidence behind that
    # looks like a rebuild proof.
    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-up-$([guid]::NewGuid().ToString('n'))"

    # -AsWhatIf, not -WhatIf: a parameter literally named WhatIf on a function that
    # already declares SupportsShouldProcess collides with the common parameter.
    function Invoke-UpForTest {
        param(
            [switch]$AsWhatIf,
            [switch]$DryRun,
            [switch]$NoWatch,
            [string]$Repository = $script:Repo,
            [string]$Mode = 'full',
            [string]$Layers = 'all',
            [string]$Location = 'eastus2',
            [string]$ImageTag = '',
            [string]$ReportRoot = $script:ReportRoot
        )
        Invoke-Main -Repository $Repository -Mode $Mode -Layers $Layers -Location $Location `
            -ImageTag $ImageTag -DryRun:$DryRun -NoWatch:$NoWatch -ReportRoot $ReportRoot `
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
        $joined = $Arguments -join ' '
        return $joined -like 'workflow run*'
    }
}

AfterAll {
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:ReportRoot) {
        Remove-Item -LiteralPath $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'up.ps1' {
    BeforeEach {
        # Happy-path fixtures; individual tests break specific pieces.
        $script:DemoVariables = @(
            'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'FABRIC_CAPACITY_ID'
        )
        $script:EnvironmentExists = $true
        $script:AuthExitCode = 0
        $script:Dispatched = $false
        $script:ViewCalls = 0
        $script:RunStatuses = @('in_progress', 'completed')
        $script:RunConclusion = 'success'
        $script:CreatedAt = '2026-08-24T10:00:00Z'
        $script:UpdatedAt = '2026-08-24T10:52:00Z'
        $script:Jobs = @(
            @{ name = 'preflight (demo environment guard)'; status = 'completed'; conclusion = 'success' }
            @{ name = 'L7 apps'; status = 'completed'; conclusion = 'success' }
            @{ name = 'oidc-login'; status = 'completed'; conclusion = 'success' }
            @{ name = 'L2 landing zone'; status = 'completed'; conclusion = 'success' }
            @{ name = 'L6 platform'; status = 'completed'; conclusion = 'success' }
            @{ name = 'L5 Fabric + seed'; status = 'completed'; conclusion = 'success' }
            @{ name = 'L8 Copilot Studio'; status = 'completed'; conclusion = 'skipped' }
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
                $id = if ($script:Dispatched) { 9002 } else { 9001 }
                return New-GhResult -Json ("[{`"databaseId`":$id}]")
            }

            if ($joined -like 'run view*') {
                $index = [Math]::Min($script:ViewCalls, $script:RunStatuses.Count - 1)
                $status = $script:RunStatuses[$index]
                $script:ViewCalls++
                $payload = @{
                    status     = $status
                    conclusion = if ($status -eq 'completed') { $script:RunConclusion } else { $null }
                    createdAt  = $script:CreatedAt
                    updatedAt  = $script:UpdatedAt
                    url        = "https://github.com/$script:Repo/actions/runs/9002"
                    jobs       = $script:Jobs
                }
                return New-GhResult -Json ($payload | ConvertTo-Json -Depth 6 -Compress)
            }

            return New-GhResult
        }
    }

    Context 'preflight - refuses before it dispatches' {
        It 'fails actionably when gh is not installed, and dispatches nothing' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'gh' }
            { Invoke-UpForTest } | Should -Throw '*GitHub CLI*not on PATH*'
            Should -Invoke Invoke-Gh -Times 0 -ParameterFilter { Test-DispatchedWorkflow -Arguments $Arguments }
        }

        It 'fails actionably when gh is not authenticated, and dispatches nothing' {
            $script:AuthExitCode = 1
            { Invoke-UpForTest } | Should -Throw '*gh auth login*'
            Should -Invoke Invoke-Gh -Times 0 -ParameterFilter { Test-DispatchedWorkflow -Arguments $Arguments }
        }

        It 'fails when the demo environment does not exist, naming how to create it' {
            $script:EnvironmentExists = $false
            # No backticks in the pattern: -like treats one as an escape character.
            { Invoke-UpForTest } | Should -Throw '*has no*GitHub environment*'
            Should -Invoke Invoke-Gh -Times 0 -ParameterFilter { Test-DispatchedWorkflow -Arguments $Arguments }
        }

        It 'refuses the run the pre-G0 guard would turn into a green no-op' {
            $script:DemoVariables = @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID')
            { Invoke-UpForTest } | Should -Throw '*SKIP every layer*'
            Should -Invoke Invoke-Gh -Times 0 -ParameterFilter { Test-DispatchedWorkflow -Arguments $Arguments }
        }

        It 'names every missing variable and the exact command that sets it' {
            $script:DemoVariables = @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID')
            $message = ''
            try { Invoke-UpForTest } catch { $message = $_.Exception.Message }
            $message | Should -BeLike '*AZURE_SUBSCRIPTION_ID*'
            $message | Should -BeLike '*FABRIC_CAPACITY_ID*'
            $message | Should -BeLike '*gh variable set AZURE_SUBSCRIPTION_ID --env demo*'
        }

        It 'requires FABRIC_CAPACITY_ID, which infra-up preflight also reads' {
            $script:DemoVariables = @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID')
            { Invoke-UpForTest } | Should -Throw '*FABRIC_CAPACITY_ID*'
        }
    }

    Context 'repository resolution' {
        It 'uses the explicit repository without asking gh' {
            Invoke-UpForTest -Repository 'someone/else' | Out-Null
            Should -Invoke Invoke-Gh -Times 0 -ParameterFilter { ($Arguments -join ' ') -like 'repo view*' }
        }

        It 'falls back to gh repo view when none is supplied' {
            $result = Invoke-UpForTest -Repository ''
            $result.Repository | Should -Be $script:Repo
            Should -Invoke Invoke-Gh -Times 1 -ParameterFilter { ($Arguments -join ' ') -like 'repo view*' }
        }

        It 'fails actionably when the repository cannot be resolved' {
            Mock Invoke-Gh { New-GhResult -ExitCode 1 } -ParameterFilter { ($Arguments -join ' ') -like 'repo view*' }
            { Invoke-UpForTest -Repository '' } | Should -Throw '*-Repository owner/name*'
        }
    }

    Context 'dispatch' {
        It 'passes every workflow input through as a -f argument' {
            Invoke-UpForTest -Mode 'full' -Layers 'l5,l6' -Location 'westus3' -ImageTag 'sha-abc' | Out-Null
            Should -Invoke Invoke-Gh -Times 1 -ParameterFilter {
                $joined = $Arguments -join ' '
                $joined -like 'workflow run infra-up.yml*' -and
                $joined -like '*mode=full*' -and
                $joined -like '*layers=l5,l6*' -and
                $joined -like '*location=westus3*' -and
                $joined -like '*image_tag=sha-abc*' -and
                $joined -like '*dry_run=false*'
            }
        }

        It 'sends dry_run=true for a remote plan-only run' {
            Invoke-UpForTest -DryRun | Out-Null
            Should -Invoke Invoke-Gh -Times 1 -ParameterFilter { ($Arguments -join ' ') -like '*dry_run=true*' }
        }

        It 'targets the repository it resolved' {
            Invoke-UpForTest | Out-Null
            Should -Invoke Invoke-Gh -Times 1 -ParameterFilter {
                ($Arguments -join ' ') -like "*--repo $script:Repo*" -and ($Arguments -join ' ') -like 'workflow run*'
            }
        }
    }

    Context '-WhatIf' {
        It 'runs the whole preflight but dispatches nothing' {
            $result = Invoke-UpForTest -AsWhatIf
            $result.WhatIfOnly | Should -BeTrue
            $result.Conclusion | Should -Be 'whatif'
            Should -Invoke Invoke-Gh -Times 0 -ParameterFilter { Test-DispatchedWorkflow -Arguments $Arguments }
        }

        It 'still validates the demo environment, so -WhatIf is a real rehearsal' {
            $script:DemoVariables = @('AZURE_CLIENT_ID')
            { Invoke-UpForTest -AsWhatIf } | Should -Throw '*missing 3 required variable*'
        }

        It 'never polls a run it did not start' {
            Invoke-UpForTest -AsWhatIf | Out-Null
            Should -Invoke Invoke-Gh -Times 0 -ParameterFilter { ($Arguments -join ' ') -like 'run view*' }
        }
    }

    Context 'watching the run' {
        It 'polls until the run reports completed' {
            $script:RunStatuses = @('queued', 'in_progress', 'in_progress', 'completed')
            $result = Invoke-UpForTest
            $result.Conclusion | Should -Be 'success'
            Should -Invoke Invoke-Gh -Times 4 -ParameterFilter { ($Arguments -join ' ') -like 'run view*' }
        }

        It 'waits for a NEW run id rather than reporting the previous run' {
            $result = Invoke-UpForTest
            $result.RunId | Should -Be 9002
        }

        It 'surfaces the per-layer result for every job' {
            $result = Invoke-UpForTest
            @($result.Legs).Count | Should -Be 7
            ($result.Legs | Where-Object { $_.Leg -eq 'L8 Copilot Studio' }).Result | Should -Be 'skipped'
        }

        It 'orders the legs like the replay graph, not alphabetically' {
            $result = Invoke-UpForTest
            $order = @($result.Legs | ForEach-Object { $_.Leg })
            $order[0] | Should -BeLike 'preflight*'
            $order[1] | Should -Be 'oidc-login'
            $order[2] | Should -Be 'L2 landing zone'
            $order[-1] | Should -Be 'L8 Copilot Studio'
        }

        It 'reports a failing run as failure and does not claim success' {
            $script:RunConclusion = 'failure'
            $result = Invoke-UpForTest
            $result.Conclusion | Should -Be 'failure'
        }

        It 'returns immediately with -NoWatch and never polls' {
            $result = Invoke-UpForTest -NoWatch
            $result.Conclusion | Should -Be 'dispatched'
            Should -Invoke Invoke-Gh -Times 0 -ParameterFilter { ($Arguments -join ' ') -like 'run view*' }
        }
    }

    Context 'wall clock - the L11 <60-minute proof is measured on this path' {
        It 'reports its own elapsed time from the invocation' {
            $result = Invoke-UpForTest
            $result.Elapsed | Should -BeOfType [timespan]
            $result.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 0
        }

        It "reports GitHub's run timestamps as the second independent source" {
            $result = Invoke-UpForTest
            $result.RunElapsed | Should -BeOfType [timespan]
            $result.RunElapsed.TotalMinutes | Should -Be 52
        }

        It 'returns null rather than inventing a duration from unusable timestamps' {
            Get-RunDuration -Snapshot ([pscustomobject]@{ CreatedAt = 'not a date'; UpdatedAt = 'nor this' }) |
                Should -BeNullOrEmpty
        }

        It 'returns null when the run ended before it started' {
            Get-RunDuration -Snapshot ([pscustomobject]@{
                    CreatedAt = '2026-08-24T11:00:00Z'; UpdatedAt = '2026-08-24T10:00:00Z'
                }) | Should -BeNullOrEmpty
        }

        It 'formats a sub-hour duration in minutes and seconds' {
            Format-Duration -Duration ([timespan]::FromSeconds(3134)) | Should -Be '52m 14s'
        }

        It 'formats an over-budget duration with hours' {
            Format-Duration -Duration ([timespan]::FromMinutes(75)) | Should -Be '1h 15m 00s'
        }
    }

    Context 'clock handover - V11.4 FAILs rather than inventing a start time' {
        BeforeEach {
            if (Test-Path -LiteralPath $script:ReportRoot) {
                Remove-Item -LiteralPath $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'writes up-clock.json under the report root' {
            $result = Invoke-UpForTest
            $result.ClockPath | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $result.ClockPath | Should -BeTrue
            (Split-Path -Path $result.ClockPath -Leaf) | Should -Be 'up-clock.json'
        }

        It 'records both instants under the exact names layer-11-audit.ps1 falls back to' {
            # Asserted against the RAW text, not the parsed object: ConvertFrom-Json
            # turns an ISO-8601 string back into a [datetime], which would hide a
            # badly formatted file behind PowerShell's own round-trip.
            $result = Invoke-UpForTest
            $raw = Get-Content -LiteralPath $result.ClockPath -Raw
            $raw | Should -Match '"MLS_L11_UP_START":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
            $raw | Should -Match '"MLS_L11_UP_COMPLETED":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
            $clock = $raw | ConvertFrom-Json
            ([datetime]$clock.MLS_L11_UP_COMPLETED) |
                Should -BeGreaterOrEqual ([datetime]$clock.MLS_L11_UP_START)
        }

        It 'carries the run identity and the budget verdict, so the record stands alone' {
            $result = Invoke-UpForTest
            $clock = Get-Content -LiteralPath $result.ClockPath -Raw | ConvertFrom-Json
            $clock.repository | Should -Be $script:Repo
            $clock.runId | Should -Be 9002
            $clock.conclusion | Should -Be 'success'
            $clock.budgetMinutes | Should -Be 60
            $clock.withinBudget | Should -BeTrue
            (Get-Content -LiteralPath $result.ClockPath -Raw) |
                Should -Match "\`"githubRunCreatedAt\`":\s*\`"$([regex]::Escape($script:CreatedAt))\`""
            $clock.clockDefinition | Should -BeLike '*last synchronous layer audit green*'
        }

        It 'records the start with -NoWatch even though nothing stopped the clock' {
            $result = Invoke-UpForTest -NoWatch
            $clock = Get-Content -LiteralPath $result.ClockPath -Raw | ConvertFrom-Json
            $clock.MLS_L11_UP_START | Should -Not -BeNullOrEmpty
            $clock.MLS_L11_UP_COMPLETED | Should -BeNullOrEmpty
            $clock.conclusion | Should -Be 'dispatched'
        }

        It 'writes nothing on -WhatIf: a rehearsal must not leave a proof record' {
            $result = Invoke-UpForTest -AsWhatIf
            $result.ClockPath | Should -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path -Path $script:ReportRoot -ChildPath 'up-clock.json') |
                Should -BeFalse
        }

        It 'exports both variables to $GITHUB_ENV when running inside Actions' {
            $githubEnv = Join-Path -Path $script:ReportRoot -ChildPath 'github-env.txt'
            New-Item -ItemType Directory -Path $script:ReportRoot -Force | Out-Null
            Set-Content -LiteralPath $githubEnv -Value '' -Encoding utf8
            $saved = $env:GITHUB_ENV
            try {
                $env:GITHUB_ENV = $githubEnv
                Invoke-UpForTest | Out-Null
                $lines = @(Get-Content -LiteralPath $githubEnv | Where-Object { $_ })
                @($lines | Where-Object { $_ -like 'MLS_L11_UP_START=*' }).Count | Should -Be 1
                @($lines | Where-Object { $_ -like 'MLS_L11_UP_COMPLETED=*' }).Count | Should -Be 1
            }
            finally {
                if ($null -eq $saved) { Remove-Item Env:\GITHUB_ENV -ErrorAction SilentlyContinue }
                else { $env:GITHUB_ENV = $saved }
            }
        }

        It 'warns instead of failing the rebuild when the record cannot be written' {
            Mock Set-Content { throw 'disk full' }
            $result = Invoke-UpForTest -WarningAction SilentlyContinue
            $result.Conclusion | Should -Be 'success'
            $result.ClockPath | Should -BeNullOrEmpty
        }
    }

    Context 'leg ordering helper' {
        It 'ranks known legs in replay order' {
            (Get-LegSortKey -JobName 'L2 landing zone') |
                Should -BeLessThan (Get-LegSortKey -JobName 'L6 platform')
        }

        It 'puts an unrecognised leg last rather than dropping it' {
            (Get-LegSortKey -JobName 'something new') |
                Should -BeGreaterThan (Get-LegSortKey -JobName 'summary')
        }
    }

    Context 'structural guarantees' {
        It 'reaches GitHub only through the single mocked seam' {
            $source = Get-Content -LiteralPath (
                Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'up.ps1'
            ) -Raw
            # One `& gh` call in the whole file, inside Invoke-Gh.
            ([regex]::Matches($source, '&\s+gh\s+@Arguments')).Count | Should -Be 1
        }

        It 'never touches Azure directly - the deployment authenticates by OIDC in the runner' {
            $source = Get-Content -LiteralPath (
                Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'up.ps1'
            ) -Raw
            $source | Should -Not -Match '&\s+az\s'
            $source | Should -Not -Match 'Connect-AzAccount'
        }
    }
}
