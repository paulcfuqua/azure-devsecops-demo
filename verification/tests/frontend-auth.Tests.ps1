# =============================================================================
# F25 — the two public dashboards must not be anonymously reachable, because
# both of them proxy /api/ straight through to data-api.
#
# The finding, in one request:
#
#     GET https://<control-tower-fqdn>/api/feeds/secure-score
#
# F1 had made data-api INTERNAL and recorded, as its reason, that "both
# frontends already proxy /api/ server-side". That is the bypass, not the fix:
# apps/control-tower/nginx.conf.template and apps/launch-ops/nginx.conf.template
# blind-proxy `location /api/ { proxy_pass ${DATA_API_ORIGIN}/; }`, both apps
# were `ingressExternal: true` with no authConfig, and data-api's identity holds
# Security Reader at SUBSCRIPTION scope plus Log Analytics Reader. An anonymous
# internet caller read the adopter's live Defender for Cloud posture.
#
# These tests are deliberately structural (they read the template and the
# workflow), for the same reason workload-rbac.Tests.ps1's are: nothing in this
# repo has ever been deployed, so the only thing that can be asserted is what
# the IaC says. What they must NOT do is assert on comment text — see
# workload-rbac.Tests.ps1's own header for why (F27). Every assertion below
# runs against a comment-stripped copy of the block it examines.
#
# Isolation approach follows compliance-app.Tests.ps1: helper work happens in
# BeforeAll only, and each It reads pre-computed $script: variables
# (pester/Pester#2669).
# =============================================================================

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..')).Path

    $script:MainBicepPath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'apps', 'main.bicep'
    $script:MainBicep = Get-Content -LiteralPath $script:MainBicepPath -Raw

    $script:DemoParamPath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'apps', 'demo.bicepparam'
    $script:DemoParam = Get-Content -LiteralPath $script:DemoParamPath -Raw

    $script:Layer07Path = Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'workflows', 'layer-07-apps.yml'
    $script:Layer07 = Get-Content -LiteralPath $script:Layer07Path -Raw

    $script:NginxPath = @{
        controlTower = Join-Path -Path $script:RepoRoot -ChildPath 'apps' -AdditionalChildPath 'control-tower', 'nginx.conf.template'
        launchOps    = Join-Path -Path $script:RepoRoot -ChildPath 'apps' -AdditionalChildPath 'launch-ops', 'nginx.conf.template'
    }
    $script:Nginx = @{}
    foreach ($key in @($script:NginxPath.Keys)) {
        $script:Nginx[$key] = Get-Content -LiteralPath $script:NginxPath[$key] -Raw
    }

    # ---- isolate each container-app module block ------------------------------
    # From "module <name> " through the first standalone "}" at column 0: every
    # line inside a module body is indented, so that brace is the module's own.
    $script:ModuleCode = @{}
    foreach ($moduleName in @('launchOpsApp', 'controlTowerApp', 'complianceApp', 'dataApiApp')) {
        if ($script:MainBicep -notmatch "(?ms)^module $moduleName .*?\n\}") {
            throw "Could not isolate the $moduleName module block in main.bicep."
        }
        # Comment-stripped. The whole point of F27 is that a `//` comment saying
        # the right words is not the same as code doing the right thing.
        $script:ModuleCode[$moduleName] = (
            ($Matches[0] -split "`n") | ForEach-Object { $_ -replace '//.*$', '' }
        ) -join "`n"
    }

    if ($script:MainBicep -notmatch '(?ms)^func entraEasyAuthConfig\(.*?\n\}') {
        throw 'Could not isolate the entraEasyAuthConfig function in main.bicep.'
    }
    $script:EasyAuthFuncCode = (
        ($Matches[0] -split "`n") | ForEach-Object { $_ -replace '//.*$', '' }
    ) -join "`n"

    if ($script:MainBicep -notmatch '(?ms)^func isEntraClientIdConfigured\(.*?$') {
        throw 'Could not isolate isEntraClientIdConfigured in main.bicep.'
    }
    $script:ClientIdGuard = $Matches[0]
}

Describe 'F25: the frontends that proxy /api/ are Easy Auth gated' {
    It 'still proxies /api/ from both frontends — the coupling these tests exist for' {
        # If this ever stops being true the finding changes shape, and the
        # assertions below should be re-derived rather than silently kept.
        foreach ($key in @('controlTower', 'launchOps')) {
            $script:Nginx[$key] | Should -Match 'location /api/ \{'
            $script:Nginx[$key] | Should -Match 'proxy_pass \$\{DATA_API_ORIGIN\}/;'
        }
    }

    It 'gives launch-ops and control-tower an authConfig built from the shared Entra builder' {
        $script:ModuleCode['launchOpsApp'] | Should -Match 'authConfig: launchOpsAuthConfigured'
        $script:ModuleCode['launchOpsApp'] | Should -Match 'entraEasyAuthConfig\(launchOpsEntraClientId'
        $script:ModuleCode['controlTowerApp'] | Should -Match 'authConfig: controlTowerAuthConfigured'
        # \s* after the paren: the control tower's call is multi-line since F135 gave it
        # a token store, and the assertion is about WHICH BUILDER it uses, not how the
        # argument list is wrapped.
        $script:ModuleCode['controlTowerApp'] | Should -Match '(?s)entraEasyAuthConfig\(\s*controlTowerEntraClientId'
    }

    It 'never publishes a human-facing app externally without that authConfig' {
        # The invariant, stated once: ingressExternal is literally the same
        # expression as "is Easy Auth configured for this app". A bare
        # `ingressExternal: true` on any of the three is the regression.
        $script:ModuleCode['launchOpsApp'] | Should -Match 'ingressExternal: launchOpsAuthConfigured'
        $script:ModuleCode['controlTowerApp'] | Should -Match 'ingressExternal: controlTowerAuthConfigured'
        $script:ModuleCode['complianceApp'] | Should -Match 'ingressExternal: complianceAuthConfigured'
        foreach ($moduleName in @('launchOpsApp', 'controlTowerApp', 'complianceApp')) {
            $script:ModuleCode[$moduleName] | Should -Not -Match 'ingressExternal: true'
        }
    }

    It 'keeps data-api internal and gives it no authConfig of its own' {
        # F1's half of the fix, which stays: the frontends are the front door.
        $script:ModuleCode['dataApiApp'] | Should -Match 'ingressExternal: false'
        $script:ModuleCode['dataApiApp'] | Should -Not -Match 'authConfig'
    }

    It 'requires a real sign-in rather than redirecting to a provider that accepts anyone' {
        $script:EasyAuthFuncCode | Should -Match "unauthenticatedClientAction: 'RedirectToLoginPage'"
        $script:EasyAuthFuncCode | Should -Match 'platform: \{'
        $script:EasyAuthFuncCode | Should -Match 'requireHttps: true'
        $script:EasyAuthFuncCode | Should -Match 'openIdIssuer: issuer'
    }

    It 'excludes only /healthz from authentication, and never anything under /api/' {
        # /healthz has to stay anonymous for V7.1's unauthenticated GET. Adding
        # /api/ (or a bare /) to that allowlist would reinstate F25 exactly.
        $script:MainBicep | Should -Match "var easyAuthExcludedPaths = \['/healthz'\]"
        $script:MainBicep | Should -Not -Match "easyAuthExcludedPaths = \[[^\]]*'/api"
    }

    It 'configures no client secret anywhere in the Easy Auth path' {
        $script:EasyAuthFuncCode | Should -Not -Match 'clientSecretSettingName'
        $script:EasyAuthFuncCode | Should -Not -Match 'clientSecretCertificateThumbprint'
        # THE TOKEN STORE IS NO LONGER UNCONDITIONALLY OFF, and these two lines used to
        # assert that it was. That was a PROXY for "no confidential-client behaviour",
        # and the proxy stopped tracking the thing once the control tower needed the
        # store to forward this session's token to the directline-token Function (F135).
        #
        # What actually matters is asserted directly instead: no client secret anywhere
        # (above), and the store OFF unless a caller supplies a container - so an app
        # that does not ask for one cannot acquire it by omission.
        $script:EasyAuthFuncCode | Should -Match 'tokenStore: empty\(tokenStoreContainerUri\)'
        $script:EasyAuthFuncCode | Should -Match 'enabled: false'
        # Enabling the store must not smuggle in a secret: the blob path authenticates
        # with a managed identity, which is the whole reason it needs no client secret.
        $script:EasyAuthFuncCode | Should -Match 'managedIdentityResourceId'
    }
}

Describe 'F26: an unset GitHub variable is the empty string, not the parameter default' {
    It 'treats both the empty string and the "unset" sentinel as not-configured' {
        # readEnvironmentVariable returns its default only when the variable is
        # UNDEFINED. `vars.X` for an undefined GitHub variable expands to "",
        # which IS defined — so the parameter arrives as "" and the 'unset'
        # default is never reached. Checking only one of the two spellings is
        # the defect.
        $script:ClientIdGuard | Should -Match "!empty\(clientId\)"
        $script:ClientIdGuard | Should -Match "clientId != 'unset'"
    }

    It 'derives each app''s configured flag from that single guard' {
        foreach ($pair in @(
                @('launchOpsAuthConfigured', 'launchOpsEntraClientId'),
                @('controlTowerAuthConfigured', 'controlTowerEntraClientId'),
                @('complianceAuthConfigured', 'complianceEntraClientId'))) {
            $script:MainBicep | Should -Match "var $($pair[0]) = isEntraClientIdConfigured\($($pair[1])\)"
        }
    }

    It 'sources all three client IDs from non-secret environment variables' {
        $script:DemoParam | Should -Match "param complianceEntraClientId = readEnvironmentVariable\('MLS_COMPLIANCE_CLIENT_ID', 'unset'\)"
        $script:DemoParam | Should -Match "param launchOpsEntraClientId = readEnvironmentVariable\('MLS_LAUNCH_OPS_CLIENT_ID', 'unset'\)"
        $script:DemoParam | Should -Match "param controlTowerEntraClientId = readEnvironmentVariable\('MLS_CONTROL_TOWER_CLIENT_ID', 'unset'\)"
    }

    It 'passes all three through layer-07-apps.yml as variables, not secrets' {
        foreach ($name in @('MLS_COMPLIANCE_CLIENT_ID', 'MLS_LAUNCH_OPS_CLIENT_ID', 'MLS_CONTROL_TOWER_CLIENT_ID')) {
            $script:Layer07 | Should -Match "$name`: \`$\{\{ vars\.$name \}\}"
            $script:Layer07 | Should -Not -Match "$name`: \`$\{\{ secrets\."
        }
    }

    It 'no longer hard-refuses the deploy when one is unset - it resolves them instead (F36)' {
        # This used to assert the opposite: a first step that failed the whole L7
        # job unless all three variables were hand-set. That was secure and
        # UNDEPLOYABLE - the registrations it demanded IDs for are the ones L3
        # creates, and their redirect URIs cannot exist before L7 has run. The
        # refusal is gone; the fail-closed property it was belt-and-braces for
        # lives in the template, and is asserted above and in the F36 Describe.
        $script:Layer07 | Should -Not -Match 'Require an Entra client ID for every externally-reachable app'
        $script:Layer07 | Should -Not -Match 'Easy Auth client IDs missing'
        $script:Layer07 | Should -Match 'Resolve the Easy Auth client IDs from their Entra app registrations \(F36\)'
    }

    It 'reports which apps actually got Easy Auth' {
        $script:MainBicep | Should -Match 'output frontendAuthStatus object = \{'
    }
}

Describe 'F26 siblings: every readEnvironmentVariable default a workflow feeds from vars.*' {
    It 'gives KEY_VAULT_CREATE_MODE a literal fallback so the @allowed list is never handed ""' {
        # Same shape, different blast radius: without the fallback the env var is
        # set-but-empty, keyVaultCreateMode resolves to '' rather than 'default',
        # and @allowed(['default','recover']) rejects it — BCP033 at bicepparam
        # compile time, for every adopter who has not set the variable.
        #
        # Asserted as a PROPERTY, not as one exact string. The expression legitimately grew a
        # middle term - the kvmode step decides `recover` when it finds a soft-deleted vault
        # (F85) - and a regex pinning the old text failed a change that preserved everything
        # the test exists to protect. What matters is that the chain ENDS in a literal, so
        # the @allowed list can never be handed "".
        $layer06 = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'workflows', 'layer-06-platform.yml') -Raw
        $layer06 | Should -Match "KEY_VAULT_CREATE_MODE: \`$\{\{[^}]*\|\| 'default' \}\}"
        # And it must still be sourced from the repository variable first, so a deliberate
        # operator override wins over anything computed.
        $layer06 | Should -Match "KEY_VAULT_CREATE_MODE: \`$\{\{ vars\.KEY_VAULT_CREATE_MODE \|\|"
    }
}

# =============================================================================
# F36 — the F25/F26 fix was secure but undeployable.
#
# `.github/workflows/layer-07-apps.yml` opened with a step that failed the whole
# L7 deploy unless MLS_LAUNCH_OPS_CLIENT_ID, MLS_CONTROL_TOWER_CLIENT_ID and
# MLS_COMPLIANCE_CLIENT_ID were all hand-set on the `demo` environment — and
# Easy Auth's redirect URIs could not be registered until the apps existed and
# had FQDNs, which happens in the same workflow the refusal blocked. An adopter
# had to resolve that by hand before anything deployed at all.
#
# Both halves are now automatic, and the fail-closed property is untouched:
#   * L3 already creates all four registrations from infra/entra/manifest.json,
#     so L7 RESOLVES each client ID by its manifest display name and treats a
#     set variable as an OVERRIDE rather than a requirement;
#   * an unresolvable client ID is a documented state (deployed, internal-only,
#     loudly reported), NOT a failure — main.bicep's ingressExternal is the same
#     expression as "is Easy Auth configured", which the chain test at the
#     bottom of this file asserts end to end;
#   * an az failure or an AMBIGUOUS match is still an error, because "the CLI
#     was throttled" and "L3 has not run" must not look the same (F20's
#     original defect), and the wrong client ID gates a dashboard against the
#     wrong tenant identity;
#   * the redirect URI is patched after the FQDNs exist, MERGED into whatever is
#     already registered, and placed exactly where the F20/F24 remediation steps
#     are — after the V7.1 manifest, with continue-on-error.
# =============================================================================

Describe 'F36: L7 resolves its own Easy Auth client IDs rather than demanding them' {
    BeforeAll {
        # Same isolation approach as workload-rbac.Tests.ps1's F20/F24 blocks:
        # every assertion runs against ONE step's body, so a string that leaked
        # into the wrong step fails these tests instead of satisfying them.
        function Get-JobBody {
            param([string]$JobName, [string]$Source)
            if ($Source -notmatch "(?ms)^  $JobName`:\r?\n(.*?)(?=^  \w\S*:\r?\n|\z)") {
                throw "Could not isolate job '$JobName' in layer-07-apps.yml."
            }
            return $Matches[1]
        }
        function Get-StepBody {
            param([string]$StepName, [string]$JobBody)
            $escaped = [regex]::Escape($StepName)
            if ($JobBody -notmatch "(?ms)^\s{6}- name: $escaped\r?\n(.*?)(?=^\s{6}- name:|\z)") {
                throw "Could not isolate step '$StepName' in its job body."
            }
            return $Matches[1]
        }

        $script:F36DeployJob = Get-JobBody -JobName 'deploy' -Source $script:Layer07
        $script:F36VerifyJob = Get-JobBody -JobName 'verify' -Source $script:Layer07
        $script:ResolveStepName = 'Resolve the Easy Auth client IDs from their Entra app registrations (F36)'
        $script:RedirectStepName = "Register each dashboard's Easy Auth redirect URI now that its FQDN exists (F36)"
        $script:ResolveStep = Get-StepBody -StepName $script:ResolveStepName -JobBody $script:F36DeployJob
        $script:RedirectStep = Get-StepBody -StepName $script:RedirectStepName -JobBody $script:F36DeployJob
        $script:RedirectReportStep = Get-StepBody -StepName 'Report a failed redirect-URI registration' -JobBody $script:F36DeployJob

        $script:EntraManifestPath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'entra', 'manifest.json'
        # Resolved, not raw: the manifest ships tokenised, and a fixture asserting on
        # "${prefix}-launch-ops-${env}-app" would be testing a string the deploy never
        # sees (F93).
        $script:EntraManifest = (Get-Content -LiteralPath $script:EntraManifestPath -Raw).
            Replace('${prefix}', 'mls').Replace('${env}', 'demo') | ConvertFrom-Json

        # The not-found branch on its own: from the line that records the state
        # to the end of the else block that owns it. "no registration exists" is
        # the one outcome that must NOT be able to end the run.
        if ($script:ResolveStep -notmatch '(?ms)\$state = "NOT FOUND.*?\$unpublished\.Add\([^\r\n]*\)') {
            throw 'Could not isolate the "registration not found" branch of the resolve step.'
        }
        $script:NotFoundBranch = $Matches[0]

        # The ambiguity branch on its own, for the same reason.
        if ($script:ResolveStep -notmatch '(?ms)if \(\$matched\.Count -gt 1\) \{.*?(?=if \(\$matched\.Count -eq 1\))') {
            throw 'Could not isolate the ambiguous-match branch of the resolve step.'
        }
        $script:AmbiguousBranch = $Matches[0]
    }

    # ---- the refusal is gone --------------------------------------------------

    It 'has deleted the step that refused the whole deploy over a missing client ID' {
        $script:F36DeployJob | Should -Not -Match 'Require an Entra client ID for every externally-reachable app'
        $script:F36DeployJob | Should -Not -Match 'Easy Auth client IDs missing'
        $script:F36DeployJob | Should -Not -Match 'L7 refused to deploy'
    }

    It 'treats an unresolvable client ID as a reported state, not an error' {
        # THE distinction this finding is about. A missing registration means the
        # app deploys internal-only; it must not exit non-zero, and it must not be
        # annotated as an error, or the estate is undeployable again.
        $script:NotFoundBranch | Should -Not -Match 'exit 1'
        $script:NotFoundBranch | Should -Not -Match '::error'
        $script:ResolveStep | Should -Match '::warning title=Some dashboards are not publicly reachable'
    }

    It 'names each app, its state and the one command that fixes it, in the step summary' {
        $script:ResolveStep | Should -Match 'GITHUB_STEP_SUMMARY'
        $script:ResolveStep | Should -Match '\| App registration \| Client ID \| Ingress \|'
        $script:ResolveStep | Should -Match 'gh workflow run layer-03-entra\.yml'
        # And it says what "internal only" means, rather than leaving the reader
        # to infer it from a green run with two dashboards missing.
        $script:ResolveStep | Should -Match 'internal only'
    }

    # ---- how the IDs are resolved --------------------------------------------

    It 'takes the app-registration display names from the Entra manifest, never a literal in the workflow' {
        # CLAUDE.md: the company prefix is naming.bicep's to own. A display name
        # spelled out here would hardcode `mls` in a workflow AND drift from L3.
        $script:ResolveStep | Should -Match 'infra/entra/manifest\.json'
        $script:ResolveStep | Should -Match 'az ad app list --display-name \$displayName'
        foreach ($registration in $script:EntraManifest.appRegistrations) {
            $script:Layer07 | Should -Not -Match ([regex]::Escape($registration.displayName))
        }
    }

    It 'selects each registration by the manifest appKey that identifies it, and the manifest declares exactly one of each' {
        foreach ($key in @('launch-ops', 'control-tower', 'compliance')) {
            $script:ResolveStep | Should -Match ([regex]::Escape("Key = '$key'"))
            @($script:EntraManifest.appRegistrations | Where-Object { $_.appKey -eq $key }).Count | Should -Be 1
        }
    }

    It 'refuses on an ambiguous match instead of picking the first' {
        # Gating a dashboard against the wrong app registration authenticates it
        # against the wrong tenant identity - the same refusal the F24 identity
        # lookup makes, and the reason the query is never `[0].appId`.
        $script:AmbiguousBranch | Should -Match '::error title=Ambiguous app registration'
        $script:AmbiguousBranch | Should -Match 'exit 1'
        $script:ResolveStep | Should -Match '\$matched\.Count -gt 1'
        $script:ResolveStep | Should -Not -Match "--query '?\[0\]"
        $script:ResolveStep | Should -Not -Match '\[0\]\.appId'
    }

    It 'asserts the exact display name in the query rather than trusting --display-name to mean equality' {
        # az has spelled that server-side filter both `eq` and `startswith`; a
        # registration merely PREFIXED with the manifest name is a different app.
        $script:ResolveStep | Should -Match "\[\?displayName=='\`$displayName'\]\.appId"
    }

    It 'distinguishes an Azure CLI failure from a registration that does not exist yet' {
        # az does not throw in pwsh, and an empty result and a throttled call used
        # to look identical. That conflation is F20's original defect.
        $script:ResolveStep | Should -Match '\$LASTEXITCODE'
        $script:ResolveStep | Should -Match '::error title=Azure CLI call failed'
    }

    It 'honours an already-set variable as an override rather than requiring it' {
        foreach ($name in @('MLS_LAUNCH_OPS_CLIENT_ID', 'MLS_CONTROL_TOWER_CLIENT_ID', 'MLS_COMPLIANCE_CLIENT_ID')) {
            $script:ResolveStep | Should -Match "$name`: \`$\{\{ vars\.$name \}\}"
            $script:ResolveStep | Should -Not -Match "$name`: \`$\{\{ secrets\."
        }
        $script:ResolveStep | Should -Match '\[Environment\]::GetEnvironmentVariable\(\$target\.Variable\)'
    }

    It 'publishes the resolved values under the exact names the bicepparam reads' {
        $script:ResolveStep | Should -Match '\$env:GITHUB_ENV'
        foreach ($name in @('MLS_LAUNCH_OPS_CLIENT_ID', 'MLS_CONTROL_TOWER_CLIENT_ID', 'MLS_COMPLIANCE_CLIENT_ID')) {
            $script:DemoParam | Should -Match "readEnvironmentVariable\('$name'"
            $script:ResolveStep | Should -Match ([regex]::Escape("Variable = '$name'"))
        }
    }

    It 'does not also declare those names as job-level env, which would make precedence decide the estate''s security posture' {
        # A job-level `env:` and a GITHUB_ENV write of the same name in the same
        # job is a precedence question nothing here should have to answer.
        $jobEnvBlock = if ($script:F36DeployJob -match '(?ms)^    env:\r?\n(.*?)(?=^    \w)') { $Matches[1] } else { '' }
        foreach ($name in @('MLS_LAUNCH_OPS_CLIENT_ID', 'MLS_CONTROL_TOWER_CLIENT_ID', 'MLS_COMPLIANCE_CLIENT_ID')) {
            $jobEnvBlock | Should -Not -Match "(?m)^\s{6}$name`:"
        }
    }

    It 'runs in the deploy job, which can write - never the Reader-only verify job' {
        $script:F36VerifyJob | Should -Not -Match ([regex]::Escape($script:ResolveStepName))
        $script:F36VerifyJob | Should -Not -Match ([regex]::Escape($script:RedirectStepName))
    }
}

Describe 'F36: the Easy Auth redirect URI is registered once the FQDN exists' {
    It 'composes each app''s reply URL from the FQDN the deployment actually returned' {
        $script:RedirectStep | Should -Match '/\.auth/login/aad/callback'
        $script:RedirectStep | Should -Match 'l7-manifest\.json'
        $script:RedirectStep | Should -Match '\$outputs\.launchOpsFqdn\.value'
        $script:RedirectStep | Should -Match '\$outputs\.controlTowerFqdn\.value'
        $script:RedirectStep | Should -Match '\$outputs\.complianceFqdn\.value'
    }

    It 'reads the existing URIs and MERGES, because --web-redirect-uris replaces the whole list' {
        # Overwriting would silently drop a working redirect URI the moment an
        # FQDN changes (a rebuilt environment gets a new one), and the adopter
        # would be left with a dashboard that 400s at login for no visible reason.
        $script:RedirectStep | Should -Match "az ad app show --id \`$target\.AppId --query 'web\.redirectUris'"
        $script:RedirectStep | Should -Match '\$merged = @\(\$existing\) \+ @\(\$redirectUri\)'
        $script:RedirectStep | Should -Match '--web-redirect-uris \$merged'
        $script:RedirectStep | Should -Not -Match '--web-redirect-uris \$redirectUri'
    }

    It 'is a no-op that says so when the URI is already registered' {
        $script:RedirectStep | Should -Match '\$existing -contains \$redirectUri'
        $script:RedirectStep | Should -Match 'already registered'
    }

    It 'skips an app that has no client ID rather than inventing one' {
        $script:RedirectStep | Should -Match '\[string\]::IsNullOrWhiteSpace\(\$target\.AppId\)'
    }

    It 'distinguishes an Azure CLI failure from an app with nothing to patch' {
        $script:RedirectStep | Should -Match '\$LASTEXITCODE'
        $script:RedirectStep | Should -Match '::error title=Azure CLI call failed'
    }

    It 'runs after the V7.1 manifest is written AND uploaded, so a failure here cannot skip them' {
        # Identical placement reasoning to the F20 and F24 remediation steps: the
        # manifest steps carry no always(), so a hard failure earlier in the job
        # would leave the Verifier with nothing to bind endpoints to builds with.
        $writeIndex = $script:F36DeployJob.IndexOf('- name: Write the V7.1 deploy manifest for the Verifier')
        $uploadIndex = $script:F36DeployJob.IndexOf('- name: Upload the V7.1 deploy manifest')
        $redirectIndex = $script:F36DeployJob.IndexOf($script:RedirectStepName)

        $writeIndex | Should -BeGreaterThan -1
        $uploadIndex | Should -BeGreaterThan $writeIndex
        $redirectIndex | Should -BeGreaterThan $uploadIndex
    }

    It 'carries continue-on-error, so idempotent remediation cannot red a deployment that worked' {
        # `verify` is needs: [preflight, deploy] and requires deploy to SUCCEED.
        $script:RedirectStep | Should -Match '(?m)^\s*continue-on-error:\s*true\s*$'
    }

    It 'is skipped on a dry run, like every other step that writes' {
        $script:RedirectStep | Should -Match '(?m)^\s*if:\s*\$\{\{\s*!inputs\.dry_run\s*\}\}\s*$'
    }

    It 'surfaces a failure in the run summary, since continue-on-error keeps the job green' {
        $script:RedirectReportStep | Should -Match "steps\.redirect_uris\.outcome == 'failure'"
        $script:RedirectReportStep | Should -Match 'GITHUB_STEP_SUMMARY'
        $script:RedirectReportStep | Should -Match 'AADSTS50011'
    }

    It 'leaves the F20 and F24 remediation steps where they were' {
        # verification/tests/workload-rbac.Tests.ps1 asserts both orderings; this
        # states the coupling here too, so a reordering fails next to its cause.
        $uploadIndex = $script:F36DeployJob.IndexOf('- name: Upload the V7.1 deploy manifest')
        $f20Index = $script:F36DeployJob.IndexOf('Apply the SQL contained-database user now that the identity exists (F20)')
        $f24Index = $script:F36DeployJob.IndexOf('Grant data-api the Fabric workspace Viewer role now that the identity exists (F24)')
        $f20Index | Should -BeGreaterThan $uploadIndex
        $f24Index | Should -BeGreaterThan $uploadIndex
    }
}

Describe 'F36: no client ID still means no external ingress - the chain, end to end' {
    # The property F25/F26 bought and F36 must not have spent. Asserted as the
    # whole chain rather than one link, because the workflow no longer refuses:
    # an app with no registration now genuinely reaches the template, and what
    # keeps it off the internet is the template alone.
    It 'carries the empty string all the way from an unresolved lookup to internal ingress' {
        foreach ($app in @(
                @{ Variable = 'MLS_LAUNCH_OPS_CLIENT_ID'; Param = 'launchOpsEntraClientId'; Flag = 'launchOpsAuthConfigured'; Module = 'launchOpsApp' },
                @{ Variable = 'MLS_CONTROL_TOWER_CLIENT_ID'; Param = 'controlTowerEntraClientId'; Flag = 'controlTowerAuthConfigured'; Module = 'controlTowerApp' },
                @{ Variable = 'MLS_COMPLIANCE_CLIENT_ID'; Param = 'complianceEntraClientId'; Flag = 'complianceAuthConfigured'; Module = 'complianceApp' })) {

            # 1. the workflow writes the variable - empty when nothing resolved.
            $script:ResolveStep | Should -Match ([regex]::Escape("Variable = '$($app.Variable)'"))
            # 2. the bicepparam reads that exact name.
            $script:DemoParam | Should -Match "param $($app.Param) = readEnvironmentVariable\('$($app.Variable)', 'unset'\)"
            # 3. the guard rejects BOTH spellings of not-configured.
            $script:MainBicep | Should -Match "var $($app.Flag) = isEntraClientIdConfigured\($($app.Param)\)"
            # 4. and ingress is that same flag, not a bare true.
            $script:ModuleCode[$app.Module] | Should -Match "ingressExternal: $($app.Flag)"
            $script:ModuleCode[$app.Module] | Should -Not -Match 'ingressExternal: true'
            # 5. as is the authConfig, so the two can never diverge.
            $script:ModuleCode[$app.Module] | Should -Match "authConfig: $($app.Flag)"
        }
        $script:ClientIdGuard | Should -Match '!empty\(clientId\)'
        $script:ClientIdGuard | Should -Match "clientId != 'unset'"
    }

    It 'still exempts only /healthz, so nothing under /api/ is anonymous on a partially-configured estate' {
        $script:MainBicep | Should -Match "var easyAuthExcludedPaths = \['/healthz'\]"
        $script:MainBicep | Should -Not -Match "easyAuthExcludedPaths = \[[^\]]*'/api"
    }

    It 'keeps data-api internal, which is what the login gate is protecting' {
        $script:ModuleCode['dataApiApp'] | Should -Match 'ingressExternal: false'
    }

    It 'introduces no client secret anywhere in the resolution or redirect path' {
        # A client ID is a public identifier; a secret is not, and CLAUDE.md hard
        # rule 5 allows exactly one stored secret in this system (Direct Line).
        foreach ($step in @($script:ResolveStep, $script:RedirectStep)) {
            $step | Should -Not -Match '(?i)client[-_]?secret'
            $step | Should -Not -Match '\$\{\{ secrets\.'
        }
    }
}
