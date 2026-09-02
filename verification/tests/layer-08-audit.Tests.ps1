# Pester tests for verification/layer-08-audit.ps1 - Dataverse, the MCP server and the
# lakehouse SQL endpoint are all mocked; zero cloud calls.

BeforeAll {
    $env:MLS_SKIP_MAIN = '1'
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'layer-08-audit.ps1')
    # No Set-StrictMode -Off: the audit scripts set -Version Latest and CI runs them
    # that way, so the harness must not relax the language mode it is testing (F49).

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-l08-$([guid]::NewGuid().ToString('n'))"
    New-Item -ItemType Directory -Path $script:ReportRoot -Force | Out-Null
    # A REAL SOLUTION TREE, not a lone manifest (F145). V8.1's expected component set
    # comes from three files - the manifest's RootComponents, every botcomponent's
    # <name>, and the connection-reference logical names - so a flat fixture would
    # exercise a parse the production code no longer performs, and would keep passing
    # while the thing it stands for was broken.
    $script:SolutionRoot = Join-Path -Path $script:ReportRoot -ChildPath 'mlsopsagent'
    New-Item -ItemType Directory -Path (Join-Path $script:SolutionRoot 'Other') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:SolutionRoot 'Assets') -Force | Out-Null
    $script:SolutionPath = Join-Path -Path $script:SolutionRoot -ChildPath 'Other' -AdditionalChildPath 'Solution.xml'
    Set-Content -LiteralPath $script:SolutionPath -Encoding utf8 -Value @'
<?xml version="1.0" encoding="utf-8"?>
<ImportExportXml>
  <SolutionManifest>
    <UniqueName>mlsopsagent</UniqueName>
    <Version>1.0.0.7</Version>
    <RootComponents>
      <RootComponent type="10001" schemaName="mls_opsagent" />
    </RootComponents>
  </SolutionManifest>
</ImportExportXml>
'@

    # 'Sign in ' carries a trailing space in Dataverse and in the committed file. The
    # comparison is exact, so the fixture keeps it: a helper that trimmed here would be
    # supplying the answer it is checking.
    foreach ($component in @(
            @{ Schema = 'mls_opsagent.topic.Greeting'; Name = 'Greeting' },
            @{ Schema = 'mls_opsagent.topic.Signin'; Name = 'Sign in ' })) {
        $dir = Join-Path -Path $script:SolutionRoot -ChildPath 'botcomponents' -AdditionalChildPath $component.Schema
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'botcomponent.xml') -Encoding utf8 -Value @"
<botcomponent schemaname="$($component.Schema)">
  <componenttype>9</componenttype>
  <name>$($component.Name)</name>
</botcomponent>
"@
    }

    Set-Content -LiteralPath (Join-Path $script:SolutionRoot 'Assets' 'botcomponent_connectionreferenceset.xml') -Encoding utf8 -Value @'
<botcomponent_connectionreferenceset>
  <botcomponent_connectionreference botcomponentid.schemaname="mls_opsagent.topic.Tools" connectionreferenceid.connectionreferencelogicalname="mls_opsagent.shared_mcp.abc123">
    <iscustomizable>1</iscustomizable>
  </botcomponent_connectionreference>
</botcomponent_connectionreferenceset>
'@

    $script:AllowedTool = @('query_lakehouse_sql', 'query_log_analytics', 'get_github_security',
        'get_defender_posture', 'get_cost_series')
    $script:EvalPath = Join-Path -Path $script:ReportRoot -ChildPath 'agent-eval-results.json'
    $script:EnvironmentVariable = @('MLS_POWER_PLATFORM_ENV_URL', 'MLS_DATAVERSE_TOKEN', 'MLS_EVAL_RESULTS',
        'MLS_MCP_SERVER_URL', 'MLS_SQL_ENDPOINT')
    $script:SavedEnvironment = @{}
    foreach ($name in $script:EnvironmentVariable) { $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }

    function New-EvalArtifact {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture builder: writes one temp-directory JSON artifact the audit then reads; no system state is changed.')]
        param([int]$Passing = 10, [switch]$ToolsOnlyHarness, [string]$RogueTool = '', [switch]$GeneratedUi, [double]$SlowLatency = 0)
        $questions = @()
        for ($i = 1; $i -le 10; $i++) {
            $pass = ($i -le $Passing)
            $latency = if ($SlowLatency -gt 0 -and $i -eq 10) { $SlowLatency } else { 2.5 }
            $answer = if ($pass) { 'Saturday has the most launches (309).' } else { 'Tuesday has the most launches (77).' }
            if ($GeneratedUi -and $i -eq 1) { $answer = '<div class="chart">Saturday</div>' }
            $questions += [pscustomobject]@{
                id             = "q$i"
                question       = 'Which day of the week has the most launches?'
                pass           = $pass
                latencySeconds = $latency
                answer         = $answer
                referenceSql   = 'SELECT TOP 1 weekday, launches FROM v_launch_weekday ORDER BY launches DESC'
                toolCalls      = @([pscustomobject]@{ name = $(if ($RogueTool -and $i -eq 1) { $RogueTool } else { 'query_lakehouse_sql' }) })
                card           = [pscustomobject]@{
                    type    = 'AdaptiveCard'
                    version = '1.5'
                    body    = @([pscustomobject]@{ type = 'TextBlock'; text = 'Saturday' })
                    actions = @([pscustomobject]@{ type = 'Action.Submit'; title = 'Details' })
                }
            }
        }
        $document = [ordered]@{
            mode        = $(if ($ToolsOnlyHarness) { 'tools' } else { 'agent' })
            path        = $(if ($ToolsOnlyHarness) { '' } else { 'mcp-tools-only' })
            passed      = $Passing
            total       = 10
            toolsListed = $script:AllowedTool
            questions   = $questions
        }
        Set-Content -LiteralPath $script:EvalPath -Encoding utf8 -Value ($document | ConvertTo-Json -Depth 12)
    }

    function Get-Row {
        param($Context, [string]$Id)
        return @($Context.Criterion | Where-Object { $_.Id -eq $Id })[0]
    }

    function Invoke-AuditForTest {
        param(
            [switch]$NoRetry,
            [string]$EnvironmentUrl = 'https://mls.crm.dynamics.com',
            [string]$SolutionPath = $script:SolutionPath,
            [string]$EvalResultPath = $script:EvalPath,
            [string]$McpServerUrl = 'https://mls-mcp-demo-ca.example.io/mcp',
            [string]$SqlEndpoint = 'abc.datawarehouse.fabric.microsoft.com'
        )
        Invoke-Main -EnvironmentUrl $EnvironmentUrl -DataverseToken 'dv-token' -SolutionPath $SolutionPath `
            -EvalResultPath $EvalResultPath -McpServerUrl $McpServerUrl -AllowedTool $script:AllowedTool `
            -AdaptiveCardVersion '1.5' -LatencyBudgetSeconds 20 -EvalPassBar 9 -SqlEndpoint $SqlEndpoint `
            -LakehouseName 'mls_operations' -ReportRoot $script:ReportRoot -NoRetry:$NoRetry
    }
}

AfterAll {
    foreach ($name in $script:EnvironmentVariable) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnvironment[$name]) }
    Remove-Item Env:\MLS_SKIP_MAIN -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:ReportRoot) {
        Remove-Item -LiteralPath $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'layer-08-audit' {
    BeforeEach {
        foreach ($name in $script:EnvironmentVariable) { [Environment]::SetEnvironmentVariable($name, $null) }
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'
        New-EvalArtifact -Passing 10

        $script:DeployedVersion = '1.0.0.7'
    # What Dataverse reports: the two roots, the two topics BY DISPLAY NAME, and the
    # connection reference. V8.1 used to compare this against the two roots alone and
    # call the other three drift.
    $script:DeployedComponent = @('mls_opsagent', 'Greeting', 'Sign in ',
        'mls_opsagent.shared_mcp.abc123')
        $script:UnmanagedLayer = $false
        $script:AdvertisedTool = $script:AllowedTool

        Mock Invoke-MlsRest {
            if ($Uri -like '*solutions*') {
                return [pscustomobject]@{ value = @([pscustomobject]@{
                            uniquename = 'mlsopsagent'; version = $script:DeployedVersion; solutionid = 'sol-1'
                        })
                }
            }
            if ($Uri -like '*solutioncomponentsummaries*') {
                return [pscustomobject]@{ value = @($script:DeployedComponent | ForEach-Object {
                            [pscustomobject]@{ msdyn_name = $_; msdyn_componenttype = 1; msdyn_unmanagedlayer = $script:UnmanagedLayer }
                        })
                }
            }
            throw "unexpected Dataverse call: $Uri"
        }

        # V8.3 reads the DECLARED tool set from the unauthenticated /healthz, not from
        # tools/list behind the shared-secret gate (F100). The fake answers as the server
        # does: the same names the registry would publish, in a `toolNames` array.
        $script:HealthStatus = 200
        Mock Invoke-MlsHttp {
            if ("$Uri" -notlike '*/healthz') { throw "unexpected HTTP call: $Uri" }
            return [pscustomobject]@{
                StatusCode = $script:HealthStatus
                Content    = (@{ ok = $true; tools = @($script:AdvertisedTool).Count; toolNames = @($script:AdvertisedTool) } | ConvertTo-Json -Depth 5)
                Headers    = @{}
                Error      = $null
            }
        }

        Mock Invoke-MlsSqlQuery {
            return @([pscustomobject]@{ weekday = 'Saturday'; launches = 309 })
        }

        Mock Invoke-MlsAz { throw "unexpected az call: $($Argument -join ' ')" }
    }

    Context 'all criteria pass' {
        It 'records V8.1-V8.5 as PASS and exits 0' {
            $context = Invoke-AuditForTest
            @($context.Criterion).Id | Should -Be @('V8.1', 'V8.2', 'V8.3', 'V8.4', 'V8.5')
            @($context.Criterion | Where-Object { $_.Status -ne 'PASS' }) | Should -BeNullOrEmpty
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 're-derives each answer from the lakehouse instead of trusting the eval artifact' {
            $context = Invoke-AuditForTest
            Should -Invoke Invoke-MlsSqlQuery -Exactly -Times 10
            (Get-Row -Context $context -Id 'V8.2').Observed | Should -BeLike '*Verifier re-derivation*'
        }

        It 'records which path the run used' {
            $context = Invoke-AuditForTest
            ($context.Note -join ' ') | Should -BeLike '*mcp-tools-only*'
        }
    }

    Context 'a criterion fails on a realistic wrong value' {
        It 'fails V8.1 when the deployed solution version drifts from the committed one' {
            $script:DeployedVersion = '1.0.0.9'
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V8.1'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*deployed=1.0.0.9 committed=1.0.0.7*'
            Get-MlsExitCode -Context $context | Should -Be 1
        }

        It 'fails V8.1 when a component carries an unmanaged layer (a browser edit after import)' {
            $script:UnmanagedLayer = $true
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V8.1').Observed | Should -BeLike '*unmanaged layer*'
        }

        It 'fails V8.2 below the 9/10 pass bar' {
            New-EvalArtifact -Passing 7
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V8.2'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*7 of 10 questions*'
        }

        It 'fails V8.2 when the artifact is the tools-only harness rather than an agent run' {
            New-EvalArtifact -Passing 10 -ToolsOnlyHarness
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V8.2'
            $row.Status | Should -Be 'FAIL'
            $row.Detail | Should -BeLike '*tools-only harness*'
        }

        It 'fails V8.3 when a tool outside the five-tool allowlist was invoked' {
            New-EvalArtifact -Passing 10 -RogueTool 'run_arbitrary_sql'
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V8.3').Observed | Should -BeLike '*run_arbitrary_sql*'
        }

        It 'fails V8.3 when the MCP server advertises a sixth tool' {
            $script:AdvertisedTool = $script:AllowedTool + 'delete_everything'
            $context = Invoke-AuditForTest -NoRetry
            (Get-Row -Context $context -Id 'V8.3').Observed | Should -BeLike '*delete_everything*'
        }

        It 'fails V8.4 on a single generated-UI response' {
            New-EvalArtifact -Passing 10 -GeneratedUi
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V8.4'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*generated UI code*'
        }

        It 'fails V8.5 when p95 latency breaches the 20 s budget' {
            New-EvalArtifact -Passing 10 -SlowLatency 41.5
            $context = Invoke-AuditForTest -NoRetry
            $row = Get-Row -Context $context -Id 'V8.5'
            $row.Status | Should -Be 'FAIL'
            $row.Observed | Should -BeLike '*p95 = 41.5s*'
        }
    }

    Context 'retry' {
        It 'retries V8.1 through Dataverse read replication without sleeping the whole window' {
            $script:Calls = 0
            Mock Invoke-MlsRest {
                if ($Uri -like '*solutions*') {
                    $script:Calls++
                    if ($script:Calls -lt 2) { return [pscustomobject]@{ value = @() } }
                    return [pscustomobject]@{ value = @([pscustomobject]@{ uniquename = 'mlsopsagent'; version = '1.0.0.7'; solutionid = 'sol-1' }) }
                }
                if ($Uri -like '*solutioncomponentsummaries*') {
                    return [pscustomobject]@{ value = @($script:DeployedComponent | ForEach-Object { [pscustomobject]@{ msdyn_name = $_ } }) }
                }
                throw "unexpected Dataverse call: $Uri"
            }
            $context = Invoke-AuditForTest
            $row = Get-Row -Context $context -Id 'V8.1'
            $row.Status | Should -Be 'PASS'
            $row.Attempt | Should -Be 2
            $row.RetryWindowMinutes | Should -Be 5
            # One poll interval, not the whole window - asserted against the row's own
            # cadence rather than a literal (F59).
            $row.SleptSeconds | Should -Be $row.PollIntervalSecond
            $row.SleptSeconds | Should -BeLessThan ($row.RetryWindowMinutes * 60 + 1)
            Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 1
        }
    }

    Context 'a check that throws' {
        It 'records V8.2 as FAIL when the lakehouse re-derivation errors, and still evaluates the rest' {
            Mock Invoke-MlsSqlQuery { throw 'Login failed: the capacity is paused.' }
            $context = Invoke-AuditForTest -NoRetry
            @($context.Criterion).Count | Should -Be 5
            (Get-Row -Context $context -Id 'V8.2').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V8.2').Observed | Should -BeLike '*capacity is paused*'
            (Get-Row -Context $context -Id 'V8.4').Status | Should -Be 'PASS'
        }
    }

    Context 'missing input - the pre-L8 state, recorded as labelled SKIPs' {
        It 'records every criterion as SKIP when nothing is deployed yet, and never as a pass' {
            $context = Invoke-AuditForTest -EnvironmentUrl '' -EvalResultPath (Join-Path -Path $script:ReportRoot -ChildPath 'absent.json') `
                -McpServerUrl '' -SqlEndpoint '' -NoRetry
            @($context.Criterion).Count | Should -Be 5
            @($context.Criterion | Where-Object { $_.Status -ne 'SKIP' }) | Should -BeNullOrEmpty
            (Get-Row -Context $context -Id 'V8.1').Detail | Should -BeLike '*Power Platform environment*'
            (Get-Row -Context $context -Id 'V8.2').Detail | Should -BeLike '*copilot-eval.yml*'
            Get-MlsExitCode -Context $context | Should -Be 0
        }

        It 'records V8.1 as SKIP when the solution has not been exported into the repo yet' {
            $context = Invoke-AuditForTest -SolutionPath (Join-Path -Path $script:ReportRoot -ChildPath 'no-solution.xml') -NoRetry
            $row = Get-Row -Context $context -Id 'V8.1'
            $row.Status | Should -Be 'SKIP'
            $row.Detail | Should -BeLike '*.gitkeep placeholder*'
        }

        It 'records V8.2 as SKIP when the lakehouse endpoint is unavailable for re-derivation' {
            $context = Invoke-AuditForTest -SqlEndpoint '' -NoRetry
            $row = Get-Row -Context $context -Id 'V8.2'
            $row.Status | Should -Be 'SKIP'
            $row.Detail | Should -BeLike '*re-derive*'
        }
    }
}

Describe 'V8.1 builds its expected set from the whole solution tree (F145)' {
    # V8.1 built the expected component set from Other/Solution.xml's RootComponents
    # alone. That file lists the roots - one, in the real solution - while Dataverse
    # reports every component summary, including all fifteen topics. Set equality between
    # those two lists could never hold, so V8.1 failed on a correct deployment with
    #
    #     components missing [] extra [Conversation Start, Fallback, Greeting, ...]
    #
    # naming sixteen legitimate components as though they were drift. The register
    # recorded the cause as a missing Verifier permission; the read had succeeded every
    # time. A criterion that cannot pass is not a strict criterion, it is a broken one -
    # and it hid the real question, which is whether the deployment matches the repo.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:RealSolution = Join-Path $script:Root 'infra/copilot-studio/solution/MeridianLaunchCopilot/Other/Solution.xml'
    }

    It 'reads names from all three committed sources, not RootComponents alone' {
        $committed = Get-CommittedSolution -Path $script:RealSolution
        $committed.ComponentReadable | Should -BeTrue

        # One root component, and it is the only thing the old parse could see.
        $committed.Component | Should -Contain 'mls_5Fmeridian-20ops-20tools'
        # A topic: only reachable through botcomponents/*/botcomponent.xml.
        $committed.Component | Should -Contain 'Greeting'
        # The connection reference: only reachable through Assets/.
        ($committed.Component | Where-Object { $_ -like 'mls_MeridianLaunchCopilot.shared_*' }) |
            Should -Not -BeNullOrEmpty

        # Seventeen is what Dataverse reported for this solution on 2026-09-02. A change
        # here is a real change to the agent and should be seen, not absorbed.
        @($committed.Component).Count | Should -Be 17
    }

    It 'does not trim a name, because Dataverse does not' {
        # 'Sign in ' has a trailing space at both ends of the comparison. Normalising it
        # here would hide a genuine rename behind a cosmetic one.
        (Get-CommittedSolution -Path $script:RealSolution).Component | Should -Contain 'Sign in '
    }

    It 'reports UNOBSERVABLE rather than inventing an empty expected set' {
        # THE POINT OF THE WHOLE FIX. With no botcomponents directory the expected set is
        # short, and a short expected set turns every deployed component into an "extra".
        # An audit that cannot see a thing says so; it never reports the thing as absent,
        # and it never reports what it could not enumerate as unexpected.
        $bare = Join-Path ([IO.Path]::GetTempPath()) "mls-f145-$([guid]::NewGuid().ToString('n'))"
        New-Item -ItemType Directory -Path (Join-Path $bare 'Other') -Force | Out-Null
        try {
            Copy-Item -LiteralPath $script:RealSolution -Destination (Join-Path $bare 'Other' 'Solution.xml')
            $committed = Get-CommittedSolution -Path (Join-Path $bare 'Other' 'Solution.xml')
            $committed.ComponentReadable | Should -BeFalse -Because 'there are no component files to enumerate'
        } finally {
            Remove-Item -LiteralPath $bare -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns $null when the manifest itself is absent' {
        Get-CommittedSolution -Path (Join-Path ([IO.Path]::GetTempPath()) 'no-such-solution.xml') |
            Should -BeNullOrEmpty
    }
}
