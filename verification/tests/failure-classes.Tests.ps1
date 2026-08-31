# Preventive checks for the failure CLASSES this estate has already paid for.
#
# Every finding below was discovered by deploying, failing, and reading a log - the most
# expensive way there is. Each run buys one defect, because a layer stops at its first error,
# so a class of defect present in four places costs four deploys to find. These tests turn
# each class into something a laptop finds in a second.
#
# The classes, and where they were learned:
#
#   F70  A fix at the call site protects one call; a fix at the CHOKE POINT protects the
#        class. L3's replication retry was added to the failing POST, and the next run died
#        on the GET one line above it. Every transport wrapper needs the retry, not every
#        call site.
#   F69  A predicate matching Graph error text against $_.Exception.Message never fires:
#        Invoke-MgGraphRequest puts the terse status there and the error CODE in
#        $_.ErrorDetails.Message. A correct retry keyed on a field that never carries the
#        value is indistinguishable from no retry at all.
#
# These are deliberately INVENTORY-BASED, like verification/guid-allowlist.txt. A new
# transport that nobody thought about does not silently inherit an exemption: it fails this
# suite until someone declares what it is and whether it retries.
#
# WHAT THIS DOES NOT COVER, stated so nobody mistakes a green run for full coverage:
# only HTTP transports. L4 reaches Purview through Security & Compliance PowerShell cmdlets
# and L8 reaches Power Platform through the `pac` CLI - neither is an Invoke-* HTTP call, so
# neither is visible here. Those are a real gap, not an exemption; they need their own check
# once their failure shapes are known from a run rather than assumed from a reading.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

    # Raw transports: the calls that actually leave the machine.
    $script:TransportPattern = 'Invoke-MgGraphRequest|Invoke-RestMethod|Invoke-WebRequest'

    # Tokens that indicate a bounded retry rather than a single attempt.
    $script:RetryPattern = 'deadline|Start-Sleep|PropagationDelay|Retry-After|retry|attempt'

    # THE INVENTORY. Every non-test PowerShell file under infra/ or scripts/ that makes a raw
    # transport call must appear here, with an explicit verdict on retry.
    #
    # RetryRequired = $true  -> the file's transport must show bounded-retry machinery.
    # RetryRequired = $false -> deliberately none, with the reason stated. Read-only or
    #                           single-shot paths where a retry would hide a real answer.
    $script:TransportInventory = @(
        @{ Path = 'infra/entra/apply-entra.ps1'; RetryRequired = $true
            Why = 'Invoke-GraphApi is the choke point; every create is followed by reads and writes against an object that may not have replicated (F70).'
        }
        @{ Path = 'infra/entra/teardown.ps1'; RetryRequired = $false
            Why = 'Deletes. A 404 means the object is already gone, which is the desired end state - retrying it would wait out a budget to confirm success.'
        }
        @{ Path = 'infra/fabric/fabric-api.psm1'; RetryRequired = $true
            Why = 'Long-running operations are polled to a deadline honouring Retry-After. NOTE the transport itself does not retry a transient 429/503 - whether it needs to is unknown until L5 runs against a live capacity, and guessing is how three wrong theories about L3 got shipped.'
        }
    )
}

Describe 'every transport choke point is accounted for' {

    It 'finds transports at all' {
        # A discovery step that silently matches nothing would make every assertion vacuous.
        $files = @(Get-ChildItem -Path $script:RepoRoot -Recurse -Include '*.ps1', '*.psm1' -File |
                Where-Object { $_.FullName -notmatch '[\\/](tests|node_modules|\.git)[\\/]' } |
                Where-Object { $_.FullName -match '[\\/](infra|scripts)[\\/]' } |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match $script:TransportPattern })
        $files.Count | Should -BeGreaterThan 0
    }

    It 'every file making a raw transport call is declared in the inventory' {
        # The point of the inventory: a NEW transport cannot inherit an exemption by being
        # forgotten. Adding one means saying what it is and whether it retries.
        $declared = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($entry in $script:TransportInventory) { $null = $declared.Add($entry.Path) }

        $undeclared = [System.Collections.Generic.List[string]]::new()
        foreach ($file in (Get-ChildItem -Path $script:RepoRoot -Recurse -Include '*.ps1', '*.psm1' -File)) {
            if ($file.FullName -match '[\\/](tests|node_modules|\.git)[\\/]') { continue }
            if ($file.FullName -notmatch '[\\/](infra|scripts)[\\/]') { continue }
            if ((Get-Content -LiteralPath $file.FullName -Raw) -notmatch $script:TransportPattern) { continue }
            $relative = $file.FullName.Substring($script:RepoRoot.Length).TrimStart('\', '/').Replace('\', '/')
            if (-not $declared.Contains($relative)) { $undeclared.Add($relative) }
        }
        $undeclared -join ', ' | Should -BeNullOrEmpty `
            -Because 'a transport nobody declared is a transport nobody decided about (F70)'
    }

    It 'every inventory entry that claims to retry actually does' {
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $script:TransportInventory) {
            if (-not $entry.RetryRequired) { continue }
            $full = Join-Path $script:RepoRoot $entry.Path
            if (-not (Test-Path -LiteralPath $full)) { $offender.Add("$($entry.Path) (missing)"); continue }
            # CODE only. `fabric-api.psm1` passed this check on the strength of a COMMENT
            # mentioning Retry-After while containing no retry whatsoever - a check satisfied
            # by prose about the thing it is checking for is the same defect it exists to
            # catch, one level up.
            $code = (Get-Content -LiteralPath $full) |
                ForEach-Object { ($_ -replace '(?<!`)#.*$', '') } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if (($code -join "`n") -notmatch $script:RetryPattern) { $offender.Add($entry.Path) }
        }
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'a transport that does not retry fails the first time its API is slow, and finds that out in a deploy'
    }

    It 'every inventory entry states why' {
        $missing = @($script:TransportInventory |
                Where-Object { [string]::IsNullOrWhiteSpace($_.Why) } |
                ForEach-Object { $_.Path })
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'an exemption without a reason is an oversight with a checkbox'
    }
}

Describe 'error predicates read the field that carries the value' {

    It 'no catch matches Graph or HTTP error codes against Exception.Message alone' {
        # F69: Invoke-MgGraphRequest puts the terse status in Exception.Message and the JSON
        # body carrying the error CODE in ErrorDetails.Message. A predicate reading only the
        # former is a retry that never fires - it passed every unit test and did nothing in
        # production, because the mocks threw the shape the author expected.
        $codePattern = 'Request_ResourceNotFound|ResourceNotFound|Authorization_RequestDenied|InsufficientPrivileges'
        $offender = [System.Collections.Generic.List[string]]::new()

        foreach ($file in (Get-ChildItem -Path $script:RepoRoot -Recurse -Include '*.ps1', '*.psm1' -File)) {
            if ($file.FullName -match '[\\/](node_modules|\.git)[\\/]') { continue }
            $lines = Get-Content -LiteralPath $file.FullName
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($line -notmatch '\$_\.Exception\.Message' -or $line -notmatch '-match') { continue }
                if ($line -notmatch $codePattern) { continue }
                # The value may be composed a line or two earlier or later; look at the block.
                $from = [math]::Max(0, $i - 4)
                $to = [math]::Min($lines.Count - 1, $i + 2)
                $block = ($lines[$from..$to]) -join "`n"
                if ($block -notmatch 'ErrorDetails') {
                    $relative = $file.FullName.Substring($script:RepoRoot.Length).TrimStart('\', '/').Replace('\', '/')
                    $offender.Add("${relative}:$($i + 1)")
                }
            }
        }
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'the Graph error code lives in ErrorDetails.Message; a predicate reading only Exception.Message never fires (F69)'
    }
}

Describe 'every job that runs is bounded' {

    BeforeAll {
        # Resolved here rather than relying on a $script: variable set in another scope. The
        # first version of this Describe scanned ZERO files and its main assertion passed on
        # an empty offender list - which is exactly the vacuity the second test below exists
        # to catch, and did.
        $script:BoundedWorkflowDir = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path '.github/workflows'
    }

    # F58 gave the AUDIT a budget so a stuck check could still report. The same reasoning was
    # never applied to the thing being audited: 65 jobs across this repo declared no
    # timeout-minutes at all, inheriting GitHub's six-hour default. A `what-if` that took 36
    # seconds against an empty estate hung indefinitely once there were resources to diff
    # against, and would have consumed that entire budget producing nothing (F81).
    #
    # A job without a bound is not "patient", it is a job whose failure mode is silence.

    It 'every job declares timeout-minutes' {
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($file in (Get-ChildItem -Path $script:BoundedWorkflowDir -Filter '*.yml' -File)) {
            $lines = Get-Content -LiteralPath $file.FullName
            $starts = [System.Collections.Generic.List[int]]::new()
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^  [A-Za-z0-9_.-]+:\s*$') { $starts.Add($i) }
            }
            $starts.Add($lines.Count)
            for ($s = 0; $s -lt $starts.Count - 1; $s++) {
                $from = $starts[$s]; $to = $starts[$s + 1]
                $block = ($lines[$from..($to - 1)]) -join "`n"
                # Only real jobs: a `jobs:` child with a runner.
                if ($block -notmatch '(?m)^    runs-on:') { continue }
                if ($block -notmatch '(?m)^    timeout-minutes:') {
                    $offender.Add("$($file.Name):$($lines[$from].Trim().TrimEnd(':'))")
                }
            }
        }
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'an unbounded job inherits a six-hour default, and a hung step then reports nothing at all'
    }

    It 'finds jobs to check, so the assertion is not vacuous' {
        $jobCount = 0
        foreach ($file in (Get-ChildItem -Path $script:BoundedWorkflowDir -Filter '*.yml' -File)) {
            $jobCount += ([regex]::Matches((Get-Content -LiteralPath $file.FullName -Raw), '(?m)^    runs-on:')).Count
        }
        $jobCount | Should -BeGreaterThan 20
    }
}

Describe 'every provider the estate uses is registered up front' {
    # An unregistered provider fails the layer that first touches it, minutes into a deploy,
    # in an error naming the provider rather than the layer. L6 deployed Key Vault and Azure
    # SQL cleanly and then died wiring the cost export on Microsoft.CostManagementExports; a
    # sweep found Microsoft.Security (L9) and Microsoft.PowerPlatform (L8) waiting to do the
    # same thing one run at a time (F82).
    #
    # The registration list is the artefact that goes stale, so it is checked against what
    # the templates actually reference.

    BeforeAll {
        $script:RepoRootP = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:InfraUp = Get-Content -LiteralPath (Join-Path $script:RepoRootP '.github/workflows/infra-up.yml') -Raw
    }

    It 'declares a registration list at all' {
        $script:InfraUp | Should -Match 'az provider register'
        ([regex]::Matches($script:InfraUp, '(?m)^\s+Microsoft\.[A-Za-z]+ \\?$')).Count |
            Should -BeGreaterThan 8 -Because 'the list is what stops a provider being discovered a layer at a time'
    }

    It 'covers every provider the bicep templates reference' {
        # Namespaces ARM always has: never worth registering explicitly.
        $alwaysPresent = @('Microsoft.Resources', 'Microsoft.Authorization', 'Microsoft.Management')

        $declared = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in [regex]::Matches($script:InfraUp, '(?m)^\s+(Microsoft\.[A-Za-z]+) \\?$')) {
            $null = $declared.Add($m.Groups[1].Value)
        }

        $referenced = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($file in (Get-ChildItem -Path (Join-Path $script:RepoRootP 'infra/bicep') -Recurse -Filter '*.bicep' -File)) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $file.FullName -Raw), "'(Microsoft\.[A-Za-z]+)/")) {
                $ns = $m.Groups[1].Value
                if ($ns -notin $alwaysPresent) { $null = $referenced.Add($ns) }
            }
        }

        $referenced.Count | Should -BeGreaterThan 3 -Because 'a scan matching nothing would make this vacuous'
        $missing = @($referenced | Where-Object { -not $declared.Contains($_) })
        $missing -join ', ' | Should -BeNullOrEmpty `
            -Because 'a provider the templates use but the list omits fails the layer that reaches it, not this test'
    }
}

Describe 'the SQL this estate ships is syntactically valid' {
    # data/seed/sql/900-contained-users.sql passed every test in this repo and was a syntax
    # error. RAISERROR accepts constants or variables and never a function call, so
    # `RAISERROR('...%s', 10, 1, ERROR_MESSAGE())` does not parse - and nothing executed the
    # file until L6 finally reached a live database, four days in (F84).
    #
    # The .ps1 that RUNS the SQL was well covered. The SQL was not covered at all, because a
    # test suite tests the language it is written in.

    BeforeAll {
        $script:SqlRoot = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path 'data/seed/sql'
    }

    It 'finds SQL files to check' {
        @(Get-ChildItem -Path $script:SqlRoot -Filter '*.sql' -File -Recurse).Count |
            Should -BeGreaterThan 0 -Because 'a scan matching nothing would make this vacuous'
    }

    It 'never passes a function call as a RAISERROR argument' {
        # The specific defect, encoded. RAISERROR's substitution arguments are constants or
        # variables; a call like ERROR_MESSAGE() or DB_NAME() is a parse error, and the parser
        # is the only thing that will tell you.
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($file in (Get-ChildItem -Path $script:SqlRoot -Filter '*.sql' -File -Recurse)) {
            $lines = Get-Content -LiteralPath $file.FullName
            for ($i = 0; $i -lt $lines.Count; $i++) {
                # An argument position ending in `()` on a RAISERROR continuation line.
                if ($lines[$i] -match '^\s*\d+\s*,\s*\d+\s*,.*[A-Z_]+\(\)\s*\)') {
                    $offender.Add("$($file.Name):$($i + 1)")
                }
            }
        }
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'RAISERROR takes constants or variables; a function call there is a syntax error the parser finds and no unit test does'
    }

    It 'every TRY block has a matching CATCH and END CATCH' {
        # A cheap structural check. Unbalanced blocks are the other way these files fail to
        # parse, and they fail at the same moment: against a real database, late.
        foreach ($file in (Get-ChildItem -Path $script:SqlRoot -Filter '*.sql' -File -Recurse)) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            $try = ([regex]::Matches($text, '(?im)^\s*BEGIN\s+TRY\b')).Count
            $catch = ([regex]::Matches($text, '(?im)^\s*BEGIN\s+CATCH\b')).Count
            $endCatch = ([regex]::Matches($text, '(?im)^\s*END\s+CATCH\b')).Count
            "$($file.Name): try=$try catch=$catch endCatch=$endCatch" |
                Should -Be "$($file.Name): try=$try catch=$try endCatch=$try"
        }
    }
}

Describe 'a reachability probe does not depend on data existing' {
    # V6.2 asserts the Verifier can REACH the Log Analytics workspace. It proved that with
    # `Heartbeat | take 1` - an agent table, filled by Azure Monitor Agent on virtual
    # machines. This estate has none: Container Apps, Functions and SQL only. So the table
    # returns [] forever, and the criterion failed against a workspace holding 5,424 rows
    # across six tables it could read perfectly well (F86).
    #
    # Whether audit records EXIST is a different criterion with a different mapping. A probe
    # that conflates the two fails for the wrong reason and passes for the wrong reason.

    BeforeAll {
        $script:AuditRoot = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path ''
        # Tables that only exist when something outside this estate's architecture is running.
        $script:AgentOnlyTables = @('Heartbeat', 'Perf', 'Syslog', 'Event', 'SecurityEvent',
            'InsightsMetrics', 'ContainerLog', 'W3CIISLog')
    }

    It 'finds the audit scripts' {
        @(Get-ChildItem -Path $script:AuditRoot -Filter 'layer-*-audit.ps1' -File).Count |
            Should -BeGreaterThan 8
    }

    It 'no reachability probe queries an agent-only table' {
        # An agent table in a KQL probe is the tell: this estate deploys no agents, so the
        # query can only ever return empty, whatever the identity's permissions are.
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($file in (Get-ChildItem -Path $script:AuditRoot -Filter 'layer-*-audit.ps1' -File)) {
            $lines = Get-Content -LiteralPath $file.FullName
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -notmatch "analytics-query'?\s*,") { continue }
                foreach ($table in $script:AgentOnlyTables) {
                    if ($lines[$i] -match "'\s*$table\s*\|") {
                        $offender.Add("$($file.Name):$($i + 1) queries $table")
                    }
                }
            }
        }
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'this estate runs no Azure Monitor Agent, so an agent table is empty regardless of whether the query succeeded'
    }
}
