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
        # The last entry of the list ends ` ; do`, not ` \`. A pattern that requires
        # the trailing backslash silently skips whichever provider happens to be
        # last - which is how the check below came to report Microsoft.Web as
        # missing from a list that declares it.
        ([regex]::Matches($script:InfraUp, '(?m)^\s+Microsoft\.[A-Za-z]+(?:\s+\\|\s+;\s+do)?\s*$')).Count |
            Should -BeGreaterThan 8 -Because 'the list is what stops a provider being discovered a layer at a time'
    }

    It 'covers every provider the bicep templates reference' {
        # Namespaces ARM always has: never worth registering explicitly.
        $alwaysPresent = @('Microsoft.Resources', 'Microsoft.Authorization', 'Microsoft.Management')

        $declared = [System.Collections.Generic.HashSet[string]]::new()
        # Same pattern as the check above, and for the same reason: the final entry
        # of the list ends ` ; do` rather than ` \`, so a pattern requiring the
        # trailing backslash reports a provider absent that is declared two lines
        # away.
        foreach ($m in [regex]::Matches($script:InfraUp, '(?m)^\s+(Microsoft\.[A-Za-z]+)(?:\s+\\|\s+;\s+do)?\s*$')) {
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


Describe 'a deploy default never stands up a placeholder image' {
    # L7 deployed five container apps, reported success, and served
    # `mcr.microsoft.com/azuredocs/containerapps-helloworld` from every one of them. The
    # audit was right and the deploy was wrong: V7.1 (no image digest), V7.3 (no telemetry)
    # and V7.5 (scale profile) were three symptoms of the one fact that none of the demo's
    # applications were running (F88).
    #
    # Two independent knobs caused it. `image_tag` defaulted to '' meaning "keep the
    # placeholder", and the target ports defaulted to 80 - the placeholder's port, not the
    # 8080 every real app Dockerfile EXPOSEs. Either alone produces an estate that
    # provisions cleanly and answers nothing, so neither may carry a placeholder default.
    #
    # This is CLAUDE.md's "every value has one source" with a second edge: the caller's
    # input outranks the callee's default, so infra-up.yml is checked too, not just the
    # layer workflow it calls.

    BeforeAll {
        $script:WorkflowRoot = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path '.github/workflows'
        $script:PlaceholderImages = @(
            'containerapps-helloworld',
            'k8se/quickstart'
        )
    }

    It 'finds workflows declaring an image tag, so the assertion is not vacuous' {
        $found = @(Get-ChildItem -Path $script:WorkflowRoot -Filter '*.yml' -File |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '(?m)^\s*image_tag:\s*$' })
        $found.Count | Should -BeGreaterThan 0 `
            -Because 'if no workflow declares an image_tag input, this whole Describe asserts nothing'
    }

    It 'no image_tag input defaults to the placeholder path' {
        # An empty default means "deploy the placeholder". That is a legitimate thing to
        # ASK for and the wrong thing to GET by omission.
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($file in (Get-ChildItem -Path $script:WorkflowRoot -Filter '*.yml' -File)) {
            $lines = Get-Content -LiteralPath $file.FullName
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -notmatch '(?m)^\s*image_tag:\s*$') { continue }
                # The input's own `default:` is the first one before the next input key.
                for ($j = $i + 1; $j -lt [Math]::Min($i + 12, $lines.Count); $j++) {
                    if ($lines[$j] -match "^\s*default:\s*(''|""""|)\s*$") {
                        $offender.Add("$($file.Name):$($j + 1) image_tag defaults to empty")
                        break
                    }
                    if ($lines[$j] -match '^\s*default:') { break }
                }
            }
        }
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'an empty image_tag deploys containerapps-helloworld, which provisions cleanly and serves none of the demo (F88)'
    }

    It 'no job-level env defaults a container target port to the placeholder port' {
        # The port is not independent of the image: real images listen on 8080, the
        # placeholder on 80. Defaulting the port separately is how the two disagreed.
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($file in (Get-ChildItem -Path $script:WorkflowRoot -Filter '*.yml' -File)) {
            $lines = Get-Content -LiteralPath $file.FullName
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "^\s*[A-Z_]+_PORT:\s*\`$\{\{\s*vars\.[A-Z_]+\s*\|\|\s*'80'\s*\}\}") {
                    $offender.Add("$($file.Name):$($i + 1)")
                }
            }
        }
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'the target port must be derived from the image actually being deployed, not defaulted to the placeholder port alongside it (F88)'
    }

    It 'the bicepparam placeholder images stay reachable as a deliberate opt-in' {
        # The placeholder itself is not the defect and must not be deleted: it is what
        # keeps the layer deployable before the first image publishes. This asserts it
        # still EXISTS, so a later cleanup does not quietly remove the fallback while
        # thinking it is removing the bug.
        $bicepparam = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path 'infra/bicep/apps/demo.bicepparam'
        $content = Get-Content -LiteralPath $bicepparam -Raw
        ($script:PlaceholderImages | Where-Object { $content -match [regex]::Escape($_) }).Count |
            Should -BeGreaterThan 0 `
            -Because 'the placeholder remains the documented fallback for an estate with no published images; F88 was about which path is the DEFAULT, not about the fallback existing'
    }
}


Describe 'an identity the estate authenticates to actually exists' {
    # Four app registrations sat in a live tenant with no service principal. Nothing failed
    # visibly: an application object is a DEFINITION, and Entra creates the principal on
    # first interactive consent, so sign-in worked. Only client-credentials issuance was
    # broken - and nothing asked for one until V7.3 needed a token to get past Easy Auth
    # and reach application code (F89).
    #
    # Two checks, because the finding had two halves. The deploy path must create the
    # principal for EVERY registration, unconditionally; and a criterion that asserts
    # telemetry must not probe the liveness path, which is by design answered without
    # running application code.

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:ApplyEntra = Join-Path $script:RepoRoot 'infra/entra/apply-entra.ps1'
        $script:EntraManifest = Join-Path $script:RepoRoot 'infra/entra/manifest.json'
    }

    It 'finds the manifest and the apply script, so the assertions are not vacuous' {
        Test-Path -LiteralPath $script:ApplyEntra | Should -BeTrue
        Test-Path -LiteralPath $script:EntraManifest | Should -BeTrue
        $manifest = Get-Content -LiteralPath $script:EntraManifest -Raw | ConvertFrom-Json
        @($manifest.appRegistrations).Count | Should -BeGreaterThan 0
    }

    It 'creates a service principal for every app registration, with no flag to skip it' {
        $content = Get-Content -LiteralPath $script:ApplyEntra -Raw
        $content | Should -Match 'Initialize-EntraServicePrincipal' `
            -Because 'an application registered without its principal is a half-created object that fails only where a token is requested'
        # A manifest flag defaulting to true that nobody would ever set false is the F85
        # pattern - a documented manual step reading as a design. The principal is not
        # optional, so no per-app flag may gate it.
        $content | Should -Not -Match "Get-Field -Object \`$app -Name 'createServicePrincipal'" `
            -Because 'gating the principal on a manifest flag reintroduces the half-created state for anyone who omits it'
    }

    It 'never probes for telemetry down the liveness path' {
        # /healthz is excluded from Easy Auth and answered by nginx from its own config:
        # no application code runs, so no span can exist. Reusing it as the telemetry
        # probe is what made V7.3 unsatisfiable rather than merely failing.
        $audit = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'verification/layer-07-audit.ps1') -Raw
        $audit | Should -Not -Match 'Test-OtelSpan[^\n]*-HealthPath' `
            -Because 'a liveness endpoint is deliberately cheap and often served without touching application code, so it cannot evidence application telemetry'
    }

    It 'sends the telemetry probe with an Authorization header' {
        $audit = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'verification/layer-07-audit.ps1') -Raw
        $audit | Should -Match 'Authorization\s*=\s*"Bearer' `
            -Because 'every non-excluded path returns 401 at Easy Auth, so an anonymous probe cannot reach application code however long it retries'
    }
}


Describe 'the estate can be renamed from one place' {
    # Every AZURE name derived from naming.bicep's companyPrefix, while every ENTRA name was
    # hardcoded 'mls-...' - 22 of them - and the Fabric workspace was pinned to
    # 'mls-operations'. A cloner who set the prefix therefore got acme-rg-platform resource
    # groups sitting beside mls-flight-operations groups: half a rebrand, and the half that
    # is hardest to notice because Entra and Fabric are not the portal blade you are looking
    # at (F90).
    #
    # naming.bicep stays the single source of the DEFAULTS. estate.env (locally) and the
    # `demo` GitHub environment (in CI) override them. These tests hold that line.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:NamingFile = Join-Path $script:Root 'infra/bicep/naming.bicep'
        $script:BicepParams = @(Get-ChildItem -Path (Join-Path $script:Root 'infra/bicep') -Filter '*.bicepparam' -Recurse -File)
        function Get-NamingLiteral {
            param([string]$Name)
            $m = Select-String -LiteralPath $script:NamingFile -Pattern "^var $Name = '([^']*)'" | Select-Object -First 1
            if ($m) { return $m.Matches[0].Groups[1].Value }
            return ''
        }
    }

    It 'finds naming.bicep and the bicepparam files, so nothing here is vacuous' {
        Test-Path -LiteralPath $script:NamingFile | Should -BeTrue
        $script:BicepParams.Count | Should -BeGreaterThan 0
        Get-NamingLiteral -Name 'defaultCompanyPrefix' | Should -Not -BeNullOrEmpty
    }

    It 'every bicepparam fallback equals naming.bicep, so the second copy cannot drift' {
        # A .bicepparam cannot import a var from the template it targets, so the literal is
        # unavoidably duplicated. Duplication that is ASSERTED is a cache; duplication that
        # is not is a second source of truth waiting to disagree.
        $prefix = Get-NamingLiteral -Name 'defaultCompanyPrefix'
        $envSeg = Get-NamingLiteral -Name 'defaultEnv'
        foreach ($file in $script:BicepParams) {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            if ($content -match "MLS_COMPANY_PREFIX', ''\)\) \? '([^']*)'") {
                $Matches[1] | Should -Be $prefix -Because "$($file.Name) must fall back to naming.bicep's defaultCompanyPrefix"
            }
            if ($content -match "MLS_ENV_SEGMENT', ''\)\) \? '([^']*)'") {
                $Matches[1] | Should -Be $envSeg -Because "$($file.Name) must fall back to naming.bicep's defaultEnv"
            }
        }
    }

    It 'no bicepparam trusts readEnvironmentVariable to supply the estate default' {
        # readEnvironmentVariable's own default fires only when the variable is UNSET, and an
        # undefined GitHub variable expands to the EMPTY STRING (F26). Verified live: with
        # MLS_COMPANY_PREFIX= set empty, the unguarded form yielded '' and every resource
        # would have been named '-rg-platform'.
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $script:BicepParams) {
            foreach ($variable in @('MLS_COMPANY_PREFIX', 'MLS_ENV_SEGMENT')) {
                $content = Get-Content -LiteralPath $file.FullName -Raw
                if ($content -notmatch [regex]::Escape($variable)) { continue }
                if ($content -notmatch "empty\(readEnvironmentVariable\('$variable'") {
                    $offender.Add("$($file.Name):$variable")
                }
            }
        }
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'an empty environment variable must fall back to the estate default, not name every resource after nothing'
    }

    It 'the Entra manifest holds no literal company prefix' {
        # The manifest is tokenised so one edit renames every group, user, app registration
        # and CA policy. A literal that creeps back renames only itself.
        $prefix = Get-NamingLiteral -Name 'defaultCompanyPrefix'
        $manifest = Get-Content -LiteralPath (Join-Path $script:Root 'infra/entra/manifest.json') -Raw
        $manifest | Should -Not -Match "\`"$prefix-" `
            -Because 'names in the manifest must be written as ${prefix}-... so a rebrand reaches identity as well as Azure'
    }

    It 'every prefix resolver honours the environment override' {
        # The override was added to the bicepparams, the naming action, apply-entra and the
        # Fabric scripts - and NOT to Purview, the policy teardown, the L4 audit or
        # down.ps1, which kept parsing naming.bicep alone. Set MLS_COMPANY_PREFIX and the
        # estate splits: Azure named acme-*, sensitivity labels still mls-*, and down.ps1
        # deleting resource groups that do not exist while reporting a clean teardown -
        # "indistinguishable from success", the same shape as the Entra teardown (F91).
        #
        # THE RULE IS TOTAL, WITH A NAMED ALLOWLIST. The first version of this test tried
        # to detect "is a resolver" by pattern and matched nothing at all - it scanned zero
        # files and passed, which a mutation caught. Every mention now counts unless it is
        # listed below with a reason.
        # .bicep is OUT OF SCOPE, not allowlisted: a template cannot read an environment
        # variable at all (readEnvironmentVariable is bicepparam-only), so `param
        # companyPrefix string = naming.defaultCompanyPrefix` is the correct shape and the
        # override reaches it through demo.bicepparam. Scoping this sweep to .bicep flagged
        # all three templates, which is the check being wrong rather than the code.
        $allowed = @{
            'layer-04-purview.yml'      = 'names the variable in a comment only; delegates to labels.ps1'
            'failure-classes.Tests.ps1' = 'this test'
        }
        $seen = [System.Collections.Generic.List[string]]::new()
        $offender = [System.Collections.Generic.List[string]]::new()
        $roots = @('scripts', 'infra', 'verification', '.github') |
            ForEach-Object { Join-Path $script:Root $_ } | Where-Object { Test-Path $_ }
        foreach ($file in (Get-ChildItem -Path $roots -Recurse -Include *.ps1, *.psm1, *.yml -File)) {
            if ($file.FullName -like '*node_modules*') { continue }
            $content = Get-Content -LiteralPath $file.FullName -Raw
            if ($content -notmatch 'defaultCompanyPrefix') { continue }
            $seen.Add($file.Name)
            if ($allowed.ContainsKey($file.Name)) { continue }
            if ($content -notmatch 'MLS_COMPANY_PREFIX') { $offender.Add($file.Name) }
        }
        # Non-vacuity: this must actually find the resolvers, or it asserts nothing.
        $seen.Count | Should -BeGreaterThan 8 `
            -Because 'the sweep must reach every file naming defaultCompanyPrefix; finding almost none means the scan is broken, not that the repo is clean'
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'a resolver that reads naming.bicep but ignores MLS_COMPANY_PREFIX disagrees with every one that honours it'
    }

    It 'every consumer that PARSES the entra manifest resolves its tokens' {
        # F91 swept for files naming defaultCompanyPrefix. That was the wrong signal, and
        # the miss took the estate offline: .github/workflows/layer-07-apps.yml parses the
        # manifest to resolve Easy Auth client IDs, names no prefix variable at all, and
        # read display names of the literal form "${prefix}-launch-ops-${env}-app". They
        # matched no app registration, no client ID was produced, and main.bicep fails
        # closed to INTERNAL ingress - so the deploy succeeded and every dashboard left the
        # internet. V7.1 404, V7.5 no scale-out, V7.3 unable to probe: three criteria, one
        # unresolved token (F93).
        #
        # The signal is PARSING, not naming: a file that only passes the path, or mentions
        # it in a comment, resolves nothing and needs nothing.
        $offender = [System.Collections.Generic.List[string]]::new()
        $parsers = [System.Collections.Generic.List[string]]::new()
        $roots = @('scripts', 'infra', 'verification', '.github') |
            ForEach-Object { Join-Path $script:Root $_ } | Where-Object { Test-Path $_ }
        foreach ($file in (Get-ChildItem -Path $roots -Recurse -Include *.ps1, *.psm1, *.yml -File)) {
            if ($file.FullName -like '*node_modules*') { continue }
            $content = Get-Content -LiteralPath $file.FullName -Raw
            # A PARSE is a read of that file piped into ConvertFrom-Json, or a call to the
            # helper that does it. Anything else is a mention.
            # SCOPED TO THE ENTRA MANIFEST. verification/layer-07-audit.ps1 parses a
            # different manifest.json - the deploy manifest of per-app image digests -
            # which carries no tokens and needs no resolution. The first version of this
            # check flagged it, which was the check being wrong rather than the code.
            if ($content -notmatch "entra['/\\, ]+manifest\.json") { continue }
            $parses = ($content -match "manifest\.json'\)?\s*-Raw" -and $content -match 'ConvertFrom-Json') -or
                      ($content -match 'Get-MlsJsonFile[^\n]*ManifestPath') -or
                      ($content -match 'Get-Manifest -Path')
            if (-not $parses) { continue }
            $parsers.Add($file.Name)
            # AN ACTUAL RESOLUTION, NOT A MENTION OF ONE. Matching a bare '${prefix}'
            # anywhere in the file counts the explanatory COMMENT as the fix: a mutation
            # that deleted the Replace() call but left the comment above it still passed,
            # which is what a mirror looks like.
            $resolves = $content -match 'Replace\(''\$\{prefix\}''' -or
                        $content -match 'TokenReplacement' -or
                        $content -match 'Resolve-ManifestToken' -or
                        $content -match 'Get-Manifest -Path'
            if (-not $resolves) { $offender.Add($file.Name) }
        }
        $parsers.Count | Should -BeGreaterThan 3 `
            -Because 'the sweep must actually find the manifest parsers; finding almost none means it is broken, not that the repo is clean'
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'a consumer that parses the tokenised manifest without resolving ${prefix}/${env} looks up names that exist in no tenant, and main.bicep then fails closed to internal ingress'
    }

    It 'ships estate.env.example documenting every variable the code reads' {
        $example = Join-Path $script:Root 'estate.env.example'
        Test-Path -LiteralPath $example | Should -BeTrue
        $content = Get-Content -LiteralPath $example -Raw
        foreach ($variable in @('MLS_COMPANY_PREFIX', 'MLS_ENV_SEGMENT')) {
            $content | Should -Match $variable -Because 'a knob the code reads but the template never mentions is a knob nobody finds'
        }
    }
}


Describe 'a criterion correlates on a field the system actually emits' {
    # V7.3 tagged its synthetic probe with `?probe=<run>-<app>` and looked for that marker
    # in the span's Url. It ran five times over two days and matched nothing, while 70
    # perfectly good spans sat in the table: data-api's AppRequests rows have Url EMPTY,
    # always (F97).
    #
    # That is not a bug to fix in the app. Span attributes come from an ALLOWLIST which
    # deliberately excludes the raw path and query string as caller-controlled free text,
    # along with every header and any SQL. So the criterion was not just reading the wrong
    # column - it was quietly asking the application to start recording caller-supplied
    # text in telemetry so that an audit could pass. A check may not ask the system to
    # weaken itself in order to go green.
    #
    # Two checks, because the finding has two halves that fail independently: no query may
    # filter on the empty column, and the reason it is empty must stay true.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'never filters an App* telemetry table on Url' {
        $queries = [System.Collections.Generic.List[string]]::new()
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($file in Get-ChildItem -Path (Join-Path $script:Root 'verification') -Filter '*.ps1' -Recurse -File) {
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                # A KQL line, not prose about one: it must both name an App* table and pipe
                # into an operator. Comments explaining the finding mention AppRequests, and
                # counting those would make the sweep pass on its own documentation.
                if ($line -notmatch '\bApp(Requests|Dependencies|Traces|Exceptions|Events)\b\s*\|') { continue }
                if ($line -match '^\s*#') { continue }
                $queries.Add("$($file.Name): $($line.Trim())")
                if ($line -match '\|\s*where[^|]*\bUrl\b') { $offender.Add($file.Name) }
            }
        }
        $queries.Count | Should -BeGreaterThan 0 `
            -Because 'the sweep must actually find the telemetry queries; finding none means the pattern is broken, not that the repo is clean'
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'data-api never sets a URL span attribute, so Url is always empty and a filter on it can only ever return zero rows - correlate on OperationId (W3C trace context), which the request middleware does populate'
    }

    It 'keeps caller-supplied text out of data-api span attributes' {
        # The premise the check above rests on. If this ever stops being true, the reason
        # Url is empty has changed and the rule needs revisiting - which is exactly what a
        # failing test here should prompt, rather than someone quietly re-adding the marker.
        $attributes = Get-Content -LiteralPath (Join-Path $script:Root 'apps/data-api/src/telemetry/attributes.ts') -Raw
        foreach ($forbidden in @('ATTR_URL_FULL', 'ATTR_URL_QUERY', 'ATTR_URL_PATH', 'ATTR_CLIENT_ADDRESS',
                'http.url', 'url.full', 'url.query', 'originalUrl', 'req.query', 'req.headers')) {
            $attributes | Should -Not -BeLike "*$forbidden*" `
                -Because 'the span attribute allowlist is the estate''s "we never emit caller text" claim; adding a URL, query string, header or client address to it breaks that claim to make an audit convenient'
        }
        # Non-vacuity: prove the file really is the attribute builder and not an empty stub
        # that would pass every assertion above by containing nothing at all.
        $attributes | Should -BeLike '*ATTR_HTTP_ROUTE*' `
            -Because 'the low-cardinality route template is what the allowlist emits INSTEAD of the raw path'
    }
}


Describe 'a filter added to one layer is added to all of them' {
    # -OnlyCriterion was built for L7, because L7 is where the hour-long re-verify loop
    # was discovered: five audits at ~55 minutes to answer one question about V7.3 (P-10).
    #
    # The loop is not L7's. L6 waits out SQL auto-pause, L11 waits out a full teardown and
    # rebuild, L5 waits on Fabric. Shipping the filter on the one layer that happened to
    # hurt would leave every other layer paying the old price - and would be the F90 shape
    # exactly: a mechanism introduced in one place, with the consumers never swept.
    #
    # So this is a TOTAL rule with no allowlist. Every layer audit accepts the parameter,
    # and every workflow that runs one exposes it and passes it through. A new layer that
    # forgets is a failing test, not a discovery six weeks later.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'gives every layer audit script the -OnlyCriterion parameter' {
        $audits = @(Get-ChildItem -Path (Join-Path $script:Root 'verification') -Filter 'layer-*-audit.ps1' -File)
        $audits.Count | Should -BeGreaterThan 5 `
            -Because 'the sweep must actually find the audit scripts; finding almost none means the glob is broken, not that the repo is clean'
        # BOTH the declaration and the plumbing. Matching the parameter name alone passed
        # a mutation that renamed the script-level parameter and left the inner one intact
        # - a script whose -OnlyCriterion is unbindable from the command line, which is the
        # only place CI can set it. A declared knob that reaches nothing is not a filter.
        $offender = @($audits | Where-Object {
                $content = Get-Content -LiteralPath $_.FullName -Raw
                $declares = $content -match '(?m)^    \[string\[\]\]\$OnlyCriterion = @\(\)'
                $plumbs = $content -match '-OnlyCriterion \$OnlyCriterion'
                -not ($declares -and $plumbs)
            } | ForEach-Object { $_.Name })
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'a layer without the filter can only be re-verified in full, which is the hour-long loop P-10 exists to end'
    }

    It 'passes -OnlyCriterion through from every workflow that runs a layer audit' {
        $workflows = @(Get-ChildItem -Path (Join-Path $script:Root '.github/workflows') -Filter '*.yml' -File |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'actions/layer-audit' })
        $workflows.Count | Should -BeGreaterThan 5 `
            -Because 'the sweep must actually find the callers of the layer-audit action'
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($workflow in $workflows) {
            $content = Get-Content -LiteralPath $workflow.FullName -Raw
            # BOTH halves, because either alone is a dead knob: an input nothing reads is
            # a lie in the dispatch form, and a passthrough with no input can never fire.
            $declares = $content -match '(?m)^\s{6}only_criterion:'
            $passes = $content -match "inputs\.only_criterion && '-OnlyCriterion'"
            if (-not ($declares -and $passes)) { $offender.Add($workflow.Name) }
        }
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'a workflow that runs an audit but cannot filter it forces a full run to re-test one criterion'
    }

    It 'keeps exit code 3 meaning DIAGNOSTIC everywhere it is interpreted' {
        # The guard that makes the filter safe: SKIP does not fail a run, so without a
        # third code a filtered run would exit 0 and be indistinguishable from a full
        # green audit - a filter that could manufacture a sign-off by selecting only the
        # criteria that pass.
        $module = Get-Content -LiteralPath (Join-Path $script:Root 'verification/MlsAudit.psm1') -Raw
        $module | Should -Match 'if \(@\(\$Context\.OnlyCriterion\)\.Count -gt 0\) \{ return 3 \}' `
            -Because 'Get-MlsExitCode is where a filtered run stops being able to read as a pass'
        $action = Get-Content -LiteralPath (Join-Path $script:Root '.github/actions/layer-audit/action.yml') -Raw
        $action | Should -Match '3\) verdict="DIAGNOSTIC' `
            -Because 'reporting a filtered run as FAIL trains people to ignore the one code that means "no verdict"'
        $action | Should -Match 'exit 3' `
            -Because '3 must stay non-zero, or a filtered run gates a layer as though it had passed'
    }
}

Describe 'a step that owns the verdict actually runs' {
    # ZAP's baseline scan of the compliance app came back FAIL-NEW: 0 - zero High-risk
    # alerts, 59 passes - and L9 recorded a failed security gate. The gate never ran (F102).
    #
    # zap.yml puts the verdict in a step of its own, "Gate on High-risk alerts", and sets
    # `fail_action: false` on the scan action so findings do not fail the step. That was
    # right, and not enough: the action still failed on its OWN post-processing (the
    # workflow passed `-J report.json` in cmd_options, colliding with the action's built-in
    # `-J report_json.json`, so the file it went looking for was never written). A failed
    # step skips the ones after it, so the gate was skipped and the job reported a verdict
    # nobody had reached.
    #
    # The rule: when a workflow delegates pass/fail to a named gate step, that step runs
    # unconditionally. Anything less lets an unrelated failure masquerade as the verdict -
    # and a security gate that reports failure without assessing anything is worse than no
    # gate, because it trains people to dismiss it.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'runs every gate step even when an earlier step failed' {
        $gates = [System.Collections.Generic.List[string]]::new()
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($file in Get-ChildItem -Path (Join-Path $script:Root '.github/workflows') -Filter '*.yml' -File) {
            $line = Get-Content -LiteralPath $file.FullName
            for ($i = 0; $i -lt $line.Count; $i++) {
                if ($line[$i] -notmatch '^\s*- name:\s*Gate on ') { continue }
                $gates.Add("$($file.Name): $($line[$i].Trim())")
                # The condition must appear before the step's `run:`/`uses:` body.
                $guarded = $false
                for ($j = $i + 1; $j -lt [math]::Min($i + 6, $line.Count); $j++) {
                    if ($line[$j] -match '^\s*(run|uses):') { break }
                    if ($line[$j] -match '^\s*if:.*always\(\)') { $guarded = $true; break }
                }
                if (-not $guarded) { $offender.Add("$($file.Name): $($line[$i].Trim())") }
            }
        }
        $gates.Count | Should -BeGreaterThan 0 `
            -Because 'the sweep must actually find the gate steps; finding none means the pattern is broken, not that the repo is clean'
        $offender -join '; ' | Should -BeNullOrEmpty `
            -Because 'a gate step that can be skipped by an earlier failure reports a verdict it never reached'
    }

    It 'never passes -J to the ZAP action, which already supplies its own' {
        # The specific collision, kept as its own check because the general rule above
        # would not have caught it - the gate was correct, the step before it was not.
        $zap = Get-Content -LiteralPath (Join-Path $script:Root '.github/workflows/zap.yml') -Raw
        if ($zap -match "cmd_options:\s*'([^']*)'") {
            $Matches[1] | Should -Not -Match '(^|\s)-J(\s|$)' `
                -Because 'zaproxy/action-baseline already passes -J report_json.json; a second -J silently redirects the output and the action then fails on a file it never wrote'
        }
        else {
            throw 'cmd_options not found in zap.yml - this check no longer reads what it thinks it reads'
        }
    }
}

Describe 'a console helper can print the blank line its own banner needs' {

    # L8, 2026-08-31. export-agent.ps1 had never been run. Its first real invocation died
    # on its own "Add required objects" reminder, before contacting anything, because
    # Write-Status '' against [Parameter(Mandatory)][string]$Message is rejected:
    # Mandatory implies a non-empty check for strings unless AllowEmptyString says
    # otherwise. import-agent.ps1 carried the same helper and the same calls.
    #
    # This class was already paid for once. infra/entra/teardown.ps1,
    # infra/policy/teardown.ps1 and infra/purview/teardown.ps1 each carry a comment
    # explaining exactly this, and up.ps1, down.ps1 and seed.ps1 all guard it. Three files
    # still missed it - which is the entire argument for a check over a fix.
    #
    # Asserted on the CAPABILITY - the parameter can accept an empty string - rather than
    # on the artefact that usually accompanies it - this file happens to call it with ''.
    # A helper that gains a blank-line call tomorrow is already covered.

    BeforeAll {
        $script:ScriptFile = @(
            Get-ChildItem -Path $script:RepoRoot -Filter '*.ps1' -Recurse -File |
                Where-Object {
                    $_.FullName -notmatch '[\/](node_modules|\.git|bin|obj)[\/]' -and
                    $_.Name -notlike '*.Tests.ps1'
                }
        )

        # Parameters that carry human-facing console text, and so eventually get asked to
        # print a spacer line.
        $script:MessageParamPattern = '\[string\]\$(Message|Text|Line|Banner)\b'

        # Scoped to Write-* functions on purpose. The first draft of this check keyed on the
        # parameter name alone and flagged infra/entra/apply-entra.ps1's Get-DeterministicGuid,
        # whose [Parameter(Mandatory)][string]$Text derives an app-role GUID from a string --
        # a parameter that SHOULD reject an empty value, because an empty one would silently
        # mint a GUID for nothing. A console helper is identified by being one, not by the
        # spelling of its parameter.
        $script:ConsoleFunctionPattern = '^\s*function\s+(Write-[A-Za-z]+)'
    }

    It 'finds PowerShell scripts to check, so the assertions are not vacuous' {
        $script:ScriptFile.Count | Should -BeGreaterThan 10
    }

    It 'every Mandatory console-text parameter accepts an empty string' {
        $offender = foreach ($file in $script:ScriptFile) {
            $relative = $file.FullName.Substring($script:RepoRoot.Length).TrimStart('\', '/')
            $currentFunction = ''
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                if ($line -match $script:ConsoleFunctionPattern) { $currentFunction = $Matches[1] }
                elseif ($line -match '^\s*function\s') { $currentFunction = '' }
                if ($currentFunction -and
                    $line -match '\[Parameter\(Mandatory\)\]' -and
                    $line -match $script:MessageParamPattern -and
                    $line -notmatch 'AllowEmptyString') {
                    "${relative}: $currentFunction -> $($line.Trim())"
                }
            }
        }
        $offender | Should -BeNullOrEmpty -Because 'a Mandatory [string] rejects an empty string, so a banner printing a blank spacer line throws before the script does anything - add [AllowEmptyString()]'
    }
}

Describe 'a registration the design depends on is declared where L3 can create it' {
    # agent-definition.md 7.2 names two app registrations the agent's authentication needs:
    # mls-copilot-auth (the Entra ID V2 provider) and mls-copilot-canvas (the SPA the
    # control-tower canvas uses for MSAL). NEITHER IS DECLARED in infra/entra/manifest.json,
    # which is the only thing L3 creates from (F106).
    #
    # This is the night's recurring defect in its purest form. V3.1 confirms object counts
    # AGAINST THE MANIFEST, so a registration nobody declared is unfalsifiable by
    # construction: L3 has nothing to create, no layer fails, every gate stays green, and
    # the agent's authentication is blocked permanently. F98/F102/F103/F105 were checks that
    # could not see; this is a check that cannot even be asked.
    #
    # A criterion validating reality against a declaration can only ever find drift, never
    # omission. Something outside the declaration has to notice - which is what this is.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    # SKIPPED, NOT DELETED, AND NOT MADE TO PASS. The requirement is real and unmet: the
    # two registrations do not exist. It is skipped rather than red because the fix is NOT
    # two lines in the manifest - the schema carries only displayName/appKey/signInAudience/
    # notes/verifierProbeRole, and section 7.2 needs an exposed API scope, an SPA redirect
    # URI, and an authorized client application. Declaring the names alone would create two
    # EMPTY SHELLS: L3 creates them, V3.1's count matches, every gate goes green, and the
    # authentication is still blocked - the gap made invisible instead of merely present,
    # which is strictly worse than today.
    #
    # Un-skip when infra/entra/manifest.json and apply-entra.ps1 can express those three
    # things. Until then this is an Identity-workstream escalation, recorded in
    # docs/DEMO-READINESS.md, not a test to satisfy.
    It 'declares every app registration the agent definition depends on' -Skip {
        $definition = Join-Path $script:Root 'infra/copilot-studio/agent-definition.md'
        Test-Path -LiteralPath $definition | Should -BeTrue `
            -Because 'the agent definition is the human-readable source of truth for showpiece #1'

        # Section 7.2 is a two-column table whose first cell is the registration name.
        $section = (Get-Content -LiteralPath $definition -Raw) -split '(?m)^###\s' |
            Where-Object { $_ -match '^7\.2' }
        $section | Should -Not -BeNullOrEmpty -Because 'section 7.2 is where the registrations are named'

        $required = @([regex]::Matches("$section", '(?m)^\|\s*`([^`]+)`\s*\|') |
                ForEach-Object { $_.Groups[1].Value } |
                Where-Object { $_ -match 'copilot|app$' } | Sort-Object -Unique)
        $required.Count | Should -BeGreaterThan 0 `
            -Because 'the sweep must actually find the named registrations; finding none means the table shape changed, not that the repo is clean'

        # manifest.json is tokenised; the definition writes the resolved prefix.
        $manifest = (Get-Content -LiteralPath (Join-Path $script:Root 'infra/entra/manifest.json') -Raw).
            Replace('${prefix}', 'mls').Replace('${env}', 'demo')
        $declared = @([regex]::Matches($manifest, '"displayName"\s*:\s*"([^"]+)"') |
                ForEach-Object { $_.Groups[1].Value })

        $missing = @($required | Where-Object { $_ -notin $declared })
        $missing -join ', ' | Should -BeNullOrEmpty `
            -Because 'L3 creates only what the manifest declares, so a registration named in the design but absent from the manifest is never created and no layer ever fails - the agent authentication is blocked permanently while every gate stays green (F106)'
    }
}

Describe 'a teardown leaves nothing a rebuild will recover' {
    # The first kill/reinstantiate cycle failed on the way back up. Log Analytics workspaces
    # soft-delete for 14 days: `az group delete` did not destroy the workspace, and
    # recreating one with the same name in the same resource group RECOVERED it. ARM then
    # called the recovered workspace Succeeded while the scheduled-query-rule provider still
    # refused it, so both L6 alert rules failed with "The workspace could not be found"
    # (F107).
    #
    # Measured, not assumed: forty minutes after the rebuild, the workspace was STILL listed
    # by list-deleted-workspaces while simultaneously live, with a createdDate predating the
    # teardown and its original customerId intact. A stable contradiction, not propagation -
    # so the cheaper candidate fix, waiting it out, would have waited forever.
    #
    # The rule this encodes is broader than one resource: a teardown whose deletes are
    # RECOVERABLE has not torn anything down, it has hidden it, and the next rebuild inherits
    # the hidden thing instead of building fresh. Anything Azure soft-deletes has to be
    # purged explicitly by a teardown that claims the estate can be rebuilt from code.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:Down = Get-Content -LiteralPath (Join-Path $script:Root '.github/workflows/infra-down.yml') -Raw
    }

    It 'purges the Log Analytics workspace rather than letting the resource-group delete soft-delete it' {
        $script:Down | Should -Match 'log-analytics workspace delete' `
            -Because 'a resource-group delete soft-deletes the workspace, and a same-name rebuild then recovers it'
        # ANCHORED TO THE EXECUTED COMMAND, NOT THE PROSE ABOUT IT. The first version of
        # this matched `--force` within 200 characters of the command name, and the warning
        # text below the invocation tells the reader to run the same command by hand - so
        # deleting --force from the REAL call still passed. A sweep that matches its own
        # documentation is a mirror. `; then` pins it to the if-conditional that actually
        # runs.
        $script:Down | Should -Match '--workspace-name "\$\{LAW_NAME\}" --force --yes; then' `
            -Because '--force is what removes the 14-day recovery option; without it the delete IS the soft-delete this finding is about'
    }

    It 'purges before the resource groups go, because the workspace must still exist' {
        $purge = $script:Down.IndexOf('log-analytics workspace delete')
        $delete = $script:Down.IndexOf('Delete in parallel')
        $purge | Should -BeGreaterThan 0
        $delete | Should -BeGreaterThan 0
        $purge | Should -BeLessThan $delete `
            -Because 'purging after the resource group is gone finds nothing to purge, and the soft-deleted workspace survives to break the next rebuild'
    }

    It 'reports what the next rebuild will find, whether or not the purge worked' {
        # F107 cost an hour precisely because "The workspace could not be found" against a
        # workspace az calls Succeeded explains nothing. A teardown that leaves a recoverable
        # workspace behind must say so, at the moment it happens.
        $script:Down | Should -Match 'list-deleted-workspaces' `
            -Because 'the teardown should check what it left behind rather than assume the purge worked'
        $script:Down | Should -Match 'Soft-deleted workspace remains' `
            -Because 'the next rebuild inherits this, so the teardown is where it has to be said'
    }
}

Describe 'an array parameter a workflow passes is split, or not passed at all' {
    # `pwsh -File` cannot bind an array from separate argv tokens - a comma-joined value
    # arrives as ONE element and a space-separated one silently drops its tail. So a
    # workflow can only ever hand one token, and an array parameter that does not split it
    # receives something nobody wrote.
    #
    # [int[]]$ChildAuditLayer coerced "2,3,6" into the single layer 2346, and the L11 audit
    # went looking for verification/layer-2346-audit.ps1 (F108). -OnlyCriterion had been
    # given a comma split for exactly this reason; the same fix was not applied here, which
    # is the F90 shape in miniature - a class fixed only at the instance it was found.
    #
    # THREE EARLIER VERSIONS OF THIS SWEEP COULD NOT SEE THE PARAMETER IT EXISTS FOR. The
    # first matched only flags written literally on their own line; the second only flags in
    # single quotes; and the flag in question is produced by an expression and written in
    # double quotes. Matching the bare NAME cannot be defeated by punctuation - but it then
    # matches prose, so comment lines are stripped first. layer-07-apps.yml mentions
    # -AppName only to explain why it deliberately does NOT pass it, and a sweep that reads
    # that as "passed" is reading documentation, which is the same mistake in a third dress.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'splits every array parameter that a workflow actually hands it' {
        $workflowText = ''
        foreach ($file in Get-ChildItem -Path (Join-Path $script:Root '.github/workflows') -Filter '*.yml' -File) {
            $raw = Get-Content -LiteralPath $file.FullName
            if (($raw -join "`n") -notmatch 'actions/layer-audit') { continue }
            # Comments are prose about the workflow, not the workflow.
            $workflowText += (($raw | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
        }
        $workflowText | Should -Not -BeNullOrEmpty -Because 'the sweep must find the workflows that run audits'

        # A split done once in the shared module counts, and is better than per-script.
        $module = Get-Content -LiteralPath (Join-Path $script:Root 'verification/MlsAudit.psm1') -Raw

        $checked = [System.Collections.Generic.List[string]]::new()
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($audit in Get-ChildItem -Path (Join-Path $script:Root 'verification') -Filter 'layer-*-audit.ps1' -File) {
            $content = Get-Content -LiteralPath $audit.FullName -Raw
            foreach ($match in [regex]::Matches($content, '(?m)^\s{4}(?:\[[^\]]+\])*\[[a-z]+\[\]\]\$([A-Za-z]+)')) {
                $name = $match.Groups[1].Value
                if ($workflowText -notmatch "-$name\b") { continue }   # never handed over: safe
                $checked.Add("$($audit.Name):-$name")
                $pattern = '\$' + $name + '\s*=\s*@\(\$' + $name + '\s*\|'
                if (-not (($content -match $pattern) -or ($module -match $pattern))) {
                    $offender.Add("$($audit.Name): -$name")
                }
            }
        }

        $checked.Count | Should -BeGreaterThan 0 `
            -Because 'a sweep that examines no parameter proves nothing - it must at least find -OnlyCriterion, which every audit declares and every workflow hands over'
        $offender -join '; ' | Should -BeNullOrEmpty `
            -Because 'CI hands an array parameter ONE token, so a script that does not split it receives something nobody wrote - "2,3,6" became layer 2346 (F108)'
    }
}

Describe 'a resource is looked up in the group that actually holds it' {
    # The F20 grant pass searched for the Azure SQL logical server in the PLATFORM resource
    # group. L6 creates it in the DATA resource group. So on every run since it was written
    # the step found nothing and skipped - and the message it printed was
    #
    #   "Could not find an Azure SQL logical server ... L6 has probably not deployed yet"
    #
    # which is plausible, wrong, and the reason nobody chased it for days (F109). The
    # contained-database user was therefore never created, data-api's managed identity had
    # no SQL login, and every /api/tables route on a SQL-backed table answered 502
    # "Login failed for user '<token-identified principal>'" - a failure that was then
    # attributed to a Fabric limitation the SQL tables never touch.
    #
    # The estate's own naming action already knows where everything lives. A workflow that
    # hardcodes a resource group for a lookup is asserting a layout it does not own; a
    # workflow that reads the wrong OUTPUT is doing the same thing more quietly.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'looks for the Azure SQL server in the data resource group, where L6 puts it' {
        $l7 = Get-Content -LiteralPath (Join-Path $script:Root '.github/workflows/layer-07-apps.yml') -Raw
        # The lookup and every call chained off it must use the same group.
        $l7 | Should -Match 'az sql server list --resource-group \$env:RG_DATA' `
            -Because 'L6 creates the logical server in the data resource group; searching the platform group finds nothing and skips silently'
        $l7 | Should -Not -Match 'az sql (server|db) (list|show) --resource-group \$env:RG_PLATFORM' `
            -Because 'a SQL lookup against the platform group cannot succeed, and its "not deployed yet" message is convincing enough to stop anyone looking further'
    }

    It 'confirms the template really does put the SQL server in the data resource group' {
        # The premise. If it ever moves, the check above becomes the wrong assertion, and
        # this one says so rather than the two drifting apart silently.
        #
        # Note where this reads: the TEMPLATE, not the workflow. The first version of this
        # test grepped layer-06-platform.yml, which never names the group - the same
        # mistake as the finding itself, made while writing the check for it. The Bicep
        # template is what actually decides.
        $template = Get-Content -LiteralPath (Join-Path $script:Root 'infra/bicep/platform/main.bicep') -Raw
        $template | Should -Match '(?i)mls-rg-data\s*:\s*Azure SQL logical server' `
            -Because 'this test asserts where the server lives, so it must fail if that stops being true'
    }
}

Describe 'a PowerShell file with non-ASCII content carries its BOM' {
    # provision-workspace.ps1 lost its byte-order mark in an edit and failed CI with
    # PSUseBOMForUnicodeEncodedFile. The file's em-dashes were pre-existing and harmless;
    # what changed was the BOM, silently, because almost no editor shows one.
    #
    # It matters beyond the linter: Windows PowerShell 5.1 reads a BOM-less file as ANSI,
    # so every non-ASCII character in it becomes mojibake - in a repository whose comments
    # carry most of its reasoning. CLAUDE.md targets pwsh 7, but this repo is cloned by
    # strangers onto machines nobody here controls.
    #
    # Cheap to check, invisible to review, and it has now happened twice.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'writes a BOM on every .ps1/.psm1 that contains non-ASCII characters' {
        $checked = 0
        $offender = [System.Collections.Generic.List[string]]::new()
        $files = @(Get-ChildItem -Path $script:Root -Include '*.ps1', '*.psm1' -Recurse -File |
                Where-Object { $_.FullName -notlike '*node_modules*' -and $_.FullName -notlike '*\.git\*' })

        foreach ($file in $files) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            if ($bytes.Length -lt 1) { continue }
            $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
            if ($hasBom) { continue }
            # Only files that actually need one: pure ASCII is fine without.
            if (-not ($bytes | Where-Object { $_ -gt 127 })) { continue }
            $checked++
            $offender.Add($file.FullName.Substring($script:Root.Length + 1))
        }

        $files.Count | Should -BeGreaterThan 20 `
            -Because 'the sweep must actually find the PowerShell in this repo; finding almost none means the glob is broken'
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'PSScriptAnalyzer fails the build on this, and Windows PowerShell 5.1 reads a BOM-less file as ANSI - turning every non-ASCII character into mojibake'
    }
}
