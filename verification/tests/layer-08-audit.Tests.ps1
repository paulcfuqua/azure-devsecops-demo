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

    # query_aws_lakehouse_sql is in the fixture's allowlist because V8.6's first half reads
    # the SAME /healthz declaration V8.3 compares against: a fixture advertising five tools
    # would make V8.6 legitimately fail for the AWS tool being absent, which is a different
    # test from the ones below.
    $script:AllowedTool = @('query_lakehouse_sql', 'query_aws_lakehouse_sql', 'query_log_analytics',
        'get_github_security', 'get_defender_posture', 'get_cost_series')
    $script:EvalPath = Join-Path -Path $script:ReportRoot -ChildPath 'agent-eval-results.json'
    $script:EnvironmentVariable = @('MLS_POWER_PLATFORM_ENV_URL', 'MLS_DATAVERSE_TOKEN', 'MLS_EVAL_RESULTS',
        'MLS_MCP_SERVER_URL', 'MLS_SQL_ENDPOINT', 'MLS_MCP_AUTH_TOKEN', 'MLS_GLUE_DATABASE')
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

    # Builds the INPUT V8.6/V8.7 interpret: one already-classified result of the shape
    # Invoke-MlsMcpToolCall returns. It deliberately does NOT decide anything the criteria
    # decide - no PASS, no FAIL, no UNOBSERVABLE verdict, no floor comparison. The mapping
    # from an HTTP 401/429/5xx or an isError payload ONTO these outcomes is the module's
    # job and is tested against Invoke-WebRequest in MlsAudit.Tests.ps1, where a fixture
    # that built the outcome directly would be a mirror.
    function New-AwsToolResult {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pure builder: returns an in-memory fixture object and changes no state anywhere.')]
        param(
            [ValidateSet('rows', 'tool-error', 'unobservable')][string]$Outcome = 'rows',
            [object[]]$Row = @(),
            [string]$Text = '',
            [int]$ElapsedMs = 2550
        )
        $payload = $null
        if ($Outcome -eq 'rows') {
            $payload = [pscustomobject]@{ columns = @('n'); rows = @($Row); rowCount = @($Row).Count; truncated = $false }
        }
        return [pscustomobject]@{
            ToolName   = 'query_aws_lakehouse_sql'
            Outcome    = $Outcome
            Reason     = $(if ($Outcome -eq 'unobservable') { $Text } else { '' })
            HttpStatus = $(if ($Outcome -eq 'unobservable') { 401 } else { 200 })
            ElapsedMs  = $ElapsedMs
            ToolError  = $(if ($Outcome -eq 'tool-error') { $Text } else { '' })
            Payload    = $payload
        }
    }

    function Invoke-AuditForTest {
        param(
            [switch]$NoRetry,
            [string]$EnvironmentUrl = 'https://mls.crm.dynamics.com',
            [string]$SolutionPath = $script:SolutionPath,
            [string]$EvalResultPath = $script:EvalPath,
            [string]$McpServerUrl = 'https://mls-mcp-demo-ca.example.io/mcp',
            [string]$SqlEndpoint = 'abc.datawarehouse.fabric.microsoft.com',
            [string]$McpAuthToken = 'mcp-token-for-test',
            [string]$AwsGlueDatabase = 'launch_intel_lakehouse'
        )
        Invoke-Main -EnvironmentUrl $EnvironmentUrl -DataverseToken 'dv-token' -SolutionPath $SolutionPath `
            -EvalResultPath $EvalResultPath -McpServerUrl $McpServerUrl -AllowedTool $script:AllowedTool `
            -AdaptiveCardVersion '1.5' -LatencyBudgetSeconds 20 -EvalPassBar 9 -SqlEndpoint $SqlEndpoint `
            -LakehouseName 'mls_operations' -McpAuthToken $McpAuthToken -AwsGlueDatabase $AwsGlueDatabase `
            -ReportRoot $script:ReportRoot -NoRetry:$NoRetry
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
                Content    = (@{
                        ok        = $true
                        tools     = @($script:AdvertisedTool).Count
                        toolNames = @($script:AdvertisedTool)
                        adapters  = @{ query_aws_lakehouse_sql = 'AthenaLakehouseSqlBackend' }
                    } | ConvertTo-Json -Depth 5)
                Headers    = @{}
                Error      = $null
            }
        }

        Mock Invoke-MlsSqlQuery {
            return @([pscustomobject]@{ weekday = 'Saturday'; launches = 309 })
        }

        # V8.6/V8.7's three probes, answering as the live endpoint did on 2026-09-16:
        # launches 286,473, launches_latest 7,969, and a five-entry Glue catalog. Each test
        # below replaces one of these with a realistic wrong answer.
        $script:AwsBaseResult = New-AwsToolResult -Row @(, @(286473)) -ElapsedMs 4431
        $script:AwsViewResult = New-AwsToolResult -Row @(, @(7969)) -ElapsedMs 2550
        $script:AwsCatalogResult = New-AwsToolResult -Row @(
            @('agencies', 'EXTERNAL_TABLE'), @('agencies_latest', 'VIRTUAL_VIEW'),
            @('launches', 'EXTERNAL_TABLE'), @('launches_latest', 'VIRTUAL_VIEW'),
            @('schedule_events', 'EXTERNAL_TABLE')) -ElapsedMs 2560

        Mock Invoke-MlsMcpToolCall {
            $statement = "$($Argument['sql'])"
            if ($statement -like '*information_schema.tables*') { return $script:AwsCatalogResult }
            if ($statement -like '*launches_latest*') { return $script:AwsViewResult }
            if ($statement -like '*launches*') { return $script:AwsBaseResult }
            throw "unexpected MCP tool call: $statement"
        }

        Mock Invoke-MlsAz { throw "unexpected az call: $($Argument -join ' ')" }
    }

    Context 'all criteria pass' {
        It 'records V8.1-V8.7 as PASS and exits 0' {
            $context = Invoke-AuditForTest
            @($context.Criterion).Id | Should -Be @('V8.1', 'V8.2', 'V8.3', 'V8.4', 'V8.5', 'V8.6', 'V8.7')
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
            @($context.Criterion).Count | Should -Be 7
            (Get-Row -Context $context -Id 'V8.2').Status | Should -Be 'FAIL'
            (Get-Row -Context $context -Id 'V8.2').Observed | Should -BeLike '*capacity is paused*'
            (Get-Row -Context $context -Id 'V8.4').Status | Should -Be 'PASS'
        }
    }

    Context 'missing input - the pre-L8 state, recorded as labelled SKIPs' {
        It 'records every criterion as SKIP when nothing is deployed yet, and never as a pass' {
            $context = Invoke-AuditForTest -EnvironmentUrl '' -EvalResultPath (Join-Path -Path $script:ReportRoot -ChildPath 'absent.json') `
                -McpServerUrl '' -SqlEndpoint '' -McpAuthToken '' -AwsGlueDatabase '' -NoRetry
            @($context.Criterion).Count | Should -Be 7
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

Describe 'V8.6 - the AWS lakehouse answers with ROWS, not with a status code' {
    # The link began working on 2026-09-16 and the evidence was a scratch script that no
    # longer exists. Everything below is what makes a teardown/rebuild mean something: an
    # estate that answers from AWS and has no criterion asserting it is one rebuild from
    # DEMO-READINESS section D's position, plumbing verified and water unverified.
    BeforeEach {
        foreach ($name in $script:EnvironmentVariable) { [Environment]::SetEnvironmentVariable($name, $null) }
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'
        New-EvalArtifact -Passing 10
        $script:DeployedVersion = '1.0.0.7'
        $script:DeployedComponent = @('mls_opsagent', 'Greeting', 'Sign in ', 'mls_opsagent.shared_mcp.abc123')
        $script:UnmanagedLayer = $false
        $script:AdvertisedTool = $script:AllowedTool
        $script:HealthStatus = 200
        Mock Invoke-MlsRest {
            if ($Uri -like '*solutions*') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ uniquename = 'mlsopsagent'; version = $script:DeployedVersion; solutionid = 'sol-1' }) }
            }
            return [pscustomobject]@{ value = @($script:DeployedComponent | ForEach-Object {
                        [pscustomobject]@{ msdyn_name = $_; msdyn_componenttype = 1; msdyn_unmanagedlayer = $script:UnmanagedLayer } }) }
        }
        Mock Invoke-MlsHttp {
            return [pscustomobject]@{
                StatusCode = $script:HealthStatus
                Content    = (@{
                        ok = $true; tools = @($script:AdvertisedTool).Count
                        toolNames = @($script:AdvertisedTool)
                        adapters = @{ query_aws_lakehouse_sql = 'AthenaLakehouseSqlBackend' }
                    } | ConvertTo-Json -Depth 5)
                Headers    = @{}
                Error      = $null
            }
        }
        Mock Invoke-MlsSqlQuery { return @([pscustomobject]@{ weekday = 'Saturday'; launches = 309 }) }
        $script:AwsBaseResult = New-AwsToolResult -Row @(, @(286473)) -ElapsedMs 4431
        $script:AwsViewResult = New-AwsToolResult -Row @(, @(7969)) -ElapsedMs 2550
        $script:AwsCatalogResult = New-AwsToolResult -Row @(
            @('agencies', 'EXTERNAL_TABLE'), @('agencies_latest', 'VIRTUAL_VIEW'),
            @('launches', 'EXTERNAL_TABLE'), @('launches_latest', 'VIRTUAL_VIEW'),
            @('schedule_events', 'EXTERNAL_TABLE')) -ElapsedMs 2560
        Mock Invoke-MlsMcpToolCall {
            $statement = "$($Argument['sql'])"
            if ($statement -like '*information_schema.tables*') { return $script:AwsCatalogResult }
            if ($statement -like '*launches_latest*') { return $script:AwsViewResult }
            if ($statement -like '*launches*') { return $script:AwsBaseResult }
            throw "unexpected MCP tool call: $statement"
        }
        Mock Invoke-MlsAz { throw "unexpected az call: $($Argument -join ' ')" }
    }

    It 'records the observation line for every probe, so the artifact can tell success from silence' {
        # F162: an authenticated scan and a blocked one produced identical reports, and
        # nothing recorded which had happened. One line per probe is what fixed it.
        $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V8.6'
        $row.Status | Should -Be 'PASS'
        $row.Observed | Should -BeLike '*base table launches -> authenticated Athena query -> 1 rows, 4431 ms*'
        $row.Observed | Should -BeLike '*view launches_latest -> authenticated Athena query -> 1 rows, 2550 ms*'
        $row.Observed | Should -BeLike '*count 286473, floor 100000*'
    }

    It 'fails when the counted value falls below the floor' {
        $script:AwsBaseResult = New-AwsToolResult -Row @(, @(3))
        $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V8.6'
        $row.Status | Should -Be 'FAIL'
        $row.Observed | Should -BeLike '*counted 3, below the floor of 100000*'
    }

    It 'fails, and does NOT report unobservable, when the deployed server no longer declares the AWS tool' {
        # The rebuild case, and the only half of this criterion that runs with no credential
        # at all: the six AWS settings not reaching the container leaves a server declaring
        # six tools instead of seven (F122/F124/F125).
        $script:AdvertisedTool = @($script:AllowedTool | Where-Object { $_ -ne 'query_aws_lakehouse_sql' })
        $row = Get-Row -Context (Invoke-AuditForTest -NoRetry -McpAuthToken '') -Id 'V8.6'
        $row.Status | Should -Be 'FAIL'
        $row.Observed | Should -BeLike '*none of them is query_aws_lakehouse_sql*'
        $row.Observed | Should -Not -BeLike 'UNOBSERVABLE*' -Because '/healthz answered and listed what it serves, so this is an observation, not a blind spot'
    }

    It 'reports UNOBSERVABLE, never zero rows, when a probe could not be read' {
        $script:AwsBaseResult = New-AwsToolResult -Outcome 'unobservable' `
            -Text 'tools/call returned HTTP 429 Too Many Requests (retry-after 600)'
        $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V8.6'
        $row.Observed | Should -BeLike 'UNOBSERVABLE*'
        $row.Observed | Should -BeLike '*429*'
        $row.Status | Should -Not -Be 'PASS'
    }

    It 'never reports the link as present when only one of the two probes could be read' {
        # The symmetric error, and the worse one: an auditor that cannot see a control must
        # not be able to report it PRESENT either.
        $script:AwsViewResult = New-AwsToolResult -Outcome 'unobservable' -Text 'no HTTP response at all'
        $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V8.6'
        $row.Status | Should -Not -Be 'PASS'
        $row.Observed | Should -BeLike 'UNOBSERVABLE*'
        $row.Observed | Should -BeLike '*286473*' -Because 'the probe that DID answer is still reported; a run returns everything it saw'
    }

    It 'fails when the VIEW is denied while the base table answers perfectly' {
        # The five-table finding regressing. A role built from the three base-table names
        # answers every base-table question and AccessDenies launches_latest - a partial
        # failure that reads like a data problem, in front of an audience.
        $script:AwsViewResult = New-AwsToolResult -Outcome 'tool-error' `
            -Text 'AccessDenied: User is not authorized to perform: glue:GetTable on resource launches_latest'
        $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V8.6'
        $row.Status | Should -Be 'FAIL'
        $row.Observed | Should -BeLike '*view launches_latest -> DENIED*'
        $row.Observed | Should -BeLike '*glue:GetTable*'
    }

    It 'skips rather than passing when no credential was supplied, and claims nothing about the lakehouse' {
        $row = Get-Row -Context (Invoke-AuditForTest -NoRetry -McpAuthToken '') -Id 'V8.6'
        $row.Status | Should -Be 'SKIP'
        $row.Observed | Should -BeLike '*no credential, so no row was read*'
        $row.Detail | Should -BeLike '*necessary and nowhere near sufficient*'
    }

    It 'reports UNOBSERVABLE when /healthz publishes no tool names at all' {
        $script:AdvertisedTool = @()
        $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V8.6'
        $row.Observed | Should -BeLike 'UNOBSERVABLE*'
        $row.Status | Should -Not -Be 'PASS'
    }
}

Describe 'V8.7 - a denial is never reported as an empty dataset (F105, one cloud over)' {
    BeforeEach {
        foreach ($name in $script:EnvironmentVariable) { [Environment]::SetEnvironmentVariable($name, $null) }
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'
        New-EvalArtifact -Passing 10
        $script:DeployedVersion = '1.0.0.7'
        $script:DeployedComponent = @('mls_opsagent', 'Greeting', 'Sign in ', 'mls_opsagent.shared_mcp.abc123')
        $script:UnmanagedLayer = $false
        $script:AdvertisedTool = $script:AllowedTool
        $script:HealthStatus = 200
        Mock Invoke-MlsRest {
            if ($Uri -like '*solutions*') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ uniquename = 'mlsopsagent'; version = $script:DeployedVersion; solutionid = 'sol-1' }) }
            }
            return [pscustomobject]@{ value = @($script:DeployedComponent | ForEach-Object {
                        [pscustomobject]@{ msdyn_name = $_; msdyn_componenttype = 1; msdyn_unmanagedlayer = $script:UnmanagedLayer } }) }
        }
        Mock Invoke-MlsHttp {
            return [pscustomobject]@{
                StatusCode = $script:HealthStatus
                Content    = (@{
                        ok = $true; tools = @($script:AdvertisedTool).Count
                        toolNames = @($script:AdvertisedTool)
                        adapters = @{ query_aws_lakehouse_sql = 'AthenaLakehouseSqlBackend' }
                    } | ConvertTo-Json -Depth 5)
                Headers    = @{}
                Error      = $null
            }
        }
        Mock Invoke-MlsSqlQuery { return @([pscustomobject]@{ weekday = 'Saturday'; launches = 309 }) }
        $script:AwsBaseResult = New-AwsToolResult -Row @(, @(286473)) -ElapsedMs 4431
        $script:AwsViewResult = New-AwsToolResult -Row @(, @(7969)) -ElapsedMs 2550
        $script:AwsCatalogResult = New-AwsToolResult -Row @(
            @('agencies', 'EXTERNAL_TABLE'), @('agencies_latest', 'VIRTUAL_VIEW'),
            @('launches', 'EXTERNAL_TABLE'), @('launches_latest', 'VIRTUAL_VIEW'),
            @('schedule_events', 'EXTERNAL_TABLE')) -ElapsedMs 2560
        Mock Invoke-MlsMcpToolCall {
            $statement = "$($Argument['sql'])"
            if ($statement -like '*information_schema.tables*') { return $script:AwsCatalogResult }
            if ($statement -like '*launches_latest*') { return $script:AwsViewResult }
            if ($statement -like '*launches*') { return $script:AwsBaseResult }
            throw "unexpected MCP tool call: $statement"
        }
        Mock Invoke-MlsAz { throw "unexpected az call: $($Argument -join ' ')" }
    }

    It 'passes on a non-empty catalog listing that carries the tables V8.6 queries' {
        $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V8.7'
        $row.Status | Should -Be 'PASS'
        $row.Observed | Should -BeLike '*5 rows, 2560 ms*'
        $row.Observed | Should -BeLike '*launches_latest*'
    }

    It 'reports an EMPTY listing as UNOBSERVABLE and never as an empty lakehouse' {
        # THE WHOLE CRITERION. Athena answers a Glue database the role may not read with an
        # empty listing, exactly as Fabric answered /tables with [] while its SQL endpoint
        # held 1,200 rows.
        $script:AwsCatalogResult = New-AwsToolResult -Row @()
        $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V8.7'
        $row.Observed | Should -BeLike 'UNOBSERVABLE*'
        $row.Observed | Should -BeLike '*unprovable*'
        $row.Status | Should -Not -Be 'PASS'
    }

    It 'never reports the catalog as absent when it could not look' {
        $script:AwsCatalogResult = New-AwsToolResult -Outcome 'unobservable' `
            -Text 'tools/call returned HTTP 429 Too Many Requests (retry-after 600): a THROTTLED response is not an empty one'
        $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V8.7'
        $row.Observed | Should -BeLike 'UNOBSERVABLE*'
        $row.Observed | Should -Not -BeLike '*missing*'
        $row.Observed | Should -Not -BeLike '*has no tables*'
    }

    It 'never reports the catalog as present when it could not look' {
        $script:AwsCatalogResult = New-AwsToolResult -Outcome 'unobservable' -Text 'no HTTP response at all'
        (Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V8.7').Status | Should -Not -Be 'PASS'
    }

    It 'reports a refusal AS a refusal, in the words a reader would act on' {
        $script:AwsCatalogResult = New-AwsToolResult -Outcome 'tool-error' `
            -Text 'AccessDeniedException: User is not authorized to perform: glue:GetTables'
        $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V8.7'
        $row.Status | Should -Be 'FAIL'
        $row.Observed | Should -BeLike '*DENIED*'
        $row.Detail | Should -BeLike '*do not read this as "the lakehouse has no tables"*'
    }

    It 'names a genuinely missing table only once the listing proved readable' {
        $script:AwsCatalogResult = New-AwsToolResult -Row @(
            @('agencies', 'EXTERNAL_TABLE'), @('launches', 'EXTERNAL_TABLE'))
        $row = Get-Row -Context (Invoke-AuditForTest -NoRetry) -Id 'V8.7'
        $row.Status | Should -Be 'FAIL'
        # -Match, not -BeLike: [ ] is a wildcard character class, so -BeLike would be
        # asserting something other than the literal the report prints.
        $row.Observed | Should -Match 'missing \[launches_latest\]'
        $row.Detail | Should -BeLike '*OBSERVED MISSING, not unobservable*'
    }

    It 'reports UNOBSERVABLE when the Glue database name could not be resolved' {
        Mock Invoke-MlsAz { return '' }
        $row = Get-Row -Context (Invoke-AuditForTest -NoRetry -AwsGlueDatabase '') -Id 'V8.7'
        $row.Observed | Should -BeLike 'UNOBSERVABLE*'
        $row.Status | Should -Not -Be 'PASS'
    }

    It 'skips, claiming nothing at all, when no credential was supplied' {
        $row = Get-Row -Context (Invoke-AuditForTest -NoRetry -McpAuthToken '') -Id 'V8.7'
        $row.Status | Should -Be 'SKIP'
        $row.Observed | Should -BeLike '*NOT probed*'
        $row.Detail | Should -BeLike '*not that it is empty*'
    }
}

Describe 'V8.6 and V8.7 declare their own wait windows rather than inheriting one' {
    # Nineteen of forty-seven criteria once inherited a window nobody chose for them,
    # including one whose answer was settled the moment the deploy step returned. Patience
    # is opted into: V8.6 waits on a Container Apps cold start plus Athena's submit-poll-
    # retrieve cycle, and V8.7 waits on catalog metadata only, on a container V8.6 has
    # already woken - so the two numbers differ from each other and from the default.
    BeforeEach {
        foreach ($name in $script:EnvironmentVariable) { [Environment]::SetEnvironmentVariable($name, $null) }
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'
        New-EvalArtifact -Passing 10
        $script:DeployedVersion = '1.0.0.7'
        $script:DeployedComponent = @('mls_opsagent', 'Greeting', 'Sign in ', 'mls_opsagent.shared_mcp.abc123')
        $script:UnmanagedLayer = $false
        $script:AdvertisedTool = $script:AllowedTool
        $script:HealthStatus = 200
        Mock Invoke-MlsRest {
            if ($Uri -like '*solutions*') {
                return [pscustomobject]@{ value = @([pscustomobject]@{ uniquename = 'mlsopsagent'; version = $script:DeployedVersion; solutionid = 'sol-1' }) }
            }
            return [pscustomobject]@{ value = @($script:DeployedComponent | ForEach-Object {
                        [pscustomobject]@{ msdyn_name = $_; msdyn_componenttype = 1; msdyn_unmanagedlayer = $script:UnmanagedLayer } }) }
        }
        Mock Invoke-MlsHttp {
            return [pscustomobject]@{
                StatusCode = 200
                Content    = (@{ ok = $true; tools = 6; toolNames = @($script:AdvertisedTool)
                        adapters = @{ query_aws_lakehouse_sql = 'AthenaLakehouseSqlBackend' } } | ConvertTo-Json -Depth 5)
                Headers    = @{}
                Error      = $null
            }
        }
        Mock Invoke-MlsSqlQuery { return @([pscustomobject]@{ weekday = 'Saturday'; launches = 309 }) }
        $script:AwsBaseResult = New-AwsToolResult -Row @(, @(286473))
        $script:AwsViewResult = New-AwsToolResult -Row @(, @(7969))
        $script:AwsCatalogResult = New-AwsToolResult -Row @(
            @('launches', 'EXTERNAL_TABLE'), @('launches_latest', 'VIRTUAL_VIEW'))
        Mock Invoke-MlsMcpToolCall {
            $statement = "$($Argument['sql'])"
            if ($statement -like '*information_schema.tables*') { return $script:AwsCatalogResult }
            if ($statement -like '*launches_latest*') { return $script:AwsViewResult }
            return $script:AwsBaseResult
        }
        Mock Invoke-MlsAz { throw "unexpected az call: $($Argument -join ' ')" }
    }

    It 'gives each criterion a window it chose, shorter than the one it would have inherited' {
        $context = Invoke-AuditForTest -NoRetry
        # V8.4 takes the context default; the comparison is against THAT rather than a
        # literal, so changing the default cannot silently make this assertion vacuous.
        $inherited = (Get-Row -Context $context -Id 'V8.4').RetryWindowMinutes
        $rows = (Get-Row -Context $context -Id 'V8.6').RetryWindowMinutes
        $catalog = (Get-Row -Context $context -Id 'V8.7').RetryWindowMinutes
        $rows | Should -Be 4
        $catalog | Should -Be 2
        $rows | Should -Not -Be $inherited
        $catalog | Should -BeLessThan $rows -Because 'the catalog probe reads metadata with no S3 scan, on a container V8.6 already woke'
        $rows | Should -BeLessThan 120 -Because 'nothing here waits on Entra or policy propagation'
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

Describe "V8.3's -AllowedTool default stays in step with ALLOWED_TOOL_NAMES (F145's shape, again)" {
    # ALLOWED_TOOL_NAMES in apps/mcp-tools/src/tools/index.ts is the one source of truth for
    # which tools the server may ever advertise (its own load-time guard enforces that against
    # the definitions it builds). This script's -AllowedTool default is a SEPARATE,
    # hand-maintained PowerShell copy of that same list, because the Verifier runs no
    # TypeScript and cannot import it directly. A tool added to one list and not the other is
    # exactly F145's shape: a criterion whose expected set silently stopped meaning what a
    # reader assumes it means -- V8.1's component list and V8.3's filtered subset drifted apart
    # once before with nothing about the second list edited to show for it. This is the test
    # that closes that path for THIS pair of lists: add an eighth tool to ALLOWED_TOOL_NAMES
    # without touching this script's default (or the reverse), and it fails.
    BeforeAll {
        $script:F145Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:ToolsIndexPath = Join-Path $script:F145Root 'apps/mcp-tools/src/tools/index.ts'
        $script:AuditScriptPath = Join-Path $script:F145Root 'verification/layer-08-audit.ps1'
    }

    It 'names exactly the same tools as ALLOWED_TOOL_NAMES, as a set' {
        $tsSource = Get-Content -LiteralPath $script:ToolsIndexPath -Raw
        $tsMatch = [regex]::Match($tsSource, 'export const ALLOWED_TOOL_NAMES = \[([\s\S]*?)\]')
        $tsMatch.Success | Should -BeTrue -Because 'ALLOWED_TOOL_NAMES must exist verbatim in tools/index.ts'
        $tsNames = @([regex]::Matches($tsMatch.Groups[1].Value, '"([a-z_]+)"') |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        # A regex that matched nothing is not the same fact as "the two lists agree" -- an
        # empty expected set would pass every subset check below vacuously.
        $tsNames.Count | Should -BeGreaterThan 0 -Because 'ALLOWED_TOOL_NAMES must contain at least one quoted name'

        # [string[]]$AllowedTool appears TWICE in this script: the top-level param block
        # (real names, matched first) and Invoke-Main's own pass-through parameter (default
        # @(), empty). [regex]::Match returns the first match, which is the top-level one.
        $psSource = Get-Content -LiteralPath $script:AuditScriptPath -Raw
        $psMatch = [regex]::Match($psSource, '\[string\[\]\]\$AllowedTool = @\(\s*([\s\S]*?)\)')
        $psMatch.Success | Should -BeTrue -Because 'layer-08-audit.ps1 must declare a non-empty -AllowedTool default'
        $psNames = @([regex]::Matches($psMatch.Groups[1].Value, "'([a-z_]+)'") |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $psNames.Count | Should -BeGreaterThan 0 -Because '-AllowedTool''s default must contain at least one quoted name'

        $missingFromScript = @($tsNames | Where-Object { $_ -notin $psNames })
        $extraInScript = @($psNames | Where-Object { $_ -notin $tsNames })
        $missingFromScript | Should -BeNullOrEmpty -Because 'every name in ALLOWED_TOOL_NAMES must appear in -AllowedTool''s default'
        $extraInScript | Should -BeNullOrEmpty -Because '-AllowedTool''s default must never claim a tool ALLOWED_TOOL_NAMES does not name'
    }
}
