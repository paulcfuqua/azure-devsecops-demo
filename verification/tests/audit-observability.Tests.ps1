# Pester tests for how the audit engine tells "could not look" apart from "looked and
# found it wrong" - the distinction L11's V11.3 depends on. Every transport is mocked; the
# one test that needs a real child process runs a throwaway script, never an audit.
#
# PAID FOR on the 2026-09-25 L11 rebuild proof (infra-up run 36095279150): gh had no
# credential in the child audits, Invoke-Sqlcmd was not installed, and both were retried for
# their criteria's full windows - V1.1 for thirty minutes - as if waiting could install a
# module or mint a token. They then reported as ordinary FAILs, indistinguishable from a
# broken layer.

BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'MlsAudit.psm1') -Force
    # No Set-StrictMode -Off: the audit scripts set -Version Latest and CI runs them that
    # way, so the harness must not relax the language mode it is testing (F49).

    $script:ReportRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "mls-observability-$([guid]::NewGuid().ToString('n'))"
    $script:TokenVariable = @('GH_TOKEN', 'MLS_VERIFIER_GH_TOKEN')
    $script:SavedToken = @{}
    foreach ($name in $script:TokenVariable) { $script:SavedToken[$name] = [Environment]::GetEnvironmentVariable($name) }

    function New-TestContext {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Pure builder: returns an in-memory audit context and changes no state anywhere.')]
        param()
        return New-MlsAuditContext -Layer 1 -Title 'observability test' -ScriptName 'test.ps1' -ReportRoot $script:ReportRoot
    }
}

AfterAll {
    foreach ($name in $script:TokenVariable) { [Environment]::SetEnvironmentVariable($name, $script:SavedToken[$name]) }
    if (Test-Path -LiteralPath $script:ReportRoot) {
        Remove-Item -LiteralPath $script:ReportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Module 'MlsAudit' -Force -ErrorAction SilentlyContinue
}

Describe 'a configuration error is not retried, and is recorded as unobservable' {
    BeforeEach {
        foreach ($name in $script:TokenVariable) { [Environment]::SetEnvironmentVariable($name, $null) }
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'
    }

    It 'stops at the first attempt when a required tool is missing, inside a 30-minute window' {
        # L5's V5.2 on 2026-09-25: thirty minutes asking whether Invoke-Sqlcmd had appeared.
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V5.2' -Description 'd' -Command 'c' -Expected 'e' `
            -RetryWindowMinutes 30 -Test {
            Assert-MlsCommand -Name 'mls-no-such-command-f7c1' -Hint 'Install it.'
            New-MlsCheckResult -Passed $true -Observed 'unreachable'
        }
        $row.Status | Should -Be 'FAIL'
        $row.Attempt | Should -Be 1
        $row.Unobservable | Should -BeTrue
        $row.Detail | Should -BeLike '*configuration error, not retried*'
        Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 0
        # Still a FAIL for the run: an audit that could not look must never exit green.
        Get-MlsExitCode -Context $context | Should -Be 1
    }

    It 'stops at the first attempt when gh has no credential (exit 4), and says it could not look' {
        Mock Assert-MlsCommand {} -ModuleName 'MlsAudit'
        Mock Invoke-MlsBoundedNativeCommand {
            [pscustomobject]@{ TimedOut = $false; ExitCode = 4; StdOut = ''
                StdErr = "gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN environment variable. Example:`n  env:`n    GH_TOKEN: `${{ github.token }}" }
        } -ModuleName 'MlsAudit'
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V1.1' -Description 'd' -Command 'c' -Expected 'e' `
            -RetryWindowMinutes 30 -Test { Invoke-MlsGh -Argument @('run', 'list', '--repo', 'o/r') }
        $row.Status | Should -Be 'FAIL'
        $row.Attempt | Should -Be 1
        $row.Unobservable | Should -BeTrue
        $row.Observed | Should -BeLike '*exit code 4*'
        Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Exactly -Times 0
    }

    It 'recognises the gh no-credential text even when it was re-thrown as a plain string' {
        # Criteria sometimes catch and re-throw with a new message; the Data marker is lost
        # but gh's own words survive, and they still mean "this runner has no token".
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V9.1' -Description 'd' -Command 'c' -Expected 'e' `
            -RetryWindowMinutes 20 -Test { throw 'gh api repos/o/r failed with exit code 4: gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN environment variable.' }
        $row.Attempt | Should -Be 1
        $row.Unobservable | Should -BeTrue
    }

    It 'still retries an ordinary transient failure for its window' {
        # The class is narrow on purpose. A 502 or a propagation miss is exactly what the
        # window exists for, and must keep getting it.
        Mock Assert-MlsCommand {} -ModuleName 'MlsAudit'
        Mock Invoke-MlsBoundedNativeCommand {
            [pscustomobject]@{ TimedOut = $false; ExitCode = 1; StdOut = ''; StdErr = 'HTTP 502: Bad Gateway' }
        } -ModuleName 'MlsAudit'
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V1.1' -Description 'd' -Command 'c' -Expected 'e' `
            -RetryWindowMinutes 2 -PollIntervalSeconds 20 -Test { Invoke-MlsGh -Argument @('api', 'repos/o/r') }
        $row.Status | Should -Be 'FAIL'
        $row.Attempt | Should -BeGreaterThan 1
        $row.Unobservable | Should -BeFalse
        Should -Invoke Wait-MlsRetryInterval -ModuleName 'MlsAudit' -Times 1
    }

    It 'does not treat a permission failure as unobservable-by-configuration' {
        # A 403 is Final (F57) but it IS an observation about the identity's grants, and
        # the existing classification stays exactly as it was.
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V2.1' -Description 'd' -Command 'c' -Expected 'e' `
            -RetryWindowMinutes 5 -Test { throw 'AuthorizationFailed: the client does not have authorization' }
        $row.Attempt | Should -Be 1
        $row.Unobservable | Should -BeFalse
        $row.Detail | Should -BeLike '*permission failure*'
    }
}

Describe 'the Verifier token reaches gh, not just the preflight' {
    BeforeEach {
        foreach ($name in $script:TokenVariable) { [Environment]::SetEnvironmentVariable($name, $null) }
        Mock Assert-MlsCommand {} -ModuleName 'MlsAudit'
        Mock Invoke-MlsBoundedNativeCommand {
            [pscustomobject]@{ TimedOut = $false; ExitCode = 0; StdOut = "{`"seen`":`"$($env:GH_TOKEN)`"}"; StdErr = '' }
        } -ModuleName 'MlsAudit'
    }

    It 'hands MLS_VERIFIER_GH_TOKEN to gh when GH_TOKEN is absent, and leaves GH_TOKEN absent afterwards' {
        # Every audit's preflight accepts MLS_VERIFIER_GH_TOKEN; gh reads only GH_TOKEN and
        # GITHUB_TOKEN. A job carrying only the first passed every preflight and then failed
        # every GitHub read (the L11 up-phase job, 2026-09-25).
        $env:MLS_VERIFIER_GH_TOKEN = 'verifier-read-token'
        (Invoke-MlsGh -Argument @('api', 'repos/o/r')).seen | Should -Be 'verifier-read-token'
        [string]::IsNullOrEmpty($env:GH_TOKEN) | Should -BeTrue
    }

    It 'keeps a GH_TOKEN the job already set' {
        $env:MLS_VERIFIER_GH_TOKEN = 'verifier-read-token'
        $env:GH_TOKEN = 'job-token'
        (Invoke-MlsGh -Argument @('api', 'repos/o/r')).seen | Should -Be 'job-token'
    }
}

Describe 'the Unobservable flag on a result row' {
    BeforeEach {
        Mock Write-MlsStatus {} -ModuleName 'MlsAudit'
        Mock Wait-MlsRetryInterval {} -ModuleName 'MlsAudit'
    }

    It 'follows the UNOBSERVABLE text convention the audits already write' {
        (New-MlsCheckResult -Passed $false -Observed 'UNOBSERVABLE: the endpoint could not be read').Unobservable | Should -BeTrue
        (New-MlsCheckResult -Passed $false -Observed 'value differs; UNOBSERVABLE appears mid-text only').Unobservable | Should -BeFalse
        (New-MlsCheckResult -Passed $false -Observed 'no deploy manifest supplied').Unobservable | Should -BeFalse
        (New-MlsCheckResult -Passed $false -Unobservable -Observed 'no deploy manifest supplied').Unobservable | Should -BeTrue
    }

    It 'never marks a PASS row unobservable - a pass is an observation' {
        $context = New-TestContext
        $row = Invoke-MlsCriterion -Context $context -Id 'V1.3' -Description 'd' -Command 'c' -Expected 'e' -NoRetry `
            -Test { New-MlsCheckResult -Passed $true -Unobservable -Observed 'fine' }
        $row.Status | Should -Be 'PASS'
        $row.Unobservable | Should -BeFalse
    }

    It 'survives the round trip through the JSON report, which is what L11 reads' {
        $context = New-TestContext
        Invoke-MlsCriterion -Context $context -Id 'V7.1' -Description 'd' -Command 'c' -Expected 'e' -NoRetry `
            -Test { New-MlsCheckResult -Passed $false -Final -Unobservable -Observed 'no deploy manifest supplied' } | Out-Null
        Invoke-MlsCriterion -Context $context -Id 'V7.2' -Description 'd' -Command 'c' -Expected 'e' -NoRetry `
            -Test { New-MlsCheckResult -Passed $false -Final -Observed 'golden spec mismatch' } | Out-Null
        $written = Write-MlsReport -Context $context -Timestamp ([guid]::NewGuid().ToString('n'))
        $document = Get-Content -LiteralPath $written.JsonPath -Raw | ConvertFrom-Json
        @($document.criteria | Where-Object { $_.Id -eq 'V7.1' })[0].Unobservable | Should -BeTrue
        @($document.criteria | Where-Object { $_.Id -eq 'V7.2' })[0].Unobservable | Should -BeFalse
        $markdown = Get-Content -LiteralPath $written.MarkdownPath -Raw
        # Exactly one Observability line: for the row that could not look, not the one that did.
        ([regex]::Matches($markdown, '\*\*Observability:\*\* UNOBSERVABLE')).Count | Should -Be 1
    }
}

Describe 'Invoke-MlsChildAudit hands a child its environment and restores the parent' {
    BeforeAll {
        $script:ChildScript = Join-Path -Path $script:ReportRoot -ChildPath 'print-env.ps1'
        New-Item -ItemType Directory -Path $script:ReportRoot -Force | Out-Null
        Set-Content -LiteralPath $script:ChildScript -Value 'Write-Output "seen=$($env:MLS_OBSERVABILITY_TEST_VAR)"; exit 7' -Encoding utf8
    }

    It 'sets the variable in the child only for its run' {
        [Environment]::SetEnvironmentVariable('MLS_OBSERVABILITY_TEST_VAR', $null)

        $run = Invoke-MlsChildAudit -ScriptPath $script:ChildScript -Environment @{ MLS_OBSERVABILITY_TEST_VAR = 'rebuild-start' }
        $run.ExitCode | Should -Be 7
        ($run.Output -join "`n") | Should -BeLike '*seen=rebuild-start*'
        [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('MLS_OBSERVABILITY_TEST_VAR')) | Should -BeTrue
    }

    It 'does not export an empty value as if it had been supplied' {
        [Environment]::SetEnvironmentVariable('MLS_OBSERVABILITY_TEST_VAR', $null)
        $run = Invoke-MlsChildAudit -ScriptPath $script:ChildScript -Environment @{ MLS_OBSERVABILITY_TEST_VAR = '' }
        ($run.Output -join "`n") | Should -BeLike '*seen=*'
        ($run.Output -join "`n") | Should -Not -BeLike '*seen=?*'
    }
}

Describe 'a criterion reads the RESOLVED input, never the raw parameter it was resolved from' {
    # PAID FOR 2026-09-25. layer-06-audit.ps1 resolved $subscription from -SubscriptionId OR
    # AZURE_SUBSCRIPTION_ID, and then V6.7/V6.8 passed the raw $SubscriptionId - empty
    # whenever the id came through the environment. The standalone verify job passes it as an
    # argument and never noticed; L11's children get only the environment, and both criteria
    # threw "Cannot bind argument to parameter 'SubscriptionId' because it is an empty string".
    BeforeAll {
        $script:AuditRoot = Join-Path -Path $PSScriptRoot -ChildPath '..'
        $script:ResolvePattern = '(?m)^\s*\$(\w+)\s*=\s*Resolve-MlsInput\s+-Name\s+''\w+''\s+-Value\s+\$(\w+)'

        function Find-RawUseAfterResolve {
            param([Parameter(Mandatory)][string]$Text)
            $start = $Text.IndexOf('function Invoke-Main')
            if ($start -lt 0) { return @() }
            $end = $Text.IndexOf('if (-not $env:MLS_SKIP_MAIN)', $start)
            if ($end -lt 0) { $end = $Text.Length }
            $body = $Text.Substring($start, $end - $start)
            $found = foreach ($match in [regex]::Matches($body, $script:ResolvePattern)) {
                $raw = $match.Groups[2].Value
                $after = $body.Substring($match.Index + $match.Length)
                foreach ($line in ($after -split "`n")) {
                    if ($line.Trim().StartsWith('#')) { continue }
                    if ($line -match ('\$' + [regex]::Escape($raw) + '\b')) { "$raw -> $($match.Groups[1].Value): $($line.Trim())" }
                }
            }
            return @($found)
        }
    }

    It 'the detector fires on the shape that caused the defect, and not on its fix' {
        $broken = @(
            'function Invoke-Main {'
            '    $subscription = Resolve-MlsInput -Name ''SubscriptionId'' -Value $SubscriptionId -EnvironmentVariable @(''AZURE_SUBSCRIPTION_ID'')'
            '    Test-X -SubscriptionId $SubscriptionId'
            '}'
            'if (-not $env:MLS_SKIP_MAIN) { }'
        ) -join "`n"
        $fixed = $broken.Replace('Test-X -SubscriptionId $SubscriptionId', 'Test-X -SubscriptionId $subscription')
        @(Find-RawUseAfterResolve -Text $broken).Count | Should -Be 1
        @(Find-RawUseAfterResolve -Text $fixed).Count | Should -Be 0
    }

    It 'finds resolved inputs to check, so the sweep is not vacuous' {
        $total = 0
        foreach ($file in Get-ChildItem -Path $script:AuditRoot -Filter 'layer-*-audit.ps1') {
            $total += [regex]::Matches((Get-Content -LiteralPath $file.FullName -Raw), $script:ResolvePattern).Count
        }
        $total | Should -BeGreaterThan 5
    }

    It 'no audit uses a raw parameter after resolving it' {
        $offenders = foreach ($file in Get-ChildItem -Path $script:AuditRoot -Filter 'layer-*-audit.ps1') {
            foreach ($hit in Find-RawUseAfterResolve -Text (Get-Content -LiteralPath $file.FullName -Raw)) { "$($file.Name): $hit" }
        }
        @($offenders) | Should -BeNullOrEmpty
    }
}
