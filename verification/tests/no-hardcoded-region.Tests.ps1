# The estate's region has exactly one source of truth: vars.AZURE_LOCATION on the demo
# GitHub environment. Nothing in the deploy path may carry a region literal as a default.
#
# This exists because a `default: eastus` in every layer workflow, plus `$Location =
# 'eastus'` in scripts/up.ps1, silently outvoted that variable: `up.ps1` passes location as
# a workflow INPUT, and an input always beats the environment variable the layer would
# otherwise read. Setting AZURE_LOCATION=centralus therefore appeared to do nothing, and
# the next deploy went to a region where Azure SQL cannot provision at all - the same
# failure the region change existed to fix (F52/F53).

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:AzureRegion = 'eastus|eastus2|centralus|westus|westus2|westus3|northcentralus|southcentralus|westcentralus|canadacentral|northeurope|westeurope|uksouth|ukwest'
}

Describe 'the estate region is never hardcoded in the deploy path' {

    It 'no workflow declares a region literal as an input default' {
        $offender = [System.Collections.Generic.List[string]]::new()
        foreach ($file in (Get-ChildItem -Path (Join-Path $script:RepoRoot '.github' 'workflows') -Filter '*.yml' -File)) {
            $number = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                $number++
                # `default: <region>` only. A region inside a comment or a description is
                # documentation, and a URL host like eastus-1.in.applicationinsights... is
                # telemetry, not configuration.
                if ($line -match "^\s*default:\s*'?($script:AzureRegion)'?\s*$") {
                    $offender.Add("$($file.Name):$number")
                }
            }
        }
        $offender -join ', ' | Should -BeNullOrEmpty -Because 'vars.AZURE_LOCATION is the single source of truth; a default silently outvotes it'
    }

    It 'every policy assignment pins its identity location explicitly' {
        # AVM's policy-assignment module defaults `location` to the DEPLOYMENT's location.
        # Four of the six assignments never passed one, so they silently tracked the estate
        # region and failed with InvalidLocationUpdate on a region change - even the ones
        # with identity 'None', which have no identity to place. A seventh module added
        # without a location would reintroduce exactly that (F55).
        $template = Join-Path $script:RepoRoot 'infra' 'bicep' 'landing-zone' 'main.bicep'
        $content = Get-Content -LiteralPath $template -Raw
        $modules = ([regex]::Matches($content, "avm/ptn/authorization/policy-assignment")).Count
        $pinned = ([regex]::Matches($content, 'location:\s*effectivePolicyAssignmentLocation')).Count
        $modules | Should -BeGreaterThan 0 -Because 'the template must still declare policy assignments'
        $pinned | Should -Be $modules -Because 'every policy-assignment module must pin its location, or AVM defaults it to the estate region'
    }

    It 'scripts/up.ps1 does not default -Location to a region' {
        $line = Select-String -Path (Join-Path $script:RepoRoot 'scripts' 'up.ps1') `
            -Pattern '^\s*\[string\]\$Location\s*=' | Select-Object -First 1
        $line | Should -Not -BeNullOrEmpty -Because 'the parameter must still exist as an override'
        $line.Line | Should -Match "=\s*''" -Because 'empty means "use the demo environment"; a region literal overrides it'
    }

    It 'the three layers that consume a region fall back to the demo environment variable' {
        foreach ($name in 'layer-02-landing-zone', 'layer-06-platform', 'layer-07-apps') {
            $path = Join-Path $script:RepoRoot '.github' 'workflows' "$name.yml"
            $content = Get-Content -LiteralPath $path -Raw
            $content | Should -Match 'AZURE_LOCATION:\s*\$\{\{\s*inputs\.location\s*\|\|\s*vars\.AZURE_LOCATION\s*\}\}' `
                -Because "$name must resolve the environment variable when no explicit input is given"
        }
    }
}
