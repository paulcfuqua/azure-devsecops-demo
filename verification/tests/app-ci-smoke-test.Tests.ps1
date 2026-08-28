# Regression guard for F22 (compliance/findings/2026-08-26-prepublication-review.md#f22,
# Task 24): every app-*-ci.yml `image` job builds and Trivy-scans the container
# but, before this task, never started it. Nothing curled /healthz before merge;
# the only runtime check was verification/layer-07-audit.ps1, which runs
# post-deployment against a live tenant. That mattered specifically because
# Task 14 hardened both frontend images to run as `USER nginx`, and the failure
# mode is silent rather than loud: a non-writable /etc/nginx/conf.d makes the
# entrypoint skip envsubst templating and serve the STOCK nginx welcome page
# instead of the app. Same class as F5 -- a CI gap meaning something is never
# actually exercised.
#
# WHICH MECHANISM CATCHES THAT (corrected by the Task 24 review; the earlier
# wording here said the untemplated container 404s on /healthz, which is not
# what happens on the wire). apps/control-tower/Dockerfile:55-56 records the
# real fallback: stock nginx serves on PORT 80, and only this app's template
# ever says `listen 8080;`. The smoke step publishes and curls 8080 only, so an
# untemplated image accepts no connection there and the gate fails through the
# poll's bounded-timeout branch. The `^ok ` body discriminator is a second,
# independent guard for every other "something answers 8080 but it is not this
# app" case -- wanted, but not the half that catches F14.
#
# This is a workflow-shape assertion, not an execution test -- GitHub Actions
# `run:` steps have no unit-test harness, so pattern-matching raw file content
# is the available mechanism (same approach as no-secret-outputs.Tests.ps1 and
# self-heal-selection.Tests.ps1). The runtime behaviour itself (does the
# container actually answer correctly) cannot be proven without a Docker
# daemon, which is not available on this dev host -- see the Task 24 report.
#
# Placement is asserted by LINE NUMBER comparison, not mere substring presence:
# the smoke step must sit strictly after "Trivy gate" (so a CRITICAL-vulnerable
# image is never started) and strictly before "Log in to GHCR" (so no registry
# credential has entered the job's environment when the container runs).
#
# Two environment gotchas this file routes around, both confirmed by an actual
# standalone repro rather than assumed (see the Task 24 report):
#   1. Calling a user-defined `function` (or invoking a scriptblock variable
#      via `& $sb`) from inside a Pester It/BeforeAll throws "A 'break' or
#      'continue' statement...escaped from your code" (pester/Pester#2669) in
#      this Pester/PowerShell combination. `grep -rln '^function ' verification/tests`
#      matches only this file before the fix -- no other *.Tests.ps1 here
#      defines one. Fix: plain cmdlets only (Select-String, Get-Content), no
#      helper functions.
#   2. A plain `foreach` loop at Describe-body scope that does
#      `Context "$($item.Name)" { It { ...$item... } }` does NOT close over
#      $item correctly for the It block's RUN phase (it runs later, after the
#      whole foreach has finished, and resolves to an empty/stale value) --
#      proved with Write-Host, not merely suspected, since a naive self
#      -referential assertion (comparing a value derived from $item against
#      another value also derived from $item) cannot tell a broken closure
#      from a correct one. Fix: Pester's native `-ForEach` data-driven Context,
#      which binds each row's keys as real per-iteration variables.

$script:RepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..')).Path
$script:WorkflowDir = Join-Path -Path $script:RepoRoot -ChildPath '.github/workflows'

# One pass per app, at discovery time (top-level script scope, plain cmdlets
# only), building the exact rows `-ForEach` needs below.
$script:AppDefs = @(
    @{ Name = 'control-tower'; File = 'app-control-tower-ci.yml'; Payload = 'nginx-text' }
    @{ Name = 'launch-ops';    File = 'app-launch-ops-ci.yml';    Payload = 'nginx-text' }
    @{ Name = 'data-api';      File = 'app-data-api-ci.yml';      Payload = 'json-data-api' }
    @{ Name = 'mcp-tools';     File = 'app-mcp-tools-ci.yml';     Payload = 'json-mcp-tools' }
    # Task 15: compliance's smoke step follows the same nginx "ok <digest>"
    # convention as control-tower/launch-ops (apps/compliance/nginx.conf.template).
    @{ Name = 'compliance';    File = 'app-compliance-ci.yml';    Payload = 'nginx-text' }
)

$script:Apps = foreach ($def in $script:AppDefs) {
    $path = Join-Path -Path $script:WorkflowDir -ChildPath $def.File

    $smokeHit = Select-String -Path $path -Pattern '^\s*-\s*name:\s*Smoke-test the image' | Select-Object -First 1
    $trivyHit = Select-String -Path $path -Pattern '^\s*-\s*name:\s*Trivy gate' | Select-Object -First 1
    $sarifHit = Select-String -Path $path -Pattern '^\s*-\s*name:\s*Upload the Trivy SARIF' | Select-Object -First 1
    $ghcrHit = Select-String -Path $path -Pattern '^\s*-\s*name:\s*Log in to GHCR' | Select-Object -First 1
    $pushHit = Select-String -Path $path -Pattern '^\s*-\s*name:\s*Push the scanned image' | Select-Object -First 1

    $smokeLine = $null
    if ($smokeHit) { $smokeLine = $smokeHit.LineNumber }
    $trivyLine = $null
    if ($trivyHit) { $trivyLine = $trivyHit.LineNumber }
    $sarifLine = $null
    if ($sarifHit) { $sarifLine = $sarifHit.LineNumber }
    $ghcrLine = $null
    if ($ghcrHit) { $ghcrLine = $ghcrHit.LineNumber }
    $pushLine = $null
    if ($pushHit) { $pushLine = $pushHit.LineNumber }

    $smokeBlock = ''
    if ($smokeLine -and $ghcrLine) {
        # [StartLine-1 .. EndLine-2]: Select-String's LineNumber is 1-indexed;
        # Get-Content's array is 0-indexed; the slice stops BEFORE EndLine's
        # own line so "Log in to GHCR" itself is excluded from the block.
        $fileLines = Get-Content -LiteralPath $path
        $smokeBlock = ($fileLines[($smokeLine - 1)..($ghcrLine - 2)] -join "`n")
    }

    @{
        Name            = $def.Name
        File            = $def.File
        Payload         = $def.Payload
        Path            = $path
        SmokeLine       = $smokeLine
        TrivyGateLine   = $trivyLine
        SarifUploadLine = $sarifLine
        GhcrLoginLine   = $ghcrLine
        PushLine        = $pushLine
        SmokeBlock      = $smokeBlock
    }
}

Describe 'app CI smoke-tests the built container image before merge (F22)' {
    Context '<Name>' -ForEach $script:Apps {
        It 'has a step named "Smoke-test the image ... (F22)" in the image job' {
            $SmokeLine | Should -Not -BeNullOrEmpty
        }

        It 'places the smoke-test step strictly after the Trivy CRITICAL gate' {
            $SmokeLine | Should -BeGreaterThan $TrivyGateLine
        }

        It 'places the smoke-test step strictly after the SARIF upload' {
            $SmokeLine | Should -BeGreaterThan $SarifUploadLine
        }

        It 'places the smoke-test step strictly before "Log in to GHCR" (no registry credential yet)' {
            $SmokeLine | Should -BeLessThan $GhcrLoginLine
        }

        It 'places the smoke-test step strictly before the push step' {
            $SmokeLine | Should -BeLessThan $PushLine
        }

        It 'runs the built image detached (docker run -d)' {
            $SmokeBlock | Should -Match 'docker run -d'
        }

        It 'polls with a bounded retry loop rather than a single sleep-then-curl' {
            $SmokeBlock | Should -Match 'for _ in \$\(seq'
            $SmokeBlock | Should -Match 'sleep'
        }

        It 'caps each probe with its own timeout (curl --max-time)' {
            $SmokeBlock | Should -Match 'curl -s --max-time'
        }

        It 'dumps docker logs on every failure path before exiting' {
            # Every "exit 1" line in the block must be matched by a
            # "docker logs" call -- count occurrences rather than merely
            # asserting "docker logs" appears once somewhere.
            $exitCount = ([regex]::Matches($SmokeBlock, 'exit 1')).Count
            $logsCount = ([regex]::Matches($SmokeBlock, 'docker logs')).Count
            $exitCount | Should -BeGreaterThan 0
            $logsCount | Should -Be $exitCount
        }

        It 'always stops and removes the container via an EXIT trap (cleanup on every path)' {
            $SmokeBlock | Should -Match 'trap\s+cleanup\s+EXIT'
            $SmokeBlock | Should -Match 'docker stop'
            $SmokeBlock | Should -Match 'docker rm'
        }

        It 'is a merge gate, not advisory: no continue-on-error on this step' {
            $SmokeBlock | Should -Not -Match 'continue-on-error'
        }

        It 'sets -euo pipefail' {
            $SmokeBlock | Should -Match 'set -euo pipefail'
        }

        It 'hands the container no secret: no GITHUB_TOKEN, no secrets context, no env-file, no workspace mount' {
            $SmokeBlock | Should -Not -Match 'secrets\.'
            $SmokeBlock | Should -Not -Match 'GITHUB_TOKEN'
            $SmokeBlock | Should -Not -Match '--env-file'
            $SmokeBlock | Should -Not -Match '-v\s'
        }

        It 'asserts HTTP 200 explicitly (not just "curl succeeded")' {
            $SmokeBlock | Should -Match '"\$\{status\}"\s*!=\s*"200"'
        }

        if ($Payload -eq 'nginx-text') {
            It 'asserts the F14 discriminator: GET /healthz and the "ok " body prefix, not a bare 200 on "/"' {
                # The stock nginx welcome page has no /healthz location at
                # all, so it cannot satisfy this even though it would satisfy
                # a bare 200-on-"/" check.
                $SmokeBlock | Should -Match '/healthz'
                $SmokeBlock | Should -Match "\^ok "
            }
        } elseif ($Payload -eq 'json-data-api') {
            It 'asserts the data-api discriminator: .service == "data-api"' {
                $SmokeBlock | Should -Match '\.service\s*==\s*"data-api"'
            }
        } elseif ($Payload -eq 'json-mcp-tools') {
            It 'asserts the mcp-tools discriminator: .ok == true and .transport == "streamable-http"' {
                $SmokeBlock | Should -Match '\.ok\s*==\s*true'
                $SmokeBlock | Should -Match '\.transport\s*==\s*"streamable-http"'
            }
            It 'never checks a "service" field -- mcp-tools'' /healthz has none (unlike data-api''s)' {
                $SmokeBlock | Should -Not -Match '\.service\s*=='
            }
        }
    }

    Context 'mcp-tools-specific interface requirement' -ForEach @(
        $script:Apps | Where-Object { $_.Name -eq 'mcp-tools' }
    ) {
        It 'passes an explicit, non-secret auth opt-out so the container can boot at all (F2 fail-closed gate)' {
            # mcp-tools' loadInboundAuth() throws at startup in every mode
            # unless MCP_AUTH_TOKEN or MCP_ALLOW_UNAUTHENTICATED is set. A bare
            # `docker run` with no flags here would exit immediately and look
            # like an image defect. Either a dummy token or the explicit
            # boolean opt-out satisfies the requirement -- this repo uses the
            # boolean (asserted below), but this assertion accepts both shapes.
            $SmokeBlock | Should -Match 'MCP_ALLOW_UNAUTHENTICATED=true|MCP_AUTH_TOKEN='
        }

        It 'uses the boolean opt-out (MCP_ALLOW_UNAUTHENTICATED), not a fabricated token string' {
            $SmokeBlock | Should -Match '-e MCP_ALLOW_UNAUTHENTICATED=true'
            # The value form matters: auth-gate.ts's loadInboundAuth tests
            # /^(1|true|yes)$/i, so "TRUE" or "1" would work and "yes please"
            # would not. Pinned here because a silent typo would put the image
            # back in the "refuses to boot" state F2's fix created.
            $SmokeBlock | Should -Not -Match 'MCP_AUTH_TOKEN='
        }
    }

    Context '<Name> defaults MLS_IMAGE_DIGEST rather than requiring it at smoke-test time' -ForEach @(
        $script:Apps | Where-Object { $_.Payload -eq 'nginx-text' }
    ) {
        It 'expects "ok unset" from the image-default digest, not an override' {
            # No MLS_IMAGE_DIGEST override here: the Dockerfile's ENV default
            # ("unset") is exactly what the "^ok " prefix check already
            # covers, and stamping a real digest is the deploy step's job
            # (L7 V7.1), not this smoke test's.
            $SmokeBlock | Should -Not -Match 'MLS_IMAGE_DIGEST='
        }
    }
}
