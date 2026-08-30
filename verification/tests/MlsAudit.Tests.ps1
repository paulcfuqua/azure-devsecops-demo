# Pester tests for verification/MlsAudit.psm1 - the criterion runner, retry policy,
# read-only guards and report writer. Every transport is mocked; zero cloud calls.

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'MlsAudit.psm1') -Force
    # No Set-StrictMode -Off: the audit scripts set -Version Latest and CI runs them
    # that way, so the harness must not relax the language mode it is testing (F49).

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-audit-tests-$([guid]::NewGuid().ToString('n'))"

    function New-TestContext {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pure builder: returns an in-memory audit context and changes no state anywhere.')]
        param([int]$Layer = 6, [switch]$NoRetry)
        return New-MlsAuditContext -Layer $Layer -Title 'unit test' -ScriptName 'test.ps1' `
            -ReportRoot $script:ReportRoot -NoRetry:$NoRetry
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:ReportRoot) {
        Remove-Item -LiteralPath $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Module 'MlsAudit' -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-MlsCriterion' {
    BeforeEach {
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'
    }

    It 'records the id, criterion text, command, expected and observed on a pass' {
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V6.1' -Description 'ARM state matches manifest' `
            -Command 'az sql db show --ids <dbId>' -Expected 'autoPauseDelay == 60' -Test {
            New-MlsCheckResult -Passed $true -Observed 'autoPauseDelay=60 minCapacity=0.5'
        }
        $row.Id | Should -Be 'V6.1'
        $row.Status | Should -Be 'PASS'
        $row.Command | Should -Be 'az sql db show --ids <dbId>'
        $row.Expected | Should -Be 'autoPauseDelay == 60'
        $row.Observed | Should -Be 'autoPauseDelay=60 minCapacity=0.5'
        @($context.Criterion).Count | Should -Be 1
    }

    It 'does not sleep at all when the first attempt passes' {
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V6.2' -Description 'passes immediately' `
            -Command 'az monitor log-analytics query' -Expected 'ok' -Test { New-MlsCheckResult -Passed $true -Observed 'ok' }
        $row.Attempt | Should -Be 1
        $row.SleptSeconds | Should -Be 0
        Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 0
    }

    It 'retries then succeeds without sleeping the full propagation window' {
        $context = New-TestContext
        $script:Attempt = 0
        $row = Invoke-MlsCriterion -Context $context -Id 'V6.2' -Description 'propagation lag then success' `
            -Command 'az monitor log-analytics query' -Expected 'a well-formed result' `
            -RetryWindowMinutes 30 -PollIntervalSeconds 300 -Test {
            $script:Attempt++
            if ($script:Attempt -lt 2) { return New-MlsCheckResult -Passed $false -Observed 'RBAC not propagated yet' }
            New-MlsCheckResult -Passed $true -Observed 'query succeeded as the Verifier identity'
        }
        $row.Status | Should -Be 'PASS'
        $row.Attempt | Should -Be 2
        # One poll interval, not the 1800-second window.
        $row.SleptSeconds | Should -Be 300
        $row.SleptSeconds | Should -BeLessThan (30 * 60)
        Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 1
    }

    It 'stops retrying at the window and reports FAIL' {
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V6.4' -Description 'never pauses' `
            -Command 'az sql db show --query status' -Expected 'Paused' `
            -RetryWindowMinutes 10 -PollIntervalSeconds 300 -Test {
            New-MlsCheckResult -Passed $false -Observed "status = 'Online', expected 'Paused'"
        }
        $row.Status | Should -Be 'FAIL'
        $row.Attempt | Should -BeGreaterThan 1
        $row.SleptSeconds | Should -BeLessOrEqual (10 * 60)
    }

    It 'turns a thrown check into a FAIL row and keeps running the rest' {
        $context = New-TestContext
        $first = Invoke-MlsCriterion -Context $context -Id 'V6.1' -Description 'throws' `
            -Command 'az resource show' -Expected 'ok' -NoRetry -Test { throw 'az exited with code 3' }
        $second = Invoke-MlsCriterion -Context $context -Id 'V6.2' -Description 'still runs' `
            -Command 'az monitor log-analytics query' -Expected 'ok' -Test { New-MlsCheckResult -Passed $true -Observed 'ok' }
        $first.Status | Should -Be 'FAIL'
        $first.Observed | Should -BeLike '*az exited with code 3*'
        $second.Status | Should -Be 'PASS'
        @($context.Criterion).Count | Should -Be 2
    }

    It 'never retries a -Final failure (a wrong value is not a propagation artifact)' {
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V3.3' -Description 'CA policy enforced' `
            -Command 'GET /v1.0/identity/conditionalAccess/policies' -Expected 'enabledForReportingButNotEnforced' `
            -RetryWindowMinutes 30 -Test {
            New-MlsCheckResult -Passed $false -Observed 'mls-ca-require-mfa-admins=enabled' -Final
        }
        $row.Status | Should -Be 'FAIL'
        $row.Attempt | Should -Be 1
        Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 0
    }

    It 'records SKIP without retrying and without failing the run' {
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V8.1' -Description 'agent not deployed' `
            -Command 'GET <envUrl>/api/data/v9.2/solutions' -Expected 'solution matches' -Test {
            New-MlsCheckResult -Status 'SKIP' -Observed 'no Power Platform environment' -Detail 'Copilot Studio is cloud-only.'
        }
        $row.Status | Should -Be 'SKIP'
        $row.Attempt | Should -Be 1
        Get-MlsExitCode -Context $context | Should -Be 0
        Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 0
    }

    It 'records PENDING while a declared 24 h window is still open, and FAIL once it has passed' {
        $context = New-TestContext
        $open = Invoke-MlsCriterion -Context $context -Id 'V6.3' -Description 'cost export' `
            -Command 'az storage blob list' -Expected '>= 1 blob' `
            -RetryWindowMinutes 1440 -InProcessWaitMinutes 0 -WindowStartUtc ([datetime]::UtcNow.AddHours(-1)) -PendingWhenUnexpired `
            -Test { New-MlsCheckResult -Passed $false -Observed '0 blobs' }
        $expired = Invoke-MlsCriterion -Context $context -Id 'V6.3' -Description 'cost export' `
            -Command 'az storage blob list' -Expected '>= 1 blob' `
            -RetryWindowMinutes 1440 -InProcessWaitMinutes 0 -WindowStartUtc ([datetime]::UtcNow.AddHours(-48)) -PendingWhenUnexpired `
            -Test { New-MlsCheckResult -Passed $false -Observed '0 blobs' }
        $open.Status | Should -Be 'PENDING'
        $open.Detail | Should -BeLike '*deadline*'
        $expired.Status | Should -Be 'FAIL'
    }

    It 'fails a check that returns something other than a check result' {
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V1.1' -Description 'bad check' `
            -Command 'gh run list' -Expected 'success' -Test { }
        $row.Status | Should -Be 'FAIL'
        $row.Observed | Should -BeLike '*returned nothing*'
    }

    It 'rejects an id that is not a playbook anchor' {
        $context = New-TestContext
        { Invoke-MlsCriterion -Context $context -Id 'not-an-anchor' -Description 'x' -Command 'y' -Expected 'z' -Test { } } |
            Should -Throw
    }

    It '-Control is optional: a call that omits it still produces a valid row with an empty mapping' {
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V6.1' -Description 'no control decision supplied' `
            -Command 'az resource show' -Expected 'ok' -Test { New-MlsCheckResult -Passed $true -Observed 'ok' }
        $row.Status | Should -Be 'PASS'
        $row.PSObject.Properties.Name | Should -Contain 'Control'
        @($row.Control).Count | Should -Be 0
    }

    It 'carries a supplied -Control mapping onto the row unchanged' {
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V3.3' -Control @('3.5.3') -Description 'CA policy state' `
            -Command 'GET /v1.0/identity/conditionalAccess/policies' -Expected 'ok' `
            -Test { New-MlsCheckResult -Passed $true -Observed 'ok' }
        $row.Control | Should -Be @('3.5.3')
    }

    It 'rejects a -Control id absent from the NIST SP 800-171 catalog, naming the offending id' {
        $context = New-TestContext
        { Invoke-MlsCriterion -Context $context -Id 'V3.3' -Control @('9.9.9') -Description 'x' `
                -Command 'y' -Expected 'z' -Test { New-MlsCheckResult -Passed $true -Observed 'o' } } |
            Should -Throw '*9.9.9*'
    }
}

Describe 'a permission failure is never a propagation failure' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' 'MlsAudit.psm1') -Force
    }

    # L2's audit ran for exactly sixty minutes and was killed by the job timeout. It was not
    # slow: mls-verifier has no role assignment at the mls management group, so every
    # criterion reading MG state threw AuthorizationFailed - and the retry loop treated that
    # as propagation lag and waited out the whole window on each one.
    #
    # "Not yet" and "never" are different answers. Retrying a permission error cannot make it
    # succeed; it only converts an actionable FAIL into a timeout with no report at all,
    # which is the worst of both (F57).

    It 'fails immediately on <Signature>, without retrying' -ForEach @(
        @{ Signature = 'AuthorizationFailed'; Message = "(AuthorizationFailed) The client 'x' does not have authorization to perform action 'Microsoft.Authorization/policyAssignments/read'" }
        @{ Signature = 'Forbidden';           Message = 'Response status code does not indicate success: 403 (Forbidden).' }
        @{ Signature = 'Authorization_RequestDenied'; Message = 'Authorization_RequestDenied: Insufficient privileges to complete the operation.' }
    ) {
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'
        $context = New-MlsAuditContext -Layer 2 -Title 't' -ScriptName 's' -ReportRoot $TestDrive
        $message = $Message
        Invoke-MlsCriterion -Context $context -Id 'V2.1' -Control @('3.4.2') `
            -Description 'd' -Command 'c' -Expected 'e' `
            -Test { throw $message } | Out-Null
        $row = @($context.Criterion)[0]
        $row.Status | Should -Be 'FAIL'
        $row.Observed | Should -BeLike '*check threw*'
        Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Times 0 `
            -Because 'a permission error cannot become permitted by waiting'
    }

    It 'still retries a genuine propagation failure' {
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'
        $context = New-MlsAuditContext -Layer 2 -Title 't' -ScriptName 's' -ReportRoot $TestDrive
        Invoke-MlsCriterion -Context $context -Id 'V2.1' -Control @('3.4.2') `
            -Description 'd' -Command 'c' -Expected 'e' `
            -Test { throw 'ResourceNotFound: the assignment has not appeared yet' } | Out-Null
        Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Times 1 -Scope It `
            -Because 'a missing object may still be propagating'
    }
}

Describe 'Wait-MlsRetryInterval' {
    It 'sleeps in short slices so the wait stays interruptible' {
        Mock Start-Sleep {} -ModuleName 'MlsAudit'
        Wait-MlsRetryInterval -Seconds 12
        Should -Invoke Start-Sleep -ModuleName 'MlsAudit' -Exactly -Times 3
    }
}

Describe 'Write-MlsReport' {
    BeforeEach {
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'
        $script:Context = New-TestContext
        Add-MlsPreflight -Context $script:Context -Name 'SubscriptionId' -Value '0000-sub'
        Add-MlsNote -Context $script:Context -Message 'tools-only fallback path recorded'
        Invoke-MlsCriterion -Context $script:Context -Id 'V6.1' -Description 'ARM state matches manifest' `
            -Command 'az sql db show --ids <dbId>' -Expected 'autoPauseDelay == 60' `
            -Test { New-MlsCheckResult -Passed $true -Observed 'autoPauseDelay=60' } | Out-Null
        Invoke-MlsCriterion -Context $script:Context -Id 'V6.4' -Description 'SQL auto-pauses' -NoRetry `
            -Command 'az sql db show --query status' -Expected 'Paused' `
            -Test { New-MlsCheckResult -Passed $false -Observed "status = 'Online'" } | Out-Null
        Invoke-MlsCriterion -Context $script:Context -Id 'V6.3' -Description 'cost export' -NoRetry `
            -Command 'az storage blob list' -Expected '>= 1 blob' `
            -Test { New-MlsCheckResult -Status 'SKIP' -Observed 'no storage account configured' } | Out-Null
    }

    It 'writes L<NN>-<timestamp>.md and a machine-readable JSON sibling' {
        $report = Write-MlsReport -Context $script:Context -Timestamp '20260824-120000Z'
        $report.MarkdownPath | Should -Match 'L06-20260824-120000Z\.md$'
        $report.JsonPath | Should -Match 'L06-20260824-120000Z\.json$'
        Test-Path -LiteralPath $report.MarkdownPath | Should -BeTrue
        Test-Path -LiteralPath $report.JsonPath | Should -BeTrue
    }

    It 'carries every criterion id, status, command, expected and observed into the Markdown' {
        $report = Write-MlsReport -Context $script:Context -Timestamp '20260824-120001Z'
        $markdown = Get-Content -LiteralPath $report.MarkdownPath -Raw
        $markdown | Should -BeLike '*V6.1*'
        $markdown | Should -BeLike '*V6.4*'
        $markdown | Should -BeLike '*az sql db show --ids <dbId>*'
        $markdown | Should -BeLike '*autoPauseDelay=60*'
        $markdown | Should -BeLike "*status = 'Online'*"
        $markdown | Should -BeLike '*SubscriptionId*'
        $markdown | Should -BeLike '*tools-only fallback path recorded*'
        $markdown | Should -BeLike '*read-only*'
    }

    It 'reports the counts and the overall result' {
        $report = Write-MlsReport -Context $script:Context -Timestamp '20260824-120002Z'
        $report.Result | Should -Be 'FAIL'
        $report.Counts.Total | Should -Be 3
        $report.Counts.Pass | Should -Be 1
        $report.Counts.Fail | Should -Be 1
        $report.Counts.Skip | Should -Be 1
        $document = Get-Content -LiteralPath $report.JsonPath -Raw | ConvertFrom-Json
        $document.layerId | Should -Be 'L06'
        $document.result | Should -Be 'FAIL'
        @($document.criteria).Count | Should -Be 3
        @($document.criteria | Where-Object { $_.Id -eq 'V6.4' })[0].Status | Should -Be 'FAIL'
    }

    It 'creates the report directory when it does not exist' {
        $fresh = Join-Path -Path $script:ReportRoot -ChildPath 'nested-does-not-exist'
        $report = Write-MlsReport -Context $script:Context -ReportRoot $fresh -Timestamp '20260824-120003Z'
        Test-Path -LiteralPath $report.MarkdownPath | Should -BeTrue
    }

    It 'carries each criterion''s Control mapping into both the Markdown and the JSON sibling' {
        $context = New-TestContext
        Invoke-MlsCriterion -Context $context -Id 'V6.1' -Control @('3.4.1') -Description 'baseline config' `
            -Command 'az sql db show' -Expected 'ok' -Test { New-MlsCheckResult -Passed $true -Observed 'ok' } | Out-Null
        Invoke-MlsCriterion -Context $context -Id 'V6.4' -Control @() -Description 'no mapping' -NoRetry `
            -Command 'az sql db show' -Expected 'ok' -Test { New-MlsCheckResult -Passed $true -Observed 'ok' } | Out-Null
        $report = Write-MlsReport -Context $context -Timestamp '20260824-120004Z'
        $markdown = Get-Content -LiteralPath $report.MarkdownPath -Raw
        $markdown | Should -BeLike '*3.4.1*'
        $markdown | Should -BeLike '*none - this criterion asserts no 800-171 requirement*'
        $document = Get-Content -LiteralPath $report.JsonPath -Raw | ConvertFrom-Json
        $mapped = @($document.criteria | Where-Object { $_.Id -eq 'V6.1' })[0]
        $unmapped = @($document.criteria | Where-Object { $_.Id -eq 'V6.4' })[0]
        @($mapped.Control) | Should -Be @('3.4.1')
        @($unmapped.Control).Count | Should -Be 0
    }
}

Describe 'Get-MlsExitCode' {
    BeforeEach {
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'
    }

    It 'is 0 when every criterion passes' {
        $context = New-TestContext
        Invoke-MlsCriterion -Context $context -Id 'V2.1' -Description 'x' -Command 'az' -Expected 'y' `
            -Test { New-MlsCheckResult -Passed $true -Observed 'ok' } | Out-Null
        Get-MlsExitCode -Context $context | Should -Be 0
    }

    It 'is 1 when any criterion FAILs' {
        $context = New-TestContext
        Invoke-MlsCriterion -Context $context -Id 'V2.1' -Description 'x' -Command 'az' -Expected 'y' -NoRetry `
            -Test { New-MlsCheckResult -Passed $true -Observed 'ok' } | Out-Null
        Invoke-MlsCriterion -Context $context -Id 'V2.2' -Description 'x' -Command 'az' -Expected 'y' -NoRetry `
            -Test { New-MlsCheckResult -Passed $false -Observed 'nope' } | Out-Null
        Get-MlsExitCode -Context $context | Should -Be 1
        Get-MlsFailCount -Context $context | Should -Be 1
    }

    It 'is 0 when criteria are SKIP or PENDING but none FAIL' {
        $context = New-TestContext
        Invoke-MlsCriterion -Context $context -Id 'V8.2' -Description 'x' -Command 'gh' -Expected 'y' -NoRetry `
            -Test { New-MlsCheckResult -Status 'SKIP' -Observed 'no agent yet' } | Out-Null
        Invoke-MlsCriterion -Context $context -Id 'V6.3' -Description 'x' -Command 'az' -Expected 'y' `
            -RetryWindowMinutes 1440 -InProcessWaitMinutes 0 -WindowStartUtc ([datetime]::UtcNow) -PendingWhenUnexpired `
            -Test { New-MlsCheckResult -Passed $false -Observed 'not yet' } | Out-Null
        Get-MlsExitCode -Context $context | Should -Be 0
    }
}

Describe 'read-only guards' {
    It 'permits the read verbs the playbooks use' {
        { Assert-MlsReadOnlyAzArgument -Argument @('group', 'exists', '--name', 'mls-rg-canary-untagged') } | Should -Not -Throw
        { Assert-MlsReadOnlyAzArgument -Argument @('policy', 'state', 'summarize', '--subscription', 's') } | Should -Not -Throw
        { Assert-MlsReadOnlyAzArgument -Argument @('monitor', 'log-analytics', 'query', '--workspace', 'w') } | Should -Not -Throw
        { Assert-MlsReadOnlyAzArgument -Argument @('containerapp', 'replica', 'list', '-g', 'rg', '-n', 'app') } | Should -Not -Throw
        { Assert-MlsReadOnlyAzArgument -Argument @('rest', '--method', 'get', '--url', 'https://graph.microsoft.com/v1.0/users') } | Should -Not -Throw
    }

    It 'refuses every mutating az call, including the L2 canary write the deploy workflow owns' {
        { Assert-MlsReadOnlyAzArgument -Argument @('group', 'create', '--name', 'mls-rg-canary-untagged', '--location', 'eastus') } |
            Should -Throw '*not read-only*'
        { Assert-MlsReadOnlyAzArgument -Argument @('group', 'delete', '--name', 'mls-rg-apps', '--yes') } | Should -Throw '*not read-only*'
        { Assert-MlsReadOnlyAzArgument -Argument @('security', 'pricing', 'update', '--name', 'Containers') } | Should -Throw '*not read-only*'
        { Assert-MlsReadOnlyAzArgument -Argument @('rest', '--method', 'post', '--url', 'https://management.azure.com/x') } |
            Should -Throw '*Refusing mutating az rest call*'
    }

    It 'refuses every mutating gh call and permits the read set' {
        { Assert-MlsReadOnlyGhArgument -Argument @('api', 'repos/o/r') } | Should -Not -Throw
        { Assert-MlsReadOnlyGhArgument -Argument @('run', 'list', '--workflow', 'infra-up.yml') } | Should -Not -Throw
        { Assert-MlsReadOnlyGhArgument -Argument @('release', 'download', 'v1', '-p', '*.spdx.json') } | Should -Not -Throw
        { Assert-MlsReadOnlyGhArgument -Argument @('workflow', 'run', 'infra-up.yml') } | Should -Throw '*read-only command set*'
        { Assert-MlsReadOnlyGhArgument -Argument @('pr', 'merge', '31') } | Should -Throw '*read-only command set*'
        { Assert-MlsReadOnlyGhArgument -Argument @('api', '-X', 'PATCH', 'repos/o/r') } | Should -Throw '*Refusing mutating gh api call*'
    }

    It 'allows only GET through the REST and Graph wrappers' {
        { Invoke-MlsRest -Uri 'https://api.fabric.microsoft.com/v1/workspaces' -Method 'POST' } | Should -Throw
        { Invoke-MlsGraph -Uri 'https://graph.microsoft.com/v1.0/users' -Method 'DELETE' } | Should -Throw
    }

    It 'allows only MCP read methods, never tools/call' {
        { Invoke-MlsMcpToolCatalog -Uri 'https://mcp.example/mcp' -Method 'tools/call' } | Should -Throw '*Refusing MCP method*'
    }

    It 'refuses a non-SELECT statement on the lakehouse endpoint' {
        { Invoke-MlsSqlQuery -ServerName 's' -DatabaseName 'd' -Query 'DROP TABLE launches' } | Should -Throw '*only reads*'
    }

    It 'refuses a git subcommand that is not a read' {
        { Invoke-MlsGit -Argument @('push', 'origin', 'main') } | Should -Throw '*only reads*'
    }

    It 'names the missing tool instead of surfacing a CommandNotFoundException' {
        { Assert-MlsCommand -Name 'mls-not-a-real-command' -Hint 'Install it first.' } |
            Should -Throw '*is not available on this machine*'
    }
}

Describe 'transport wrappers' {
    It 'Invoke-MlsRest issues one GET through Invoke-RestMethod' {
        Mock Invoke-RestMethod { [pscustomobject]@{ value = @(@{ id = 'w1'; displayName = 'mls-operations' }) } } -ModuleName 'MlsAudit'
        $response = Invoke-MlsRest -Uri 'https://api.fabric.microsoft.com/v1/workspaces' -Header @{ Authorization = 'Bearer x' }
        $response.value[0].displayName | Should -Be 'mls-operations'
        Should -Invoke Invoke-RestMethod -ModuleName 'MlsAudit' -Exactly -Times 1 -ParameterFilter { $Method -eq 'GET' }
    }

    It 'Invoke-MlsMcpToolCatalog posts a JSON-RPC tools/list and nothing else' {
        Mock Invoke-RestMethod { [pscustomobject]@{ result = [pscustomobject]@{ tools = @(@{ name = 'query_lakehouse_sql' }) } } } -ModuleName 'MlsAudit'
        $catalog = Invoke-MlsMcpToolCatalog -Uri 'https://mcp.example/mcp'
        $catalog.result.tools[0].name | Should -Be 'query_lakehouse_sql'
        Should -Invoke Invoke-RestMethod -ModuleName 'MlsAudit' -Exactly -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $Body -like '*tools/list*'
        }
    }

    It 'Invoke-MlsGraph falls back to az rest when the Graph SDK is absent' {
        # Invoke-MlsGraph decides by probing `Get-Command Invoke-MgGraphRequest`,
        # so absence must be simulated at that probe. Deleting
        # function:global:Invoke-MgGraphRequest does NOT work: on a host where
        # Microsoft.Graph.Authentication is installed the real cmdlet is still
        # discoverable, the SDK branch is taken, and the test calls Graph for
        # real (it fails with "Authentication needed"). That made the result
        # depend on whether the module happened to be installed, and it put a
        # live call one auth token away from happening in a suite that must
        # make none. Mocking the probe itself is host-independent.
        Mock Get-Command { $null } -ModuleName 'MlsAudit' -ParameterFilter {
            $Name -eq 'Invoke-MgGraphRequest'
        }
        Mock Invoke-MlsAz { [pscustomobject]@{ value = @(@{ id = 'app-2' }) } } -ModuleName 'MlsAudit'
        $response = Invoke-MlsGraph -Uri 'https://graph.microsoft.com/v1.0/applications'
        $response.value[0].id | Should -Be 'app-2'
        Should -Invoke Invoke-MlsAz -ModuleName 'MlsAudit' -Exactly -Times 1 -ParameterFilter {
            $Argument -contains 'rest' -and $Argument -contains 'get'
        }
    }

    # These three replace a single test that asserted "the SDK is PRESENT, so use it". That
    # was the defect written down as a contract: the CI runner has the Graph module installed
    # and never calls Connect-MgGraph, so every Graph criterion threw "Authentication needed"
    # while the working az fallback sat unreachable beneath it (F64).

    function global:Invoke-MgGraphRequest {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stub for the Graph SDK cmdlet: its parameters exist so Invoke-MlsGraph binds against them and Should -Invoke -ParameterFilter can inspect them. The body is intentionally empty - the Pester mock supplies the behaviour.')]
        param($Method, $Uri, $OutputType)
    }
    function global:Get-MgContext { }

    It 'Invoke-MlsGraph uses the Graph SDK when it is present AND signed in' {
        try {
            Mock Get-MgContext { [pscustomobject]@{ ClientId = 'verifier-app-id' } } -ModuleName 'MlsAudit'
            Mock Invoke-MgGraphRequest { [pscustomobject]@{ value = @(@{ id = 'app-1' }) } } -ModuleName 'MlsAudit'
            Mock Invoke-MlsAz { throw 'must not fall back to az when the SDK is present and connected' } -ModuleName 'MlsAudit'
            $response = Invoke-MlsGraph -Uri 'https://graph.microsoft.com/v1.0/applications'
            $response.value[0].id | Should -Be 'app-1'
            Should -Invoke Invoke-MgGraphRequest -ModuleName 'MlsAudit' -Exactly -Times 1 -ParameterFilter { $Method -eq 'GET' }
        }
        finally {
            Remove-Item -LiteralPath 'function:global:Invoke-MgGraphRequest' -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath 'function:global:Get-MgContext' -ErrorAction SilentlyContinue
        }
    }

    It 'falls back to az rest when the SDK is installed but nobody signed in' {
        # Exactly the runner's state. This is the case that produced V1.4's failure.
        function global:Invoke-MgGraphRequest {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stub for the Graph SDK cmdlet; the Pester mock supplies the behaviour. The parameters exist only so Invoke-MlsGraph binds against them.')]
            param($Method, $Uri, $OutputType)
        }
        function global:Get-MgContext { }
        try {
            Mock Get-MgContext { $null } -ModuleName 'MlsAudit'
            Mock Invoke-MgGraphRequest { throw 'Authentication needed. Please call Connect-MgGraph.' } -ModuleName 'MlsAudit'
            Mock Invoke-MlsAz { [pscustomobject]@{ value = @(@{ id = 'app-from-az' }) } } -ModuleName 'MlsAudit'
            $response = Invoke-MlsGraph -Uri 'https://graph.microsoft.com/v1.0/applications'
            $response.value[0].id | Should -Be 'app-from-az'
            Should -Invoke Invoke-MgGraphRequest -ModuleName 'MlsAudit' -Exactly -Times 0 `
                -Because 'an unauthenticated SDK must not be tried at all'
        }
        finally {
            Remove-Item -LiteralPath 'function:global:Invoke-MgGraphRequest' -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath 'function:global:Get-MgContext' -ErrorAction SilentlyContinue
        }
    }

    It 'falls back to az rest when a signed-in SDK call fails anyway' {
        # Two transports are only worth having if one of them working is enough.
        function global:Invoke-MgGraphRequest {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stub for the Graph SDK cmdlet; the Pester mock supplies the behaviour. The parameters exist only so Invoke-MlsGraph binds against them.')]
            param($Method, $Uri, $OutputType)
        }
        function global:Get-MgContext { }
        try {
            Mock Write-MlsStatus { } -ModuleName 'MlsAudit'
            Mock Get-MgContext { [pscustomobject]@{ ClientId = 'verifier-app-id' } } -ModuleName 'MlsAudit'
            Mock Invoke-MgGraphRequest { throw 'token expired' } -ModuleName 'MlsAudit'
            Mock Invoke-MlsAz { [pscustomobject]@{ value = @(@{ id = 'app-from-az' }) } } -ModuleName 'MlsAudit'
            $response = Invoke-MlsGraph -Uri 'https://graph.microsoft.com/v1.0/applications'
            $response.value[0].id | Should -Be 'app-from-az'
        }
        finally {
            Remove-Item -LiteralPath 'function:global:Invoke-MgGraphRequest' -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath 'function:global:Get-MgContext' -ErrorAction SilentlyContinue
        }
    }

    It 'Invoke-MlsChildAudit reports a missing audit script instead of throwing' {
        $run = Invoke-MlsChildAudit -ScriptPath (Join-Path -Path $script:ReportRoot -ChildPath 'layer-99-audit.ps1')
        $run.ExitCode | Should -Be 127
        $run.Output -join ' ' | Should -BeLike '*not found*'
    }
}

Describe 'Invoke-MlsSqlQuery authentication' {
    # The demo's SQL server sets azureADOnlyAuthentication: true and the audits run on a
    # Linux runner, so Invoke-Sqlcmd has no integrated-security path to degrade to: a token
    # is mandatory. This module used to pass -AccessToken $null, which could only ever
    # produce a driver-level "Login failed" that says nothing about the real cause. These
    # tests pin the whole resolution order and the failure message.
    #
    # Invoke-MlsSqlcmd (private) is the seam: mocking it proves WHICH token reaches the
    # driver without a SqlServer module installed anywhere in CI.
    BeforeEach {
        Mock Assert-MlsCommand {} -ModuleName 'MlsAudit'
        Mock Invoke-MlsSqlcmd { @([pscustomobject]@{ t = 'launches'; n = 1200 }) } -ModuleName 'MlsAudit'
        Mock Invoke-MlsAz { [pscustomobject]@{ accessToken = 'minted-token' } } -ModuleName 'MlsAudit'
        Remove-Item -LiteralPath 'env:MLS_SQL_ACCESS_TOKEN' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'env:MLS_VERIFIER_SQL_TOKEN' -ErrorAction SilentlyContinue
    }

    It 'passes an explicitly supplied token to the driver and mints nothing' {
        $rows = @(Invoke-MlsSqlQuery -ServerName 'endpoint.datawarehouse.fabric.microsoft.com' `
                -DatabaseName 'mls_operations' -Query 'SELECT COUNT(*) FROM launches' -AccessToken 'explicit-token')
        $rows[0].n | Should -Be 1200
        Should -Invoke Invoke-MlsSqlcmd -ModuleName 'MlsAudit' -Exactly -Times 1 -ParameterFilter {
            $AccessToken -eq 'explicit-token'
        }
        Should -Invoke Invoke-MlsAz -ModuleName 'MlsAudit' -Exactly -Times 0
    }

    It 'falls back to the environment before minting, exactly like the other module inputs' {
        $env:MLS_SQL_ACCESS_TOKEN = 'env-token'
        try {
            Invoke-MlsSqlQuery -ServerName 's' -DatabaseName 'd' -Query 'SELECT 1' | Out-Null
        }
        finally {
            Remove-Item -LiteralPath 'env:MLS_SQL_ACCESS_TOKEN' -ErrorAction SilentlyContinue
        }
        Should -Invoke Invoke-MlsSqlcmd -ModuleName 'MlsAudit' -Exactly -Times 1 -ParameterFilter {
            $AccessToken -eq 'env-token'
        }
        Should -Invoke Invoke-MlsAz -ModuleName 'MlsAudit' -Exactly -Times 0
    }

    It 'mints a database.windows.net token through the read-only az wrapper when none is supplied' {
        Invoke-MlsSqlQuery -ServerName 's' -DatabaseName 'd' -Query 'WITH x AS (SELECT 1 AS n) SELECT * FROM x' | Out-Null
        Should -Invoke Invoke-MlsAz -ModuleName 'MlsAudit' -Exactly -Times 1 -ParameterFilter {
            $Argument -contains 'get-access-token' -and $Argument -contains 'https://database.windows.net'
        }
        Should -Invoke Invoke-MlsSqlcmd -ModuleName 'MlsAudit' -Exactly -Times 1 -ParameterFilter {
            $AccessToken -eq 'minted-token'
        }
    }

    It 'the minting path stays inside the read-only contract' {
        # get-access-token is in $script:AzReadOnlyVerb, so the guard the rest of the module
        # relies on is not bypassed to authenticate.
        { Assert-MlsReadOnlyAzArgument -Argument @('account', 'get-access-token', '--resource', 'https://database.windows.net') } |
            Should -Not -Throw
    }

    It 'fails with an actionable message naming what to supply when az cannot mint one' {
        Mock Invoke-MlsAz { throw "Please run 'az login' to setup account." } -ModuleName 'MlsAudit'
        { Invoke-MlsSqlQuery -ServerName 's' -DatabaseName 'd' -Query 'SELECT 1' } |
            Should -Throw '*Could not mint an Azure SQL access token*'
        Should -Invoke Invoke-MlsSqlcmd -ModuleName 'MlsAudit' -Exactly -Times 0
    }

    It 'names -AccessToken and the environment variables in that message' {
        Mock Invoke-MlsAz { throw 'no subscription found' } -ModuleName 'MlsAudit'
        $message = ''
        try { Invoke-MlsSqlQuery -ServerName 's' -DatabaseName 'd' -Query 'SELECT 1' }
        catch { $message = $_.Exception.Message }
        $message | Should -BeLike '*-AccessToken*'
        $message | Should -BeLike '*MLS_SQL_ACCESS_TOKEN*'
        $message | Should -BeLike '*Entra-only*'
    }

    It 'never falls through to a null token when az answers without one' {
        Mock Invoke-MlsAz { [pscustomobject]@{ expiresOn = '2026-08-24 12:00:00' } } -ModuleName 'MlsAudit'
        { Invoke-MlsSqlQuery -ServerName 's' -DatabaseName 'd' -Query 'SELECT 1' } |
            Should -Throw '*returned no accessToken*'
        Should -Invoke Invoke-MlsSqlcmd -ModuleName 'MlsAudit' -Exactly -Times 0
    }

    It 'rejects a non-SELECT before it touches a token, a driver or the CLI' {
        { Invoke-MlsSqlQuery -ServerName 's' -DatabaseName 'd' -Query 'DROP TABLE launches' -AccessToken 'explicit-token' } |
            Should -Throw '*only reads*'
        Should -Invoke Assert-MlsCommand -ModuleName 'MlsAudit' -Exactly -Times 0
        Should -Invoke Invoke-MlsAz -ModuleName 'MlsAudit' -Exactly -Times 0
        Should -Invoke Invoke-MlsSqlcmd -ModuleName 'MlsAudit' -Exactly -Times 0
    }
}

Describe 'Resolve-MlsInput' {
    It 'prefers the explicit value, then the environment, then the default' {
        Resolve-MlsInput -Name 'X' -Value 'explicit' -Hint 'h' | Should -Be 'explicit'
        $env:MLS_TEST_INPUT = 'from-env'
        try {
            Resolve-MlsInput -Name 'X' -Value '' -EnvironmentVariable @('MLS_TEST_INPUT') -Hint 'h' | Should -Be 'from-env'
        }
        finally { Remove-Item Env:\MLS_TEST_INPUT -ErrorAction SilentlyContinue }
        Resolve-MlsInput -Name 'X' -Value '' -EnvironmentVariable @('MLS_TEST_ABSENT') -DefaultValue 'fallback' -Hint 'h' |
            Should -Be 'fallback'
    }

    It 'throws an actionable message naming the parameter and every environment variable' {
        { Resolve-MlsInput -Name 'SubscriptionId' -Value '' -EnvironmentVariable @('AZURE_SUBSCRIPTION_ID_ABSENT') `
                -Hint 'The demo subscription the landing zone governs.' } |
            Should -Throw '*-SubscriptionId*'
        { Resolve-MlsInput -Name 'SubscriptionId' -Value '' -EnvironmentVariable @('AZURE_SUBSCRIPTION_ID_ABSENT') `
                -Hint 'The demo subscription the landing zone governs.' } |
            Should -Throw '*AZURE_SUBSCRIPTION_ID_ABSENT*'
    }
}

Describe 'domain helpers' {
    It 'Test-MlsSetEquality reports missing and extra members' {
        $equal = Test-MlsSetEquality -Actual @('a', 'b') -Expected @('b', 'a')
        $equal.Equal | Should -BeTrue
        $drift = Test-MlsSetEquality -Actual @('launches', 'scrubs', 'stray') -Expected @('launches', 'scrubs', 'pads')
        $drift.Equal | Should -BeFalse
        $drift.Missing | Should -Contain 'pads'
        $drift.Extra | Should -Contain 'stray'
    }

    It 'Get-MlsPercentile uses the nearest-rank formula the L8 playbook publishes' {
        Get-MlsPercentile -Value @(1, 2, 3, 4, 5, 6, 7, 8, 9, 10) -Percentile 0.95 | Should -Be 10
        Get-MlsPercentile -Value @(19, 1, 2, 3) -Percentile 0.95 | Should -Be 19
        Get-MlsPercentile -Value @() | Should -BeNullOrEmpty
    }

    It 'Test-MlsAdaptiveCard accepts a pinned 1.5 card and rejects Action.Execute and a wrong version' {
        $good = [pscustomobject]@{
            type    = 'AdaptiveCard'
            version = '1.5'
            body    = @([pscustomobject]@{ type = 'TextBlock'; text = 'Saturday' })
            actions = @([pscustomobject]@{ type = 'Action.Submit'; title = 'Details' })
        }
        (Test-MlsAdaptiveCard -Card $good).Valid | Should -BeTrue

        $execute = [pscustomobject]@{
            type    = 'AdaptiveCard'
            version = '1.5'
            body    = @()
            actions = @([pscustomobject]@{ type = 'Action.Execute'; title = 'Run' })
        }
        $result = Test-MlsAdaptiveCard -Card $execute
        $result.Valid | Should -BeFalse
        $result.Problem -join ' ' | Should -BeLike '*Action.Execute*'

        $wrongVersion = [pscustomobject]@{ type = 'AdaptiveCard'; version = '1.6'; body = @() }
        (Test-MlsAdaptiveCard -Card $wrongVersion).Valid | Should -BeFalse
    }

    It 'Test-MlsGeneratedUi catches HTML/JS/JSX in a response body' {
        Test-MlsGeneratedUi -Text 'Saturday has the most launches (309).' | Should -BeFalse
        Test-MlsGeneratedUi -Text '<div class="chart">309</div>' | Should -BeTrue
        Test-MlsGeneratedUi -Text 'const render = () => (<Chart />)' | Should -BeTrue
    }

    It 'Test-MlsSpdxDocument requires namespace, creation info and a non-empty package list' {
        $valid = [pscustomobject]@{
            spdxVersion       = 'SPDX-2.3'
            SPDXID            = 'SPDXRef-DOCUMENT'
            name              = 'launch-ops'
            documentNamespace = 'https://example/spdx/launch-ops'
            creationInfo      = [pscustomobject]@{ created = '2026-08-24T00:00:00Z' }
            packages          = @([pscustomobject]@{ name = 'react' })
        }
        (Test-MlsSpdxDocument -Document $valid).Valid | Should -BeTrue
        $empty = [pscustomobject]@{
            spdxVersion       = 'SPDX-2.3'
            SPDXID            = 'SPDXRef-DOCUMENT'
            name              = 'launch-ops'
            documentNamespace = 'https://example/spdx/launch-ops'
            creationInfo      = [pscustomobject]@{ created = '2026-08-24T00:00:00Z' }
            packages          = @()
        }
        (Test-MlsSpdxDocument -Document $empty).Valid | Should -BeFalse
    }

    It 'Test-MlsMonotonicTimestamp catches a trail whose stages go backwards' {
        (Test-MlsMonotonicTimestamp -Timestamp @('2026-08-24T10:00:00Z', '2026-08-24T10:05:00Z')).Monotonic | Should -BeTrue
        $backwards = Test-MlsMonotonicTimestamp -Timestamp @('2026-08-24T10:05:00Z', '2026-08-24T10:00:00Z')
        $backwards.Monotonic | Should -BeFalse
        $backwards.Problem | Should -BeLike '*precedes*'
    }
}

Describe 'Get-MlsCollection distinguishes an empty collection from a one-item one' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' 'MlsAudit.psm1') -Force
    }

    It 'returns zero items for an empty <Shape> collection' -ForEach @(
        @{ Shape = 'value';      Response = [pscustomobject]@{ value = @() } }
        @{ Shape = 'data';       Response = [pscustomobject]@{ data = @() } }
        @{ Shape = 'jobs';       Response = [pscustomobject]@{ jobs = @() } }
        @{ Shape = 'check_runs'; Response = [pscustomobject]@{ check_runs = @() } }
        @{ Shape = 'hashtable';  Response = @{ value = @() } }
    ) {
        # An empty collection used to fall through to `return @($Response)` and report
        # Count = 1 - the wrapper object itself - because PowerShell unrolls @() to
        # $null on return, making an empty key indistinguishable from an absent one.
        # Every audit that counts a filtered Graph or gh response then read an ABSENT
        # object as PRESENT. The Verifier failing toward passing is the worst
        # direction available to it.
        @(Get-MlsCollection -Response $Response).Count | Should -Be 0
    }

    It 'still returns the items of a populated collection' {
        $response = [pscustomobject]@{ value = @(
                [pscustomobject]@{ id = 'a' }
                [pscustomobject]@{ id = 'b' }
            ) }
        $items = @(Get-MlsCollection -Response $response)
        $items.Count | Should -Be 2
        $items[0].id | Should -Be 'a'
    }

    It 'still wraps a bare object that carries no collection key' {
        $items = @(Get-MlsCollection -Response ([pscustomobject]@{ id = 'solo' }))
        $items.Count | Should -Be 1
        $items[0].id | Should -Be 'solo'
    }

    It 'returns zero items for a null response' {
        @(Get-MlsCollection -Response $null).Count | Should -Be 0
    }

    It 'an empty collection is not mistaken for a one-item one' {
        # The property the bug violated, stated directly.
        $empty = @(Get-MlsCollection -Response ([pscustomobject]@{ value = @() }))
        $single = @(Get-MlsCollection -Response ([pscustomobject]@{ value = @([pscustomobject]@{ id = 'x' }) }))
        $empty.Count | Should -Not -Be $single.Count
    }
}

Describe 'collection helpers are re-wrapped at every call site' {
    BeforeAll {
        $script:AuditSource = @(
            Get-ChildItem -Path (Join-Path $PSScriptRoot '..') -Filter '*.ps1' -File
            Get-ChildItem -Path (Join-Path $PSScriptRoot '..') -Filter '*.psm1' -File
        )
    }

    # These helpers return a PIPELINE. `return @()` emits nothing, so an unwrapped
    # caller is handed nothing at all; `return @($one)` unrolls to the bare scalar.
    # Both throw on .Count and on [0] under Set-StrictMode -Version Latest, which
    # all twelve audit scripts set. Only two-or-more elements ever worked.
    #
    # The wrap cannot be pushed down into the helper: returning the array via the
    # comma operator makes @(helper) a nested one-element array instead, breaking
    # every caller that DOES wrap. @() at the call site is the only form that is
    # correct for zero, one and many, and it is idempotent. So this is a call-site
    # invariant, and this test is what keeps it one.
    #
    # layer-01-audit died in CI this way, before evaluating a single criterion,
    # while its own tests stayed green because the harness set Set-StrictMode -Off
    # and every assertion re-wrapped the call itself (F49).

    It 'no audit assigns <Helper> without @()' -ForEach @(
        @{ Helper = 'Get-MlsCollection' }
        @{ Helper = 'Get-AllowedGuid' }
        @{ Helper = 'Get-ManifestUserPrincipalName' }
        @{ Helper = 'Get-MlsLabel' }
    ) {
        #  matters: without it 'Get-MlsLabel' also matches Get-MlsLabelPolicy, which
        # returns a single object and is null-checked by its caller - wrapping that in
        # @() would break the check this guard is supposed to protect.
        $pattern = '\$\w+\s*=\s*' + [regex]::Escape($Helper) + '\b'
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $script:AuditSource) {
            $number = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                $number++
                if ($line -match $pattern) { $offender.Add("$($file.Name):$number") }
            }
        }
        $offender -join ', ' | Should -BeNullOrEmpty -Because 'the helper unrolls to nothing when empty and to a bare scalar when it holds one item; the call site must wrap it in @()'
    }
}
