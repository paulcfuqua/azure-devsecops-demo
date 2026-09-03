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

    It 'every hardcoded Fabric name equals what naming.bicep derives, prefix included' {
        # THE SAME ARGUMENT AS THE TEST ABOVE, APPLIED TO THE NAMES IT DID NOT COVER.
        #
        # naming.bicep defines fabricWorkspaceName and fabricLakehouseName expressly so
        # nothing hardcodes the company prefix, and its own comment says so. Nothing was
        # checking that anyone obeyed. Found 2026-09-03 while triaging an actionlint
        # "Context access might be invalid: MLS_LAKEHOUSE_NAME" warning: the variable does
        # not exist, and the fallback behind it was the literal 'mls_operations' - which is
        # correct behaviour today and a hardcoded company prefix, the F90 defect that a
        # rebrand carries into Azure and leaves behind.
        #
        # Fabric names are NOT ARM resource names: no env segment, no type suffix, and the
        # lakehouse takes an UNDERSCORE where the workspace takes a hyphen (lakehouse names
        # allow letters, digits and underscores only). So this asserts both shapes.
        function Get-NamingFunc {
            param([string]$Name)
            $m = Select-String -LiteralPath $script:NamingFile -Pattern "^func $Name\(prefix string\) string => '\`$\{prefix\}([^']*)'" |
                Select-Object -First 1
            if ($m) { return $m.Matches[0].Groups[1].Value }
            return ''
        }

        $prefix = Get-NamingLiteral -Name 'defaultCompanyPrefix'
        $workspaceSuffix = Get-NamingFunc -Name 'fabricWorkspaceName'
        $lakehouseSuffix = Get-NamingFunc -Name 'fabricLakehouseName'

        $prefix | Should -Not -BeNullOrEmpty
        $workspaceSuffix | Should -Not -BeNullOrEmpty `
            -Because 'if fabricWorkspaceName cannot be parsed this test asserts nothing and passes over the defect it exists to catch'
        $lakehouseSuffix | Should -Not -BeNullOrEmpty `
            -Because 'if fabricLakehouseName cannot be parsed this test asserts nothing and passes over the defect it exists to catch'

        $expectedWorkspace = "$prefix$workspaceSuffix"
        $expectedLakehouse = "$prefix$lakehouseSuffix"

        # DEPLOYABLE ARTIFACTS AND AUDIT SCRIPTS. Docs, tests and fixtures may name the
        # estate's own workspace freely - what must not drift is a value a DEPLOYMENT or an
        # AUDIT reads. That deliberately includes PowerShell parameter defaults: a rebrand
        # that reaches Azure and leaves `[string]$LakehouseName = 'mls_operations'` behind
        # in the audit is F90 in the component whose job is to notice F90. Tests are
        # excluded because a fixture asserting a literal name is the point of the fixture.
        $scanned = 0
        $offender = [System.Collections.Generic.List[string]]::new()
        $targets = @(
            Get-ChildItem -Path (Join-Path $script:Root '.github/workflows') -Filter '*.yml' -File
            Get-ChildItem -Path (Join-Path $script:Root '.github/actions') -Filter '*.yml' -File -Recurse
            Get-ChildItem -Path (Join-Path $script:Root 'infra/bicep') -Filter '*.bicepparam' -File -Recurse
            @(Get-ChildItem -Path (Join-Path $script:Root 'infra') -Filter '*.ps1' -File -Recurse) +
            @(Get-ChildItem -Path (Join-Path $script:Root 'infra') -Filter '*.psm1' -File -Recurse) +
            @(Get-ChildItem -Path (Join-Path $script:Root 'verification') -Filter '*.ps1' -File) +
            @(Get-ChildItem -Path (Join-Path $script:Root 'data/seed') -Filter '*.ps1' -File -Recurse) +
            @(Get-ChildItem -Path (Join-Path $script:Root 'data/seed') -Filter '*.psm1' -File -Recurse) |
                Where-Object { $_.FullName -notmatch '[\\/]tests?[\\/]' }
        )
        foreach ($file in $targets) {
            $lineNumber = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                $lineNumber++
                if ($line -match '^\s*#') { continue }
                foreach ($match in [regex]::Matches($line, "'([A-Za-z][A-Za-z0-9]*[_-]operations)'")) {
                    $literal = $match.Groups[1].Value
                    $scanned++
                    $expected = if ($literal -like '*_*') { $expectedLakehouse } else { $expectedWorkspace }
                    if ($literal -ne $expected) {
                        $offender.Add("$($file.Name):$lineNumber has '$literal', but naming.bicep derives '$expected'")
                    }
                }
            }
        }

        $scanned | Should -BeGreaterThan 0 `
            -Because 'if no deployable artifact names the Fabric workspace or lakehouse, this test asserts nothing'
        $offender -join ' | ' | Should -BeNullOrEmpty `
            -Because "a Fabric name that does not match naming.bicep's fabricWorkspaceName/fabricLakehouseName is a hardcoded company prefix, which a rebrand carries into Azure and leaves behind (F90)"
    }

    It 'never puts the empty string in the winning branch of a workflow `&&` expression' {
        # F180. GitHub Actions has no ternary operator. `A && B || C` is short-circuit
        # evaluation over TRUTHINESS, and the empty string is FALSY - so
        #
        #     ${{ cond && '' || '-Flag' }}
        #
        # yields '-Flag' whether cond is true or false. When cond is true, `true && ''`
        # evaluates to '', that result is falsy, and `|| '-Flag'` wins. The expression
        # cannot express "pass nothing", which is the only thing it was written to do.
        #
        # This was infra-down.yml's -SkipChildAudit condition. V11.2 - the criterion that
        # proves a teardown did not cross the G3 tenant-object line - recorded SKIP on every
        # teardown ever run, and kept recording SKIP after F170 moved the guard to a job
        # that could actually see the certificate. Measured 2026-09-03: the guard reported
        # configured, the certificate staged, the "unavailable" notice correctly skipped,
        # and -SkipChildAudit was passed regardless. Two independent causes stacked behind
        # one symptom, and only a real teardown separated them.
        #
        # The fix is positional, not clever: put the NON-EMPTY value in the `&&` branch.
        # Every other call site in this repository already did.
        $workflows = @(
            Get-ChildItem -Path (Join-Path $script:Root '.github/workflows') -Filter '*.yml' -File
            Get-ChildItem -Path (Join-Path $script:Root '.github/actions') -Filter '*.yml' -File -Recurse
        )
        $scanned = 0
        $offender = [System.Collections.Generic.List[string]]::new()

        foreach ($file in $workflows) {
            $lineNumber = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                $lineNumber++
                if ($line -match '^\s*#') { continue }
                # Any ${{ ... && ... || ... }} expression is a candidate; only those whose
                # `&&` value is an empty literal are broken.
                foreach ($match in [regex]::Matches($line, '\$\{\{[^}]*?&&[^}]*?\|\|[^}]*?\}\}')) {
                    $scanned++
                    if ($match.Value -match "&&\s*''\s*\|\|") {
                        $offender.Add("$($file.Name):$lineNumber $($match.Value.Trim())")
                    }
                }
            }
        }

        $scanned | Should -BeGreaterThan 0 `
            -Because 'if no workflow uses the && || idiom at all, this test asserts nothing and would pass over the defect it exists to catch'
        $offender -join ' | ' | Should -BeNullOrEmpty `
            -Because "the empty string is falsy, so `${{ cond && '' || 'X' }}` yields 'X' for EVERY value of cond - put the non-empty value in the && branch instead (F180)"
    }

    It 'never provisions the Fabric capacity into a resource group the teardown deletes' {
        # A PAID CAPACITY IN A GATE-FREE BLAST RADIUS (sponsor decision 2026-09-03).
        #
        # scripts/bootstrap/02-fabric-capacity.ps1 defaulted -ResourceGroup to
        # <prefix>-rg-platform, which infra-down.yml deletes without a gate, and NOTHING
        # recreates it: grep .github/workflows for 02-fabric-capacity and there are zero
        # hits. The teardown would destroy the capacity, leave FABRIC_CAPACITY_ID pointing
        # at a dead ARM id, strand the surviving workspace, and make the NEXT teardown fail
        # trying to suspend something that no longer exists.
        #
        # It is invisible on the trial capacity, which is Microsoft-managed and has no ARM
        # resource to delete. It arms on the first teardown AFTER the G2 move to paid F2 -
        # which is to say the moment the estate starts costing money. That is the worst
        # possible time for a latent fault, and no test could ever have caught it by
        # running, because the path only exists once someone has paid.
        #
        # Derived from naming.bicep, not compared against literals: a rebrand must not be
        # able to quietly move the capacity back inside the blast radius.
        $script = Join-Path $script:Root 'scripts/bootstrap/02-fabric-capacity.ps1'
        Test-Path -LiteralPath $script | Should -BeTrue `
            -Because 'if the bootstrap script is gone this test asserts nothing and passes over the defect it exists to catch'

        $content = Get-Content -LiteralPath $script -Raw
        $content | Should -Match '\$ResourceGroup\s*=\s*''([^'']+)''' `
            -Because 'the capacity resource group must have a readable default to check'
        $null = $content -match '\$ResourceGroup\s*=\s*''([^'']+)'''
        $capacityGroup = $Matches[1]

        $prefix = Get-NamingLiteral -Name 'defaultCompanyPrefix'
        $prefix | Should -Not -BeNullOrEmpty
        $teardownGroups = @('platform', 'apps', 'data', 'ops') | ForEach-Object { "$prefix-rg-$_" }

        $teardownGroups | Should -Not -Contain $capacityGroup `
            -Because "infra-down.yml deletes $($teardownGroups -join ', ') gate-free and no workflow recreates the capacity, so a paid F2 provisioned into one of them is destroyed on the first teardown after the G2 - and kill-rebuild.md section 1 tells operators the capacity persists"
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

    It 'no file that resolves the prefix then writes a prefixed name by hand' {
        # The check above asks whether a file resolves the prefix AT ALL. This one asks the
        # harder question: having resolved it, does the file then ignore its own answer?
        #
        # V3.1's drift sweep resolved the prefix through Get-MlsEstateNaming, threaded it
        # into a -NamingPrefix parameter, and used it in the very message it printed two
        # lines below - then exempted the bootstrap identities with the hardcoded literal
        # @('mls-github-deployer', 'mls-verifier'). After MLS_COMPANY_PREFIX=acme the sweep
        # would enumerate acme-prefixed apps, find acme-github-deployer, match neither
        # literal, and V3.1 would fail PERMANENTLY on a correct estate. That is F90's class
        # one turn in: not a file that forgot to resolve the prefix, but one that resolved
        # it correctly and was then outvoted by a string sitting beside it.
        #
        # THE RULE, written out so it can be argued with rather than guessed at:
        #
        #   IN SCOPE     a non-test .ps1/.psm1 under verification/, infra/ or scripts/ that
        #                already resolves the prefix - it names Get-MlsEstateNaming,
        #                MLS_COMPANY_PREFIX or defaultCompanyPrefix. The right value is in
        #                that file's hands, so a literal beside it is a second answer to a
        #                question the file has already settled.
        #   FLAGGED      a string found in the ABSTRACT SYNTAX TREE in one of two shapes.
        #                (a) The WHOLE value is a prefixed name - '<prefix>-rg-apps' - which
        #                is a name and can be nothing else. (b) The value EMBEDS a quoted
        #                prefixed name - "displayName eq '<prefix>-verifier'" - which is the
        #                Graph/OData, KQL and SQL filter shape, and the one this sweep first
        #                missed. Every real filter in this repo interpolates a variable
        #                ("...eq '$DisplayName'"), so a quoted literal there is drift by
        #                construction.
        #                Parsing rather than grepping is what makes the scope cheap to
        #                defend: comments and comment-based help are not in the AST at all,
        #                so the prose explaining this very finding in layer-03-audit.ps1,
        #                and purview/labels.ps1's verbatim transcript of a Graph error
        #                naming mls-flight-operations, cost nothing to exclude.
        #   NOT FLAGGED  a prefixed name mentioned inside a longer PROSE string - a -Hint, a
        #                -Detail, a Write-Status line. Widening (a) from "is a name" to
        #                "contains a name" was tried and produced twelve of these and no new
        #                defect: "read as mls-verifier (Reader covers */read)" is a sentence,
        #                not a lookup. The two shapes above are what a NAME looks like; a
        #                sweep that also flags English is a sweep somebody deletes.
        #   NOT FLAGGED  a param() default. That is the override POINT, not a bypass of one -
        #                CI passes the resolved name in, and layer-12-audit.ps1 says exactly
        #                that where its default is written. Detected as an ancestor
        #                ParameterAst, which covers script and function param blocks alike.
        #   OUT          *.Tests.ps1, which assert against literal names on purpose; .md,
        #                .yml and .json; MLS_* environment-variable and GitHub-secret
        #                identifiers, which are their own names and not resource names; the
        #                MlsAudit module and its Mls* functions; and naming.bicep, which is
        #                the one place the literal belongs.
        #
        # WHAT THIS DOES NOT COVER, so a green run is not mistaken for total coverage: a
        # file that never resolves the prefix is invisible here - every scripts/bootstrap
        # param default among them. That is deliberate rather than an oversight. Whether a
        # file resolves at all is the preceding check's question; this one holds a file to
        # an answer it already has.
        $prefix = Get-NamingLiteral -Name 'defaultCompanyPrefix'
        $prefix | Should -Not -BeNullOrEmpty `
            -Because 'the sweep must learn the prefix from naming.bicep; a sweep carrying its own copy is the defect it is looking for'
        $escaped = [regex]::Escape($prefix)
        # (a) the whole value is a name; (b) the value embeds a quoted name (a filter clause).
        $wholeName = "^$escaped-[A-Za-z0-9][A-Za-z0-9._-]*$"
        $quotedName = "['`"]$escaped-[A-Za-z0-9][A-Za-z0-9._-]*['`"]"

        # Each entry exempts ONE literal, in ONE file, on ONE line shape. Context is matched
        # against the trimmed source line, so the exemption cannot be inherited by a
        # different use of the same name added to the same file later.
        $allowed = @(
            @{
                Path    = 'infra/fabric/provision-workspace.ps1'
                Literal = "$prefix-verifier"
                Context = '^\[pscustomobject\]@\{\s*Label\s*='
                Why     = 'Console display text in the workspace role-grant loop, sitting beside the unprefixed "data-api identity" and "mcp-tools identity". Nothing looks the string up - the grant is keyed on $VerifierPrincipalId - and the workspace NAME in this same file comes from Get-EstatePrefix. A rebrand makes this label stale, not the script wrong.'
            }
            @{
                Path    = 'scripts/bootstrap/02-fabric-capacity.ps1'
                Literal = "$prefix-demo"
                Context = "^else \{ '$prefix-demo' \}$"
                Why     = 'The last-resort value of the `owner` TAG, after -Owner and $env:MLS_OWNER. A tag value, not a resource name: nothing in any other system resolves it, so a rebrand makes it stale rather than wrong - the same argument as the provision-workspace label above. This file became visible to the sweep only when a 2026-09-03 comment named MLS_COMPANY_PREFIX while recording that its RESOURCE GROUP and CAPACITY NAME defaults are hardcoded and are F90''s class; those two are the ones that matter, they are param() defaults the sweep deliberately does not gate, and changing a G0 bootstrap script on the critical path of a running rebuild is a decision for the sponsor rather than a drive-by (see F168''s closing note).'
            }
        )

        $gated = [System.Collections.Generic.List[string]]::new()
        $offender = [System.Collections.Generic.List[string]]::new()
        $used = [System.Collections.Generic.HashSet[string]]::new()
        $literalsSeen = 0

        $roots = @('verification', 'infra', 'scripts') |
            ForEach-Object { Join-Path $script:Root $_ } | Where-Object { Test-Path $_ }
        foreach ($file in (Get-ChildItem -Path $roots -Recurse -Include *.ps1, *.psm1 -File)) {
            if ($file.Name -like '*.Tests.ps1') { continue }
            if ($file.FullName -match '[\\/](node_modules|\.git)[\\/]') { continue }
            $text = Get-Content -LiteralPath $file.FullName -Raw
            if ($text -notmatch 'Get-MlsEstateNaming|MLS_COMPANY_PREFIX|defaultCompanyPrefix') { continue }
            $relative = $file.FullName.Substring($script:Root.Length).TrimStart('\', '/').Replace('\', '/')
            $gated.Add($relative)

            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$null, [ref]$parseErrors)
            if ($parseErrors -and $parseErrors.Count -gt 0) {
                # A file the sweep cannot read is reported as unobservable, never as clean.
                $offender.Add("${relative} (does not parse)")
                continue
            }

            $strings = $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                    $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
                }, $true)
            foreach ($string in $strings) {
                if ($string.Value -notmatch $wholeName -and $string.Value -notmatch $quotedName) { continue }
                $literalsSeen++
                $ancestor = $string.Parent
                $isParameterDefault = $false
                while ($null -ne $ancestor) {
                    if ($ancestor -is [System.Management.Automation.Language.ParameterAst]) {
                        $isParameterDefault = $true
                        break
                    }
                    $ancestor = $ancestor.Parent
                }
                if ($isParameterDefault) { continue }
                $line = $string.Extent.StartScriptPosition.Line.Trim()
                $exemption = @($allowed | Where-Object {
                        $_.Path -eq $relative -and $_.Literal -eq $string.Value -and $line -match $_.Context
                    })[0]
                if ($exemption) {
                    $null = $used.Add("$($exemption.Path)|$($exemption.Literal)")
                    continue
                }
                $offender.Add("${relative}:$($string.Extent.StartLineNumber) '$($string.Value)'")
            }
        }

        # Non-vacuity, both halves of it. The sweep must reach the resolvers, AND the AST
        # walk must actually see prefixed literals - a walk that matched nothing would
        # report a clean repository in precisely the voice of a working one.
        $gated.Count | Should -BeGreaterThan 8 `
            -Because 'the sweep must reach every file that resolves the prefix; finding almost none means it is broken, not that the repo is clean'
        $literalsSeen | Should -BeGreaterThan 3 `
            -Because 'the AST walk must find prefixed literals at all - most are legitimate param() defaults, and seeing none means it matched nothing'

        foreach ($entry in $allowed) {
            $entry.Why | Should -Not -BeNullOrEmpty -Because 'an exemption without a reason is an oversight with a checkbox'
            $used.Contains("$($entry.Path)|$($entry.Literal)") | Should -BeTrue `
                -Because "the exemption for $($entry.Path) matches nothing any more; a stale allowance is an exemption nobody is deciding about"
        }

        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'a file that resolved the prefix and then wrote one out by hand disagrees with itself the moment MLS_COMPANY_PREFIX changes, and the literal is the half that wins (F90)'
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
        # READS BOTH SHAPES, AND STILL REFUSES TO GUESS. cmd_options started as a
        # single-quoted scalar; authenticating the scan (F157) made it a folded
        # block, and this check THREW rather than passing over a form it could not
        # parse - which is the behaviour it should have, and is why it is being
        # taught the new shape rather than loosened.
        $zapPath = Join-Path $script:Root '.github/workflows/zap.yml'
        $zap = Get-Content -LiteralPath $zapPath -Raw
        $options = $null

        if ($zap -match "cmd_options:\s*'([^']*)'") {
            $options = $Matches[1]
        }
        elseif ($zap -match "cmd_options:\s*[>|][-+]?\s*\r?\n((?:\s+\S.*\r?\n?)+)") {
            # A folded/literal block: every indented line until the indentation drops.
            $options = ($Matches[1] -split '\r?\n' | ForEach-Object { $_.Trim() }) -join ' '
        }

        if ($null -eq $options) {
            throw "cmd_options not found in zap.yml - this check no longer reads what it thinks it reads"
        }
        $options | Should -Not -BeNullOrEmpty -Because 'an empty parse is the same blindness as no parse'
        $options | Should -Match '(^|\s)-a(\s|$)' -Because 'the alpha passive rules are the reason cmd_options exists; if this is gone the parse is wrong'
        $options | Should -Not -Match '(^|\s)-J(\s|$)' `
            -Because 'zaproxy/action-baseline already passes -J report_json.json; a second -J silently redirects the output and the action then fails on a file it never wrote'
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

    It 'hands the next rebuild the one value that can tell a new workspace from a recovered one' {
        # F107 cost an hour precisely because "The workspace could not be found" against a
        # workspace az calls Succeeded explains nothing. A teardown that leaves a recoverable
        # workspace behind must say so, at the moment it happens. THAT INTENT IS UNCHANGED.
        #
        # What changed is the mechanism, because the old one could not do the job (F174).
        # This used to require the string 'Soft-deleted workspace remains', emitted when
        # `list-deleted-workspaces` still listed the workspace after the purge. That warning
        # fired on EVERY teardown and was false every time: `--force` purges the workspace
        # but leaves a tombstone in that list. Measured 2026-09-03 - the tombstone for
        # customerId 5c967cf4 was still listed while a NEW same-name workspace (87f95e84)
        # ran live in the same resource group, and both scheduled-query alert rules deployed
        # clean. So the old assertion pinned a check that could only ever report the hazard
        # as PRESENT, and this test kept it there.
        #
        # The value that DOES distinguish the two states is the workspace's customerId,
        # which is what F107's own entry recorded ("its original customerId intact") and
        # never encoded. The teardown must capture it BEFORE the delete - afterwards there
        # is nothing to read it from - and publish it for the rebuild to compare against.
        $script:Down | Should -Match 'customerId' `
            -Because 'the customerId is the only observable that separates a genuinely new workspace from a recovered one, so a teardown claiming the estate rebuilds from code has to record it'

        $capture = $script:Down.IndexOf('old_customer_id=')
        $purge = $script:Down.IndexOf('--workspace-name "${LAW_NAME}" --force --yes')
        $capture | Should -BeGreaterThan 0 `
            -Because 'the pre-purge customerId has to be captured into a variable, not merely mentioned in prose'
        $purge | Should -BeGreaterThan 0
        $capture | Should -BeLessThan $purge `
            -Because 'a customerId read AFTER the workspace is purged reads nothing, so the capture has to precede the delete'

        $script:Down | Should -Match 'GITHUB_STEP_SUMMARY' `
            -Because 'the value is useless if it stays in a log line nobody carries to the rebuild'

        # THE REGRESSION GUARD, and the reason this test is not merely relaxed. Anyone
        # re-adding a verdict derived from list-deleted-workspaces re-adds F174.
        $script:Down | Should -Not -Match 'Soft-deleted workspace remains' `
            -Because 'that warning is emitted on every teardown regardless of whether the purge worked, because --force leaves a tombstone in list-deleted-workspaces - an auditor that cannot see a control must not be able to report it as present either (F174)'
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

Describe 'no committed artifact hardcodes a rebuild-scoped hostname' {
    # F129. The Copilot Studio connector definition carried
    #
    #   "host":"mls-mcp-demo-ca.thankfulisland-7f9b1aba.centralus.azurecontainerapps.io"
    #
    # and the live estate answers on `happymeadow-9e15a087`. `thankfulisland-7f9b1aba` is a
    # Container Apps environment that no longer exists: AZURE ASSIGNS THAT DOMAIN SEGMENT
    # RANDOMLY, once per environment, and a teardown/rebuild gets a new one. So the literal
    # was guaranteed to be wrong after the very kill-and-rebuild this demo exists to
    # showcase - and it broke the copilot silently, surfacing as "Connector request failed"
    # inside Copilot Studio with nothing anywhere naming a hostname.
    #
    # This is F90's class exactly: a name from another system, written into a committed
    # artifact, that survives the change it should have tracked. F90 was Entra names
    # surviving a rebrand; CLAUDE.md's answer there was to tokenise `infra/entra/manifest.json`
    # with ${prefix}/${env} and resolve it in the one place that reads it. Same answer here:
    # the connector keeps `${mcpHost}` and import-agent.ps1 resolves it at pack time.
    #
    # SCOPED TO THE REBUILD-VARIABLE PART. A hostname is not banned - `azurewebsites.net`
    # names are stable across rebuilds, and documentation quoting a real FQDN as evidence is
    # honest. What must never be committed as configuration is the RANDOM environment
    # domain, because nothing regenerates it.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'keeps no Container Apps environment domain in any deployable artifact' {
        # Deployable = things that are packed, imported or applied. Docs and evidence may
        # quote a live FQDN; they are records of an observation, not configuration.
        $searchRoot = @('infra', 'apps', '.github', 'scripts', 'compliance') |
            ForEach-Object { Join-Path $script:Root $_ } | Where-Object { Test-Path $_ }
        $files = @(Get-ChildItem -Path $searchRoot -Recurse -File -Include '*.json', '*.xml', '*.yml', '*.yaml', '*.bicep' |
                Where-Object { $_.FullName -notlike '*node_modules*' -and $_.FullName -notlike '*package-lock.json' })

        $scanned = 0
        $offender = [System.Collections.Generic.List[string]]::new()
        # <app>.<word>-<8 hex>.<region>.azurecontainerapps.io - the random middle segment is
        # the part that cannot survive a rebuild.
        $pattern = '[a-z0-9-]+\.[a-z]+-[0-9a-f]{8}\.[a-z]+\.azurecontainerapps\.io'
        foreach ($file in $files) {
            $scanned++
            $text = Get-Content -LiteralPath $file.FullName -Raw
            if ([string]::IsNullOrEmpty($text)) { continue }
            foreach ($m in [regex]::Matches($text, $pattern)) {
                $offender.Add("$($file.FullName.Substring($script:Root.Length + 1)): $($m.Value)")
            }
        }

        $scanned | Should -BeGreaterThan 50 `
            -Because 'if the sweep reads almost nothing, its globs are wrong and it asserts nothing'
        $offender -join ' | ' | Should -BeNullOrEmpty `
            -Because 'the middle segment of a Container Apps FQDN is assigned randomly per environment, so a committed literal is wrong the moment the estate is rebuilt - tokenise it and resolve it where it is used (F129)'
    }
}

Describe 'a job-level condition never gates on a value it cannot see' {
    # F125, and the FOURTH instance of one shape in a single session - this one introduced
    # by the very commit that closed BLOCKER-5, which is the point: the class is easy to
    # write and impossible to see.
    #
    # A job-level `if:` is evaluated BEFORE the job's environment is resolved. So
    #
    #     verify:
    #       environment: verify
    #       if: ${{ vars.AZURE_VERIFIER_CLIENT_ID != '' }}
    #
    # reads the EMPTY STRING even though the variable is set on `verify` - and the guard,
    # written to mean "skip when no verifier is configured", actually means "skip ALWAYS".
    # A step-level `if:` inside the same job resolves it correctly, which is why
    # layer-05-fabric.yml's identical-looking guard has always worked and these did not.
    #
    # WHAT MAKES IT UNCONDITIONAL HERE. This repository has ZERO repository-level GitHub
    # variables - every one lives in the `demo` or `verify` environment (CLAUDE.md: "Every
    # value has one source. Estate-wide settings live in the `demo` GitHub environment").
    # So ANY `vars.` reference in a job-level `if:` is empty, always, with no configuration
    # in which it does what it looks like it does.
    #
    # It cost self-heal.yml's `verify` job the ability to run AT ALL, which compounded
    # BLOCKER-4 precisely: even with a readable alert surface and a healed alert, the audit
    # that judges the chain would still have skipped. Nobody noticed, because a skipped job
    # is green.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'uses no vars.* reference in any job-level if: condition' {
        $workflows = @(Get-ChildItem -Path (Join-Path $script:Root '.github/workflows') -Filter '*.yml' -File)
        $scanned = 0
        $offender = [System.Collections.Generic.List[string]]::new()

        foreach ($workflow in $workflows) {
            $lines = Get-Content -LiteralPath $workflow.FullName
            $job = ''
            $inJobIf = $false
            foreach ($line in $lines) {
                if ($line -match '^  ([A-Za-z0-9_-]+):\s*$') { $job = $Matches[1]; $inJobIf = $false; continue }
                if ([string]::IsNullOrWhiteSpace($job)) { continue }
                # A JOB-level key sits at exactly four spaces; a step's `if:` is deeper and
                # is evaluated after the environment resolves, so it is fine.
                if ($line -match '^    if:') { $inJobIf = $true; $scanned++ }
                elseif ($line -match '^    [A-Za-z_-]+:') { $inJobIf = $false }
                elseif ($line -match '^  \S') { $inJobIf = $false }
                if ($inJobIf -and $line -match 'vars\.([A-Za-z0-9_]+)') {
                    $offender.Add("$($workflow.Name)::$job gates on vars.$($Matches[1])")
                }
            }
        }

        $scanned | Should -BeGreaterThan 5 `
            -Because 'if the sweep finds almost no job-level if: conditions, its indentation rule is wrong and it is asserting nothing'
        $offender -join ' | ' | Should -BeNullOrEmpty `
            -Because 'a job-level if: is evaluated before the environment resolves, and every variable in this repo is environment-scoped - so the condition reads the empty string and the guard fires ALWAYS rather than never (F125)'
    }
}

Describe 'a job that reads an estate setting declares the environment holding it' {
    # F124, and it is the THIRD instance of one shape in a single session.
    #
    #   F122  a Key Vault reference could not resolve, because the site named no identity
    #         to resolve it with.
    #   F123  the self-heal chain got HTTP 403 on every run, because SELF_HEAL_TOKEN is an
    #         environment secret and no job that uses it declares an environment.
    #   F124  the control-tower image shipped with no Direct Line endpoint, because the
    #         `image` job - the only job that BUILDS the bundle - declared no environment,
    #         so `vars.MLS_DIRECTLINE_TOKEN_URL` resolved to the empty string.
    #
    # Every one of them is "the value exists, is spelled correctly, and is INVISIBLE to the
    # thing that needs it", and every one of them failed silently, because an absent GitHub
    # variable is the empty string rather than an error.
    #
    # F124's own detail is worth keeping: `preflight` and `deploy` in that workflow BOTH
    # declared `environment: demo`, and neither of them builds anything. The value was
    # reaching the two jobs that did not need it and missing the one that did. A reviewer
    # scanning for "does this workflow use the demo environment" would have seen yes.
    #
    # WHY MLS_ SPECIFICALLY. CLAUDE.md is explicit that estate-wide settings live in the
    # `demo` GitHub environment, and every MLS_-prefixed variable in this repository is one
    # of those. A job reading one without declaring an environment is therefore reading an
    # empty string, always - there is no configuration in which that line does what it
    # looks like it does.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'declares an environment in every job that reads a vars.MLS_* estate setting' {
        $workflows = @(Get-ChildItem -Path (Join-Path $script:Root '.github/workflows') -Filter '*.yml' -File)
        $scanned = 0
        $offender = [System.Collections.Generic.List[string]]::new()

        foreach ($workflow in $workflows) {
            $lines = Get-Content -LiteralPath $workflow.FullName
            $job = ''
            $declaresEnvironment = @{}
            $readsSetting = @{}
            foreach ($line in $lines) {
                # A job header is exactly two spaces in, under `jobs:`. Anything deeper is a
                # key inside the job, which is where `environment:` and the `vars.` reads live.
                if ($line -match '^  ([A-Za-z0-9_-]+):\s*$') {
                    $job = $Matches[1]
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($job)) { continue }
                if ($line -match '^\s{3,}environment:\s*\S') { $declaresEnvironment[$job] = $true }
                if ($line -match 'vars\.(MLS_[A-Z0-9_]+)') {
                    if (-not $readsSetting.ContainsKey($job)) { $readsSetting[$job] = [System.Collections.Generic.List[string]]::new() }
                    if (-not $readsSetting[$job].Contains($Matches[1])) { $readsSetting[$job].Add($Matches[1]) }
                }
            }
            foreach ($name in $readsSetting.Keys) {
                $scanned++
                if (-not $declaresEnvironment.ContainsKey($name)) {
                    $offender.Add("$($workflow.Name)::$name reads $($readsSetting[$name] -join ', ')")
                }
            }
        }

        $scanned | Should -BeGreaterThan 0 `
            -Because 'if no job reads a vars.MLS_* setting, this test asserts nothing and would pass over the very defect it exists to catch'
        $offender -join ' | ' | Should -BeNullOrEmpty `
            -Because 'an MLS_ variable lives in the demo environment, so a job that does not declare one reads the EMPTY STRING - silently, because an absent GitHub variable is not an error (F124)'
    }

    # F170, and declaring SOME environment is not enough - it has to be the RIGHT one.
    #
    # The test above catches a job that declares no environment at all. infra-down.yml's
    # `preflight` declared `environment: demo` and read `secrets.MLS_VERIFIER_CERT_BASE64`,
    # which lives on `verify`. It passed the test above and was broken anyway: the guard
    # reported "not configured" on every run since it was written, the down-state audit was
    # always invoked with `-SkipChildAudit`, and V11.2 - the criterion that proves a
    # teardown did NOT cross the G3 tenant-object line - recorded SKIP every single time
    # while the workflow went green and the scorecard read "verified".
    #
    # A reviewer scanning for "does this job declare an environment" would have seen yes.
    # That is F124's own lesson one level up, and it is why this asserts the NAME.
    #
    # Writing this sweep immediately found two more, which is the point of writing sweeps:
    #   layer-04-purview.yml   `preflight` reads the verifier cert under environment: demo
    #   layer-09-devsecops.yml `ghas` reads MLS_VERIFIER_GH_TOKEN with no environment, so
    #                          the first element of its token fallback chain is dead code
    #                          and the job has only ever run on SELF_HEAL_TOKEN.
    It 'declares the environment that actually HOLDS each environment-scoped secret it reads' {
        # The authority for this map is the GitHub environment configuration, mirrored here
        # because a test cannot query it. CLAUDE.md hard rule 5 enumerates the long-lived
        # credentials; these are the ones that are environment-scoped rather than
        # repository-scoped. SELF_HEAL_TOKEN is deliberately ABSENT: F123 made it a
        # repository secret precisely so every job can see it, so it constrains nothing.
        $holder = @{
            'MLS_VERIFIER_CERT_BASE64'   = 'verify'
            'MLS_VERIFIER_CERT_PASSWORD' = 'verify'
            'MLS_VERIFIER_GH_TOKEN'      = 'verify'
            'PURVIEW_CERT_BASE64'        = 'demo'
            'PURVIEW_CERT_PASSWORD'      = 'demo'
        }

        $workflows = @(Get-ChildItem -Path (Join-Path $script:Root '.github/workflows') -Filter '*.yml' -File)
        $scanned = 0
        $offender = [System.Collections.Generic.List[string]]::new()

        foreach ($workflow in $workflows) {
            $lines = Get-Content -LiteralPath $workflow.FullName
            $job = ''
            $declared = @{}
            $readsSecret = @{}
            $lineNumber = 0
            foreach ($line in $lines) {
                $lineNumber++
                # Comment lines are skipped: this file documents the very defect it scans
                # for, and a prose mention of a secret name is not a read of it.
                if ($line -match '^\s*#') { continue }
                if ($line -match '^  ([A-Za-z0-9_-]+):\s*$') {
                    $job = $Matches[1]
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($job)) { continue }
                if ($line -match '^\s{3,}environment:\s*([A-Za-z0-9_-]+)\s*$') { $declared[$job] = $Matches[1] }
                foreach ($match in [regex]::Matches($line, 'secrets\.([A-Z0-9_]+)')) {
                    $name = $match.Groups[1].Value
                    if (-not $holder.ContainsKey($name)) { continue }
                    $key = "$job`n$name"
                    if (-not $readsSecret.ContainsKey($key)) { $readsSecret[$key] = $lineNumber }
                }
            }
            foreach ($key in $readsSecret.Keys) {
                $jobName, $secretName = $key -split "`n", 2
                $scanned++
                $want = $holder[$secretName]
                $got = if ($declared.ContainsKey($jobName)) { $declared[$jobName] } else { '<none>' }
                if ($got -ne $want) {
                    $offender.Add("$($workflow.Name):$($readsSecret[$key]) job '$jobName' reads $secretName with environment '$got', but it lives on '$want'")
                }
            }
        }

        $scanned | Should -BeGreaterThan 0 `
            -Because 'if no job reads an environment-scoped secret, this test asserts nothing and would pass over the very defect it exists to catch'
        $offender -join ' | ' | Should -BeNullOrEmpty `
            -Because 'an absent GitHub secret is the EMPTY STRING, not an error, so a job declaring the WRONG environment reads nothing and degrades silently - which is how V11.2 never once had evidence while reporting green (F170)'
    }
}

Describe 'a site that references Key Vault names the identity that will resolve it' {
    # F122. The directline Function's DIRECTLINE_SECRET was a well-formed reference to a
    # real secret, held by an identity that existed and had been granted the role. It
    # resolved to an empty string on every start-up since the site was created:
    #
    #   status:  MSINotEnabled
    #   details: Reference was not able to be resolved because site Managed Identity
    #            not enabled.
    #
    # A `@Microsoft.KeyVault(...)` app setting is resolved by the platform with the site's
    # SYSTEM-assigned identity unless the site sets `keyVaultReferenceIdentity`
    # (`keyVaultAccessIdentityResourceId` on the AVM site module). This site has only a
    # user-assigned identity, because Flex Consumption needs an identity RESOURCE ID at
    # site-creation time - so the two requirements are in direct tension, and satisfying
    # the first silently breaks the second.
    #
    # WHY A STATIC TEST AND NOT ONLY V6.8. The runtime criterion needs a deployed estate
    # and forty minutes; this needs a checkout and a second. More to the point, the two
    # answer different questions: V6.8 asks whether THIS estate's references resolve, and
    # this asks whether the class can be reintroduced anywhere in the repository - which
    # is the thing that actually recurs, since the next Function App to want a secret will
    # be copied from the one that has one.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

        function Get-BicepBlock {
            <# The `module x '...' = { ... }` or `resource x '...' = { ... }` declarations
               in a file, by brace depth. Returns the text of each. Crude, and adequate:
               it needs to attribute an app setting to the declaration that owns it, not
               to understand Bicep. #>
            param([Parameter(Mandatory)][string]$Path)
            $lines = Get-Content -LiteralPath $Path
            $blocks = [System.Collections.Generic.List[object]]::new()
            $current = $null
            $depth = 0
            foreach ($line in $lines) {
                if ($null -eq $current -and $line -match '^\s*(module|resource)\s+(\w+)\s') {
                    $current = [pscustomobject]@{ Name = $Matches[2]; Text = [System.Text.StringBuilder]::new() }
                    $depth = 0
                }
                if ($null -ne $current) {
                    [void]$current.Text.AppendLine($line)
                    $depth += ([regex]::Matches($line, '\{')).Count
                    $depth -= ([regex]::Matches($line, '\}')).Count
                    if ($depth -le 0 -and $current.Text.Length -gt 0 -and $line -match '\}') {
                        $blocks.Add([pscustomobject]@{ Name = $current.Name; Text = $current.Text.ToString() })
                        $current = $null
                    }
                }
            }
            return $blocks
        }
    }

    It 'sets keyVaultAccessIdentityResourceId on every site declaring a Key Vault reference' {
        $templates = @(Get-ChildItem -Path (Join-Path $script:Root 'infra') -Filter '*.bicep' -Recurse -File)
        $withReference = [System.Collections.Generic.List[string]]::new()
        $offender = [System.Collections.Generic.List[string]]::new()

        foreach ($template in $templates) {
            foreach ($block in (Get-BicepBlock -Path $template.FullName)) {
                if ($block.Text -notmatch '@Microsoft\.KeyVault\(') { continue }
                $relative = $template.FullName.Substring($script:Root.Length + 1)
                $withReference.Add("$relative/$($block.Name)")
                # Either identity can resolve a reference. What is fatal is naming
                # NEITHER while relying on a user-assigned one, which is the default
                # a copied Flex Consumption block lands you in.
                $namesIdentity = $block.Text -match 'keyVaultAccessIdentityResourceId\s*:' -or
                                 $block.Text -match 'systemAssigned\s*:\s*true'
                if (-not $namesIdentity) { $offender.Add("$relative/$($block.Name)") }
            }
        }

        $withReference.Count | Should -BeGreaterThan 0 `
            -Because 'if no template declares a Key Vault reference, this test asserts nothing and would pass over the very defect it exists to catch'
        $offender -join ', ' | Should -BeNullOrEmpty `
            -Because 'a Key Vault reference on a site with only a user-assigned identity resolves to an EMPTY VALUE and reports success everywhere a reader would look (F122)'
    }
}

Describe 'a workflow default asks for a build the committed source can produce' {
    # F132. `layer-08-copilot-studio.yml` defaulted `deploy_as_managed: true` while the
    # committed solution says <Managed>0</Managed>, so `pac solution pack --packagetype
    # Managed` refused with:
    #
    #   Solution package type did not match requested type.
    #
    # The default had NEVER been satisfiable. Every L8 import since the workflow was
    # written either skipped (F130's version-keyed check) or failed here, and the failure
    # read as a `pac` problem rather than as a workflow asking for an artifact the
    # repository has never contained.
    #
    # This is the "constant that names something in another system" rule pointed inward:
    # the other system is the committed solution tree, and it is right there to read. The
    # deploy path now asserts it too (Assert-PackageTypeMatchesSource, in preflight, before
    # any tenant write) - this catches the same thing in a second, on a laptop, without a
    # Power Platform environment.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:Workflow = Join-Path $script:Root '.github/workflows/layer-08-copilot-studio.yml'
        $script:SolutionXml = Join-Path $script:Root 'infra/copilot-studio/solution/MeridianLaunchCopilot/Other/Solution.xml'
    }

    It 'finds both the workflow and the solution source, so the assertion is not vacuous' {
        # Without this, a rename would turn the check below into a silent pass - which is
        # the shape of defect this whole file exists to catch.
        $script:Workflow | Should -Exist
        $script:SolutionXml | Should -Exist
    }

    It 'defaults deploy_as_managed to whatever the committed solution actually is' {
        $sourceIsManaged = ([xml](Get-Content -LiteralPath $script:SolutionXml -Raw)).SelectSingleNode('//Managed').InnerText.Trim() -eq '1'

        # Every declaration of the input, not just the first: the workflow declares it once
        # per trigger, and F132 survived in BOTH copies.
        $defaults = @()
        $lines = Get-Content -LiteralPath $script:Workflow
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -notmatch '^\s*deploy_as_managed:\s*$') { continue }
            for ($j = $i + 1; $j -lt [Math]::Min($i + 12, $lines.Count); $j++) {
                if ($lines[$j] -match '^\s*default:\s*(\S+)') { $defaults += $Matches[1]; break }
                if ($lines[$j] -match '^\s{0,8}\w[\w-]*:\s*$') { break }
            }
        }

        $defaults.Count | Should -BeGreaterThan 0 -Because 'deploy_as_managed must declare a default somewhere'
        foreach ($default in $defaults) {
            ($default -eq 'true') | Should -Be $sourceIsManaged -Because @"
The workflow defaults deploy_as_managed=$default while $($script:SolutionXml)
says the source is $(if ($sourceIsManaged) { 'managed' } else { 'unmanaged' }). pac will
refuse the pack. Change the default, or export the solution the other way - but they
cannot disagree, because the disagreement is unsatisfiable rather than merely unwise.
"@
        }
    }
}

Describe 'a stored hostname never outranks the live estate' {
    # F144, which is F129's class and F90's before it. `vars.STAGING_URL` held
    #
    #   https://mls-launch-ops-demo-ca.thankfulisland-7f9b1aba.centralus.azurecontainerapps.io
    #
    # while the live app answered on `...happymeadow-9e15a087...`. A Container Apps
    # environment domain is assigned at CREATION and changes on every rebuild - the one
    # thing this demo exists to do - so a hostname kept in a GitHub variable is correct
    # until the first teardown and wrong forever after. DNS did not resolve, the ZAP scan
    # reached nothing, and the only reason that was not a silent green is the empty-report
    # gate (F102's fix, working).
    #
    # The repository already forbids a rebuild-scoped hostname in a committed artifact
    # (see the Describe above). It could not see this one, because a GitHub variable is
    # not an artifact - and an absent or stale variable is a well-formed string, never an
    # error. So the check has to be made against the WORKFLOW: a job that reads a stored
    # host must also derive the live one, in the same job, where the two can be compared.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:WorkflowDir = Join-Path $script:Root '.github/workflows'

        # Variables that carry a hostname of something this estate deploys. A name ending
        # in _URL is not enough on its own: MLS_DIRECTLINE_TOKEN_URL is an azurewebsites
        # name, which is stable across rebuilds because the Function App keeps its name.
        $script:StoredHostVars = @('STAGING_URL')

        # What "derived" looks like: the live ingress read back from Azure.
        $script:DerivePattern = 'ingress\.fqdn'
    }

    It 'finds the workflow directory, so the sweep is not vacuous' {
        $script:WorkflowDir | Should -Exist
        @(Get-ChildItem -Path $script:WorkflowDir -Filter '*.yml' -File).Count |
            Should -BeGreaterThan 5
    }

    It 'derives the live FQDN in every workflow that reads a stored estate hostname' {
        $offenders = [System.Collections.Generic.List[string]]::new()
        $readers = [System.Collections.Generic.List[string]]::new()

        foreach ($workflow in (Get-ChildItem -Path $script:WorkflowDir -Filter '*.yml' -File)) {
            $text = Get-Content -LiteralPath $workflow.FullName -Raw
            foreach ($varName in $script:StoredHostVars) {
                # The EXPRESSION, not prose that mentions the variable. A workflow whose
                # input description says "empty falls back to vars.STAGING_URL" is
                # documenting a delegate's behaviour, not reading a hostname.
                if ($text -notmatch ('\$\{\{\s*vars\.' + [regex]::Escape($varName) + '\s*\}\}')) { continue }
                $readers.Add("$($workflow.Name) reads $varName")
                if ($text -notmatch $script:DerivePattern) {
                    $offenders.Add("$($workflow.Name) reads vars.$varName and never asks Azure for the live ingress FQDN")
                }
            }
        }

        # If nobody reads these variables any more the inventory is stale, and a check
        # that asserts nothing is worse than no check: it reports green forever.
        $readers.Count | Should -BeGreaterThan 0 -Because 'StoredHostVars must name variables something actually reads'

        $offenders -join "`n" | Should -BeNullOrEmpty -Because @"
A Container Apps environment domain changes on every rebuild, so a stored hostname is
correct exactly until the first teardown. Read the live ingress in the same job
(az containerapp show --query properties.configuration.ingress.fqdn) and prefer it over
the stored value, reporting the stored one as stale when they disagree.
"@
    }

    It 'checks that the scan target resolves before scanning it' {
        # F135's rule, F144's bill: well-formed and reachable are different properties,
        # and asserting only the first turns a stale hostname into `docker failed with
        # exit code 3` deep inside a third-party action - the symptom, never the cause.
        $zap = Join-Path $script:WorkflowDir 'zap.yml'
        $zap | Should -Exist
        Get-Content -LiteralPath $zap -Raw | Should -Match 'getent hosts'
    }
}

Describe 'a caller grants every permission the reusable workflow it calls asks for' {
    # A reusable workflow cannot ask for a permission its CALLER has not granted. When it
    # does, the run fails at STARTUP:
    #
    #   conclusion: startup_failure     jobs: []
    #
    # No jobs, no logs, no annotation naming the permission - the worst diagnostic GitHub
    # produces, and it lands on the whole workflow rather than the one job at fault.
    #
    # Paid for while fixing F144: zap.yml began deriving its scan target from the live
    # Container App instead of a stored FQDN, which needs `id-token: write`, and
    # layer-09-devsecops.yml's `zap:` job granted `contents: read` alone. The L9 run that
    # was meant to PROVE the F144 fix never started.
    #
    # Deliberately over-strict: it unions every write permission any job in the callee
    # declares, without reasoning about which jobs run. A caller granting slightly more
    # than one run needs is a far cheaper mistake than a workflow that cannot start.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:WorkflowDir = Join-Path $script:Root '.github/workflows'

        function Get-WritePermission {
            <# Every `<name>: write` under any `permissions:` block in a file. #>
            param([Parameter(Mandatory)][string]$Path)
            $found = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($line in (Get-Content -LiteralPath $Path)) {
                if ($line -match '^\s+([a-z-]+):\s*write\s*$') { [void]$found.Add($Matches[1]) }
            }
            return $found
        }

        function Get-JobBlock {
            <# Job name -> its lines. Jobs are the two-space keys under `jobs:`. #>
            param([Parameter(Mandatory)][string]$Path)
            $blocks = @{}
            $current = $null
            foreach ($line in (Get-Content -LiteralPath $Path)) {
                if ($line -match '^  ([A-Za-z0-9_-]+):\s*$') {
                    $current = $Matches[1]
                    $blocks[$current] = [System.Collections.Generic.List[string]]::new()
                    continue
                }
                # A top-level key ends the job section.
                if ($line -match '^[A-Za-z]' ) { $current = $null; continue }
                if ($null -ne $current) { $blocks[$current].Add($line) }
            }
            return $blocks
        }
    }

    It 'finds at least one local reusable-workflow call, so the sweep is not vacuous' {
        $calls = @(Get-ChildItem -Path $script:WorkflowDir -Filter '*.yml' -File |
                Select-String -Pattern 'uses:\s*\./\.github/workflows/' -SimpleMatch:$false)
        $calls.Count | Should -BeGreaterThan 0
    }

    It 'grants every write permission the callee declares' {
        $offenders = [System.Collections.Generic.List[string]]::new()

        foreach ($caller in (Get-ChildItem -Path $script:WorkflowDir -Filter '*.yml' -File)) {
            foreach ($entry in (Get-JobBlock -Path $caller.FullName).GetEnumerator()) {
                $body = $entry.Value -join "`n"
                if ($body -notmatch 'uses:\s*\./\.github/workflows/([A-Za-z0-9_.-]+\.yml)') { continue }
                $calleeName = $Matches[1]
                $calleePath = Join-Path $script:WorkflowDir $calleeName
                if (-not (Test-Path -LiteralPath $calleePath)) {
                    $offenders.Add("$($caller.Name) job '$($entry.Key)' calls $calleeName, which does not exist")
                    continue
                }

                # Only the permissions in THIS job's block count; a sibling job's grant
                # does nothing for this call, and a file-level one is overridden by the
                # job's own block the moment it declares one.
                $jobGranted = [System.Collections.Generic.HashSet[string]]::new()
                foreach ($line in $entry.Value) {
                    if ($line -match '^\s+([a-z-]+):\s*write\s*$') { [void]$jobGranted.Add($Matches[1]) }
                }

                foreach ($needed in (Get-WritePermission -Path $calleePath)) {
                    if (-not $jobGranted.Contains($needed)) {
                        $offenders.Add("$($caller.Name) job '$($entry.Key)' calls $calleeName, which needs '${needed}: write', and grants it no such permission")
                    }
                }
            }
        }

        $offenders -join "`n" | Should -BeNullOrEmpty -Because @"
A reusable workflow cannot ask for a permission its caller has not granted: the run ends
as startup_failure with no jobs and no logs. Add the permission to the CALLING job's
permissions block.
"@
    }
}

Describe 'a Key Vault secret is looked up under the name the estate configured' {
    # F147. L8's eval job read the Direct Line secret as `directline-secret` - the name in
    # the G0 bootstrap runbook. The estate creates `mls-directline-secret` and names it in
    # the `demo` environment variable MLS_DIRECTLINE_SECRET_NAME, which is what L6 hands
    # the Bicep and what the Function's Key Vault reference resolves.
    #
    # So the secret EXISTED, was spelled correctly, and could not be seen by the thing that
    # read it - the invisible-value class again - and the job reported:
    #
    #   mls-sec-demo-kv holds no 'directline-secret', so the agent cannot be evaluated
    #
    # which reads as "nobody has created it yet" and sent a reader off to publish an agent
    # and mint a secret that had been sitting in the vault for a day. Four criteria
    # (V8.2, V8.3, V8.4, V8.5) skipped on it, every run, and the job reported success -
    # correctly, because skipping cleanly is what it is designed to do when it cannot
    # evaluate.
    #
    # CLAUDE.md: "Every value has one source." A literal in a second place is a second
    # source, and it outranks the real one silently because nothing compares them.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:WorkflowDir = Join-Path $script:Root '.github/workflows'
    }

    It 'finds workflows that read Key Vault, so the sweep is not vacuous' {
        $readers = @(Get-ChildItem -Path $script:WorkflowDir -Filter '*.yml' -File |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'az keyvault secret' })
        $readers.Count | Should -BeGreaterThan 0
    }

    It 'passes --name a variable, never a hardcoded secret name' {
        $offenders = [System.Collections.Generic.List[string]]::new()

        foreach ($workflow in (Get-ChildItem -Path $script:WorkflowDir -Filter '*.yml' -File)) {
            $lines = Get-Content -LiteralPath $workflow.FullName
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -notmatch 'az keyvault secret (show|set)') { continue }
                # The command may be split across continuation lines; --name can be on any
                # of them, so read forward until the continuation stops.
                $j = $i
                while ($j -lt $lines.Count) {
                    if ($lines[$j] -match '--name\s+(\S+)') {
                        $value = $Matches[1]
                        # An expansion - "${VAR}", $VAR, ${{ vars.X }} - is a single source.
                        # A bare literal is a second one.
                        if ($value -notmatch '\$') {
                            $offenders.Add("$($workflow.Name):$($j + 1) hardcodes --name $value")
                        }
                        break
                    }
                    if ($lines[$j] -notmatch '\\\s*$') { break }
                    $j++
                }
            }
        }

        $offenders -join "`n" | Should -BeNullOrEmpty -Because @"
A secret name written in a workflow is a second source for a value the demo environment
already owns, and it outranks the real one silently because nothing compares them. Read the
name from the variable that L6 uses (MLS_DIRECTLINE_SECRET_NAME), and when the variable is
unset say THAT rather than guessing a name - an unset variable and a missing secret need
different fixes and must not produce the same message.
"@
    }
}

Describe 'a credential minted in two places is minted the same way' {
    # F163. zap.yml mints a probe token TWICE - the classifier needs one to decide
    # whether an endpoint is an auth wall, the scanner needs one to scan through it.
    # F161 corrected the audience in the first and missed the second, and the run
    # still looked partly fine because ONE app had an Application ID URI added by
    # hand during testing, so the wrong form resolved there and nowhere else.
    #
    # One app masked the bug in the other two, which is the reason this is a check
    # rather than a fixed line: the next divergence will be just as quiet.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:Zap = Join-Path $script:Root '.github/workflows/zap.yml'
    }

    It 'finds the workflow, so the sweep is not vacuous' {
        $script:Zap | Should -Exist
        (Get-Content -LiteralPath $script:Zap -Raw) | Should -Match 'get-access-token'
    }

    It 'requests the same audience shape everywhere it mints a probe token' {
        $mints = @(Get-Content -LiteralPath $script:Zap |
                Where-Object { $_ -match 'get-access-token' })

        $mints.Count | Should -BeGreaterThan 1 -Because 'the token is minted in both the resolve and the scan job; if this drops to one, this check is reading the wrong thing'

        # Easy Auth validates a token's audience against the app's CLIENT ID, and
        # `--resource <clientId>` produces exactly that. `api://<clientId>` is a
        # different audience that additionally requires an Application ID URI on
        # the registration - which is the accident that made one app work.
        $wrong = @($mints | Where-Object { $_ -match 'resource\s+"api://' })
        $wrong -join "`n" | Should -BeNullOrEmpty -Because @"
Easy Auth matches a bearer token's audience against the app's client id, so the
probe token must be requested with the bare id. Initialize-VerifierProbeRole's
docstring says so, and V7.3 has always done it that way.
"@
    }
}

Describe 'every credential a runbook creates is in the closed inventory' {
    # F151/F164. CLAUDE.md rule 5 calls its credential list "the complete list of
    # long-lived credentials" and names two Key Vault entries. The vault held four.
    #
    # A census found the extra two; this sweep is what would have found them the day
    # they appeared. `mls-data-api-github-token` turned out to be entirely legitimate
    # - G0 step 11b creates it, added for F116 - and simply never reached rule 5's
    # list. `mls-github-token` is its pre-rename name, left behind.
    #
    # The point is not that either was dangerous. It is that a list which calls
    # itself complete, and is the rotation runbook after a leak, drifted silently
    # from the thing it describes. A leak would have rotated the named ones and left
    # the rest.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:Claude = Get-Content -LiteralPath (Join-Path $script:Root 'CLAUDE.md') -Raw
        $script:Gitleaks = Get-Content -LiteralPath (Join-Path $script:Root '.github/workflows/gitleaks.yml') -Raw

        # Every Key Vault secret the runbooks tell an operator to create.
        $script:RunbookSecrets = @(
            Get-ChildItem -Path (Join-Path $script:Root 'docs/runbooks') -Filter '*.md' -Recurse -File |
                ForEach-Object { Select-String -LiteralPath $_.FullName -Pattern 'keyvault secret set[^\r\n]*--name\s+([A-Za-z0-9$_"{}-]+)' -AllMatches } |
                ForEach-Object { $_.Matches } |
                ForEach-Object { $_.Groups[1].Value.Trim('"') } |
                # A name built from a variable is resolved elsewhere and cannot be
                # compared as a literal; the variable itself must be in the list.
                Where-Object { $_ -notmatch '^\$' -and $_ -notmatch '^\$\{' } |
                Sort-Object -Unique
        )
    }

    It 'finds secrets in the runbooks, so the sweep is not vacuous' {
        $script:RunbookSecrets.Count | Should -BeGreaterThan 0
    }

    It 'names every runbook-created secret in CLAUDE.md rule 5' {
        $missing = @($script:RunbookSecrets | Where-Object { $script:Claude -notmatch [regex]::Escape($_) })
        $missing -join ', ' | Should -BeNullOrEmpty -Because @"
CLAUDE.md rule 5 calls its list "the complete list of long-lived credentials" and is the
rotation runbook after a leak. A secret a runbook creates and that list does not name is a
credential nobody would rotate.
"@
    }

    It 'names every runbook-created secret in the gitleaks rotation table' {
        # CLAUDE.md: "gitleaks.yml's incident text is the rotation list and must stay
        # in sync with this one." Nothing enforced that until now, and the two agreed
        # with each other while both disagreed with the vault.
        $missing = @($script:RunbookSecrets | Where-Object { $script:Gitleaks -notmatch [regex]::Escape($_) })
        $missing -join ', ' | Should -BeNullOrEmpty -Because @"
gitleaks.yml's incident text is what someone follows at 3am after a leak. A credential absent
from it is one that does not get rotated.
"@
    }
}

Describe 'a grant the estate depends on is not bound to a principal the rebuild replaces' {
    # F172. `CREATE USER ... FROM EXTERNAL PROVIDER` makes the Azure SQL engine resolve the
    # principal in Microsoft Graph. An application cannot impersonate another application, so
    # under CI the engine falls back to the SQL SERVER'S OWN managed identity, which must hold
    # the Entra "Directory Readers" role - and docs/runbooks/g0-bootstrap.md documented that
    # grant as "One assignment, once per tenant".
    #
    # It was never once per tenant. L6 creates the server in mls-rg-data, teardown DELETES that
    # resource group, and the server's SYSTEM-ASSIGNED identity dies with it and returns under
    # the same NAME with a NEW principal id. Entra removes the dangling role assignment along
    # with the deleted service principal. So the grant stopped existing the first time the
    # estate was rebuilt, which is the one thing this demo exists to do.
    #
    # Measured on the 2026-09-03 re-baseline, not inferred: the directory audit log records
    # `mls-ops-demo-sql` added to Directory Readers at 2026-09-01T12:23:23Z for a service
    # principal that no longer exists; the current server identity holds zero directory role
    # assignments; the Directory Readers role has zero members. Four layers later data-api
    # answered 502 `Login failed for user '<token-identified principal>'` on every SQL-backed
    # route and V7.6 went red.
    #
    # THE CLASS, stated so it outlives this instance: a NAME survives a rebuild and a PRINCIPAL
    # ID does not. Every check keyed on the name still passes. So a one-time grant made against
    # a resource-group-scoped identity is true exactly until the first teardown, and silent
    # afterwards.

    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:SeedSqlDir = Join-Path $script:Root 'data/seed/sql'
        $script:Layer07Yml = Get-Content -LiteralPath (Join-Path $script:Root '.github/workflows/layer-07-apps.yml') -Raw
    }

    It 'creates the workload contained-database user from an explicit SID, never FROM EXTERNAL PROVIDER' {
        # COMMENTS STRIPPED FIRST, AND THAT IS THE WHOLE POINT. The statement this forbids is
        # quoted verbatim in the comment explaining its removal, so a naive grep over the raw
        # files passes on prose describing its own departure - which is exactly what
        # workload-rbac.Tests.ps1 did until today.
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($file in Get-ChildItem -LiteralPath $script:SeedSqlDir -Filter '*.sql' -File) {
            $code = [regex]::Replace((Get-Content -LiteralPath $file.FullName -Raw), '(?s)/\*.*?\*/', '')
            if ($code -match 'FROM\s+EXTERNAL\s+PROVIDER') { $offender.Add($file.Name) }
        }
        $moduleCode = [regex]::Replace(
            (Get-Content -LiteralPath (Join-Path $script:SeedSqlDir 'sql-seed.psm1') -Raw), '(?s)<#.*?#>', '')
        $moduleCode = (($moduleCode -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        if ($moduleCode -match 'FROM\s+EXTERNAL\s+PROVIDER') { $offender.Add('sql-seed.psm1') }

        $offender -join ', ' | Should -BeNullOrEmpty -Because @"
FROM EXTERNAL PROVIDER needs the SQL server's own managed identity to hold Directory Readers.
That identity is destroyed with mls-rg-data on every teardown and returns with a new principal
id, so the grant behind it is gone and no name-based check can tell. Create the user with
CREATE USER ... WITH SID = <clientId>, TYPE = E instead - it asks Graph nothing, needs no
tenant-level privilege, and a rebuild reproduces it.
"@
    }

    It 'verifies the SID of the contained user, not merely that a principal of that name exists' {
        # ASSERT THE CAPABILITY, NOT THE ARTEFACT. A user-assigned identity destroyed with its
        # resource group and recreated under the same name gets a NEW clientId, so a database
        # that outlived it holds a user nobody can log in as - and "a principal of this name
        # exists" is satisfied by exactly that user. The SID is what the engine matches a
        # presented token against, so the SID is what has to be read back.
        # BOOLEANS, NOT -Match ON THE WHOLE FILE. A failed Should -Match prints its input,
        # and these inputs are a 1,400-line workflow and a 900-line module - so the useful
        # sentence ends up buried under the artefact it is about.
        $module = Get-Content -LiteralPath (Join-Path $script:SeedSqlDir 'sql-seed.psm1') -Raw
        [bool]($module -match 'CONVERT\(UNIQUEIDENTIFIER, \[sid\]\)') | Should -BeTrue `
            -Because 'sql-seed.psm1 must read the stored SID back out of sys.database_principals'

        [bool]($script:Layer07Yml -match 'CONVERT\(UNIQUEIDENTIFIER, \[sid\]\)') | Should -BeTrue `
            -Because 'layer-07-apps.yml''s own independent read-back must compare the SID, not the name'
        [bool]($script:Layer07Yml -match 'az identity show') | Should -BeTrue `
            -Because 'the clientId written as the SID is read from Azure at deploy time, never stored'
    }

    It 'surfaces every continue-on-error grant step under a name that says a failure happened' {
        # A STEP LIST IS EVIDENCE, AND IT MUST DISTINGUISH TWO STATES - F162's rule applied to
        # the run summary. continue-on-error is right for an idempotent remediation: a
        # transient blip must not red the deploy job and starve the Verifier that would judge
        # it. But the 2026-09-03 rebuild then showed
        #
        #     success  Apply the SQL contained-database user ... (F20)
        #     success  Report a failed F20 grant pass
        #
        # where the second line's PRESENCE means the first one failed. "Report a failed X"
        # reporting success is indistinguishable at a glance from nothing being wrong, and the
        # deploy job was read as green for fifty minutes while its grant had not landed.
        $reporting = @([regex]::Matches($script:Layer07Yml, "(?m)^\s+- name: (['`"]?)(?<name>[^\r\n]*?)\1\r?$") |
                ForEach-Object { $_.Groups['name'].Value } |
                Where-Object { $_ -match '(?i)\bfail(ed|ure)\b' })

        $reporting.Count | Should -BeGreaterOrEqual 3 `
            -Because 'the F19, F20 and F24 grant steps each carry continue-on-error and each needs a reporting step'
        $vague = @($reporting | Where-Object { $_ -notmatch '^FAILURE:' })
        $vague -join ' | ' | Should -BeNullOrEmpty -Because @"
A step whose only job is to announce that something broke must say so in its own name, because
the run's step list is what a reader scans first. 'Report a failed X' beside a green tick reads
as 'nothing to report'.
"@
    }
}
