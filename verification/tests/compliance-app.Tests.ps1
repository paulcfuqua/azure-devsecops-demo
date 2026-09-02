# =============================================================================
# Task 13/15: the compliance board's container app (mls-compliance-demo-ca)
# and its CI/deploy wiring.
#
# Task 13's own brief pins two literal assertions ("requires authentication",
# "scales to zero"); this file carries those plus the surrounding coverage the
# task calls for explicitly: that Easy Auth is actually CONFIGURED (comment
# text alone must not satisfy it), that no client secret reaches the repo or
# CI, that the app is deliberately excluded from the outputs V7.1's
# unauthenticated sweep reads from (see main.bicep's compliance app block),
# and the app-compliance-ci.yml workflow-shape assertions in the style of
# workload-rbac.Tests.ps1's F20:/F24: blocks — smoke-test placement relative
# to the Trivy gate and the GHCR login, and the L7 deploy wiring.
#
# Isolation approach follows workload-rbac.Tests.ps1: helper functions run
# ONLY inside BeforeAll (never invoked from inside an It), because
# app-ci-smoke-test.Tests.ps1's header documents a real Pester/PowerShell
# interaction where calling a user-defined function from inside an It throws
# "a 'break' or 'continue' statement ... escaped from your code"
# (pester/Pester#2669). Every It below only reads pre-computed $script:
# variables.
# =============================================================================

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..')).Path

    $script:MainBicepPath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'apps', 'main.bicep'
    $script:MainBicep = Get-Content -LiteralPath $script:MainBicepPath -Raw

    $script:NamingBicepPath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'naming.bicep'
    $script:NamingBicep = Get-Content -LiteralPath $script:NamingBicepPath -Raw

    $script:DemoParamPath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'apps', 'demo.bicepparam'
    $script:DemoParam = Get-Content -LiteralPath $script:DemoParamPath -Raw

    $script:CiWorkflowPath = Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'workflows', 'app-compliance-ci.yml'
    $script:CiWorkflow = Get-Content -LiteralPath $script:CiWorkflowPath -Raw

    $script:Layer07Path = Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'workflows', 'layer-07-apps.yml'
    $script:Layer07 = Get-Content -LiteralPath $script:Layer07Path -Raw

    # ---- isolate the complianceApp module block (main.bicep) ------------------
    # From its own "module complianceApp" header through the first STANDALONE
    # "}" line at column 0 — every line inside the module body is indented, so
    # that unindented brace is the module's own closing one. This is tighter
    # than stopping at the next module/output/resource/var declaration: this
    # file's section comments (e.g. the L10 witness header right after this
    # module) run to hundreds of words between one module's "}" and the next
    # "module " keyword, and none of that prose belongs to complianceApp.
    if ($script:MainBicep -notmatch '(?ms)^module complianceApp .*?\n\}\r?\n') {
        throw 'Could not isolate the complianceApp module block in main.bicep.'
    }
    $script:ComplianceModuleBlock = $Matches[0]

    # Comment-stripped copy: "Easy Auth is actually configured, not merely
    # mentioned in a comment" has to be provable against CODE, not prose. This
    # module block carries a lot of prose (by design, matching this file's
    # documentation style) that itself says words like "authConfig" and
    # "RedirectToLoginPage" — so the real assertion runs against this stripped
    # copy, not the raw block.
    $script:ComplianceModuleCode = (
        ($script:ComplianceModuleBlock -split "`n") | ForEach-Object { $_ -replace '//.*$', '' }
    ) -join "`n"

    # ---- isolate the shared Easy Auth builder (main.bicep) --------------------
    # Since F25 the authConfig object is not inline in each module: all three
    # human-facing apps call entraEasyAuthConfig(), so the assertions about what
    # Easy Auth is CONFIGURED to do run against that function, and the assertions
    # about whether a given app uses it run against that app's module block.
    if ($script:MainBicep -notmatch '(?ms)^func entraEasyAuthConfig\(.*?\n\}') {
        throw 'Could not isolate the entraEasyAuthConfig function in main.bicep.'
    }
    $script:EasyAuthFunc = $Matches[0]
    $script:EasyAuthFuncCode = (
        ($script:EasyAuthFunc -split "`n") | ForEach-Object { $_ -replace '//.*$', '' }
    ) -join "`n"

    # ---- isolate the containerAppNames output block (main.bicep) --------------
    if ($script:MainBicep -notmatch '(?ms)^output containerAppNames object = \{.*?\n\}') {
        throw 'Could not isolate the containerAppNames output block in main.bicep.'
    }
    $script:ContainerAppNamesOutput = $Matches[0]

    # ---- workflow job/step isolation helpers, invoked only here ---------------
    function Get-JobBody {
        param([string]$JobName, [string]$Source)
        if ($Source -notmatch "(?ms)^  $JobName`:\r?\n(.*?)(?=^  \w\S*:\r?\n|\z)") {
            throw "Could not isolate job '$JobName'."
        }
        return $Matches[1]
    }

    $script:CiPreflightJob = Get-JobBody -JobName 'preflight' -Source $script:CiWorkflow
    $script:CiBuildTestJob = Get-JobBody -JobName 'build-test' -Source $script:CiWorkflow
    $script:CiImageJob = Get-JobBody -JobName 'image' -Source $script:CiWorkflow
    $script:CiDeployJob = Get-JobBody -JobName 'deploy' -Source $script:CiWorkflow

    # Smoke-step isolation by index (same technique workload-rbac.Tests.ps1
    # uses for the F20/F24 steps) rather than an exact-string step-name match,
    # so an em-dash encoding quirk in "Smoke-test the image — ... (F22)" can't
    # make the isolation itself the thing that's broken.
    $script:SmokeIndex = $script:CiImageJob.IndexOf('- name: Smoke-test the image')
    $script:TrivyGateIndex = $script:CiImageJob.IndexOf('- name: Trivy gate')
    $script:GhcrLoginIndex = $script:CiImageJob.IndexOf('- name: Log in to GHCR')
    $script:PushIndex = $script:CiImageJob.IndexOf('- name: Push the scanned image')
    $script:SmokeBlock = ''
    if ($script:SmokeIndex -ge 0 -and $script:GhcrLoginIndex -gt $script:SmokeIndex) {
        $script:SmokeBlock = $script:CiImageJob.Substring($script:SmokeIndex, $script:GhcrLoginIndex - $script:SmokeIndex)
    }

    # ---- L7 declarative-deploy wiring (layer-07-apps.yml) ----------------------
    $script:L7DeployJob = Get-JobBody -JobName 'deploy' -Source $script:Layer07
}

Describe 'Task 13: compliance container app behind Easy Auth' {
    It 'requires authentication on the compliance app' {
        # The task-13 brief's own Step 1 failing test, verbatim except that the
        # configuration now lives in the shared entraEasyAuthConfig() builder (F25).
        $script:ComplianceModuleBlock | Should -Match 'authConfig'
        $script:ComplianceModuleBlock | Should -Match 'entraEasyAuthConfig\(complianceEntraClientId'
        $script:EasyAuthFunc | Should -Match "unauthenticatedClientAction:\s*'RedirectToLoginPage'"
    }

    It 'scales to zero like its siblings' {
        $script:ComplianceModuleBlock | Should -Match 'scaleSettings: scaleToZero'
    }

    It 'has Easy Auth configured in actual code, not merely described in a comment' {
        # Re-run the brief's own assertions against COMMENT-STRIPPED copies. A
        # module block or builder that only ever said these words in prose would
        # fail here even though it passes the test above.
        $script:ComplianceModuleCode | Should -Match 'authConfig:'
        $script:ComplianceModuleCode | Should -Match 'entraEasyAuthConfig\('
        $script:EasyAuthFuncCode | Should -Match "unauthenticatedClientAction:\s*'RedirectToLoginPage'"
        $script:EasyAuthFuncCode | Should -Match 'globalValidation:\s*\{'
        $script:EasyAuthFuncCode | Should -Match 'azureActiveDirectory:\s*\{'
        $script:EasyAuthFuncCode | Should -Match 'enabled:\s*true'
        $script:EasyAuthFuncCode | Should -Match 'requireHttps:\s*true'
    }

    It 'ties external ingress to Easy Auth being configured, never to a bare true (F26)' {
        # Before F26 this read `ingressExternal: true` unconditionally, and the
        # runbook claimed an unset MLS_COMPLIANCE_CLIENT_ID made ARM reject the
        # deployment. It did not: an undefined GitHub variable expands to the empty
        # string, so the board would have gone up open.
        $script:ComplianceModuleCode | Should -Match 'ingressExternal: complianceAuthConfigured'
        $script:ComplianceModuleCode | Should -Not -Match 'ingressExternal: true'
        $script:ComplianceModuleBlock | Should -Match 'ingressAllowInsecure: false'
        $script:MainBicep | Should -Match 'var complianceAuthConfigured = isEntraClientIdConfigured\(complianceEntraClientId\)'
    }

    It 'configures no client secret for the Entra provider' {
        # The whole point of Task 13's Easy Auth shape: a client ID (not a
        # secret) is enough for "is this caller signed in", and nothing here
        # should reach for the confidential-client properties. Asserted on the
        # shared builder as well as the module, since that is where the provider
        # registration now lives.
        foreach ($block in @($script:ComplianceModuleBlock, $script:EasyAuthFunc)) {
            $block | Should -Not -Match 'clientSecretSettingName'
            $block | Should -Not -Match 'clientSecretCertificateThumbprint'
        }
        $script:ComplianceModuleBlock | Should -Not -Match '(?m)^\s*secrets:'
        # The compliance board asks one question - "is this caller signed in" - and
        # forwards nothing downstream, so it passes NO token-store container and the
        # store stays off for it. Asserted at the CALL SITE rather than in the shared
        # builder, because the builder is now conditional: since F135 the control tower
        # does supply one, and an assertion on the builder would either fail or have to
        # be loosened into meaninglessness.
        $script:ComplianceModuleCode | Should -Match "entraEasyAuthConfig\(complianceEntraClientId, easyAuthIssuer, easyAuthExcludedPaths, '', ''\)"
    }

    It 'passes the client ID as a parameter reference, never a literal GUID' {
        $script:ComplianceModuleCode | Should -Match 'entraEasyAuthConfig\(complianceEntraClientId,'
        $script:EasyAuthFuncCode | Should -Match 'clientId: clientId'
        # A literal-looking GUID here would mean someone hardcoded a real
        # tenant's app ID into source instead of leaving it a parameter.
        $script:ComplianceModuleBlock | Should -Not -Match 'clientId:\s*''[0-9a-fA-F]{8}-'
        $script:EasyAuthFunc | Should -Not -Match 'clientId:\s*''[0-9a-fA-F]{8}-'
    }

    It 'grants no managed identity and no RBAC — the app reads only baked-in files' {
        $script:ComplianceModuleBlock | Should -Not -Match 'managedIdentities'
        $script:MainBicep | Should -Not -Match '(?i)compliance.*(principalId|roleDefinitionId)'
    }

    It 'names the app through naming.bicep, never a hardcoded prefix' {
        $script:MainBicep | Should -Match "var complianceName = naming\.containerAppName\(companyPrefix, naming\.appKeys\.compliance, env\)"
        $script:NamingBicep | Should -Match "compliance:\s*'compliance'"
    }

    It 'is deliberately excluded from containerAppNames — V7.1''s unauthenticated sweep must never reach it' {
        $script:ContainerAppNamesOutput | Should -Not -Match 'compliance'
    }

    It 'publishes its own name and FQDN through dedicated outputs instead' {
        $script:MainBicep | Should -Match 'output complianceAppName string = complianceName'
        $script:MainBicep | Should -Match 'output complianceFqdn string = complianceApp\.outputs\.fqdn'
    }

    It 'sources the Entra client ID from a non-secret environment variable, with a deliberately invalid default' {
        $script:DemoParam | Should -Match "readEnvironmentVariable\('MLS_COMPLIANCE_CLIENT_ID',\s*'unset'\)"
    }
}

Describe 'Task 15: app-compliance-ci.yml carries both fork guards from the outset' {
    It 'guards preflight against a fork PR reaching the demo environment' {
        $script:CiWorkflow | Should -Match ([regex]::Escape('github.event.pull_request.head.repo.full_name == github.repository'))
    }

    It 'guards deploy against running on a pull_request event at all' {
        $script:CiDeployJob | Should -Match ([regex]::Escape("github.event_name != 'pull_request'"))
    }
}

Describe 'Task 15: app-compliance-ci.yml smoke-tests the image before merge (F22 pattern)' {
    It 'has a smoke-test step in the image job' {
        $script:SmokeIndex | Should -BeGreaterThan -1
    }

    It 'places the smoke-test step strictly after the Trivy CRITICAL gate' {
        $script:SmokeIndex | Should -BeGreaterThan $script:TrivyGateIndex
    }

    It 'places the smoke-test step strictly before "Log in to GHCR" (no registry credential yet)' {
        $script:SmokeIndex | Should -BeLessThan $script:GhcrLoginIndex
    }

    It 'places the smoke-test step strictly before the push step' {
        $script:SmokeIndex | Should -BeLessThan $script:PushIndex
    }

    It 'hands the container no secret: no GITHUB_TOKEN, no secrets context, no env-file, no volume mount' {
        $script:SmokeBlock | Should -Not -Match 'secrets\.'
        $script:SmokeBlock | Should -Not -Match 'GITHUB_TOKEN'
        $script:SmokeBlock | Should -Not -Match '--env-file'
        $script:SmokeBlock | Should -Not -Match '-v\s'
    }

    It 'asserts the app''s own /healthz payload via the "^ok " prefix, not a bare 200' {
        $script:SmokeBlock | Should -Match '/healthz'
        $script:SmokeBlock | Should -Match '\^ok '
    }

    It 'is a merge gate, not advisory: no continue-on-error on the smoke step' {
        $script:SmokeBlock | Should -Not -Match 'continue-on-error'
    }
}

Describe 'Task 15: npm ci stays out of any job holding id-token or packages write' {
    It 'build-test (which runs npm ci) declares no elevated permissions block' {
        $script:CiBuildTestJob | Should -Not -Match 'permissions:'
    }

    It 'the image job (packages: write) does not itself run npm ci' {
        $script:CiImageJob | Should -Not -Match 'npm ci'
    }

    It 'the deploy job (id-token: write) does not itself run npm ci' {
        $script:CiDeployJob | Should -Not -Match 'npm ci'
    }
}

Describe 'Task 15: layer-07-apps.yml deploy wiring picks up the compliance app' {
    It 'resolves a GHCR image reference for compliance, same as the other four apps' {
        $script:L7DeployJob | Should -Match 'COMPLIANCE_IMAGE=\$\{registry\}/compliance:\$\{IMAGE_TAG\}'
    }

    It 'resolves an image digest for compliance via the shared resolve() helper' {
        $script:L7DeployJob | Should -Match 'resolve\s+"\$\{COMPLIANCE_IMAGE:-\}"\s+"\$\{CA_COMPLIANCE\}"\s+COMPLIANCE_IMAGE_DIGEST'
    }

    It 'derives a COMPLIANCE_PORT the same way as the other four apps, override still honoured' {
        # WAS: pinned to a job-level `COMPLIANCE_PORT: ${{ vars.COMPLIANCE_PORT || '80' }}`.
        # F88 removed that, and this test correctly caught the removal.
        #
        # The port is no longer chosen independently of the image. It is DERIVED by the same
        # step that resolves the image, because the two are one decision: the real images
        # listen on 8080 and the placeholder on 80, and defaulting them apart is what
        # deployed five containerapps-helloworld containers that reported success while
        # serving none of the demo.
        #
        # So this asserts the PROPERTY the original was reaching for - compliance is wired
        # exactly like the other four, and a deliberate operator override still wins - rather
        # than the mechanism that used to carry it. Pinning the mechanism is what made a
        # correct fix look like a regression.
        $script:L7DeployJob | Should -Match 'COMPLIANCE_PORT=\$\{COMPLIANCE_PORT_OVERRIDE:-\$\{port\}\}'
        $script:L7DeployJob | Should -Match "COMPLIANCE_PORT_OVERRIDE:\s*\`$\{\{\s*vars\.COMPLIANCE_PORT\s*\}\}"
    }

    It 'passes MLS_COMPLIANCE_CLIENT_ID through as a non-secret environment variable' {
        $script:L7DeployJob | Should -Match "MLS_COMPLIANCE_CLIENT_ID:\s*\`$\{\{\s*vars\.MLS_COMPLIANCE_CLIENT_ID\s*\}\}"
    }

    It 'the naming composite action resolves ca-compliance' {
        $namingActionPath = Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'actions', 'naming', 'action.yml'
        $namingAction = Get-Content -LiteralPath $namingActionPath -Raw
        $namingAction | Should -Match 'ca-compliance'
    }

    It 'does not fold compliance into the V7.1 deploy-manifest jq step (it stays outside containerAppNames)' {
        $manifestStepIndex = $script:L7DeployJob.IndexOf('- name: Write the V7.1 deploy manifest for the Verifier')
        $uploadStepIndex = $script:L7DeployJob.IndexOf('- name: Upload the V7.1 deploy manifest')
        $manifestStepIndex | Should -BeGreaterThan -1
        $manifestStep = $script:L7DeployJob.Substring($manifestStepIndex, $uploadStepIndex - $manifestStepIndex)
        $manifestStep | Should -Not -Match 'compliance'
    }

    It 'places the compliance wiring ahead of the F20/F24 remediation steps, same as every other app''s deploy wiring' {
        # Guards against a future edit accidentally inserting compliance
        # wiring BETWEEN the V7.1 manifest steps and F20/F24 - which
        # workload-rbac.Tests.ps1 already proves must stay adjacent and
        # unconditional-then-continue-on-error, in that order.
        $digestResolveIndex = $script:L7DeployJob.IndexOf('resolve "${COMPLIANCE_IMAGE:-}"')
        $whatIfIndex = $script:L7DeployJob.IndexOf('- name: What-if the apps deployment')
        $manifestWriteIndex = $script:L7DeployJob.IndexOf('- name: Write the V7.1 deploy manifest for the Verifier')
        $f20Index = $script:L7DeployJob.IndexOf('Apply the SQL contained-database user now that the identity exists (F20)')

        $digestResolveIndex | Should -BeGreaterThan -1
        $digestResolveIndex | Should -BeLessThan $whatIfIndex
        $whatIfIndex | Should -BeLessThan $manifestWriteIndex
        $manifestWriteIndex | Should -BeLessThan $f20Index
    }
}
