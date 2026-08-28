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
        $script:ModuleCode['controlTowerApp'] | Should -Match 'entraEasyAuthConfig\(controlTowerEntraClientId'
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
        $script:EasyAuthFuncCode | Should -Match 'tokenStore: \{'
        $script:EasyAuthFuncCode | Should -Match 'enabled: false'
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

    It 'refuses the L7 deploy outright when any of the three is unset' {
        # The loud failure docs/runbooks/g0-bootstrap.md used to claim ARM
        # produced. ARM never did; this step does.
        $script:Layer07 | Should -Match 'Require an Entra client ID for every externally-reachable app'
        $script:Layer07 | Should -Match 'for var in MLS_LAUNCH_OPS_CLIENT_ID MLS_CONTROL_TOWER_CLIENT_ID MLS_COMPLIANCE_CLIENT_ID'
        $script:Layer07 | Should -Match 'Easy Auth client IDs missing'
        $script:Layer07 | Should -Match 'exit 1'
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
        $layer06 = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'workflows', 'layer-06-platform.yml') -Raw
        $layer06 | Should -Match "KEY_VAULT_CREATE_MODE: \`$\{\{ vars\.KEY_VAULT_CREATE_MODE \|\| 'default' \}\}"
    }
}
