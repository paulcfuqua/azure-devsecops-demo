# =============================================================================
# Regression guard for F4 (compliance/findings/2026-08-26-prepublication-review.md#f4,
# Task 8): nothing in this repo should publish an ingestion credential — an App
# Insights connection string, a key, a secret — as a Bicep output, and no
# workflow should cat a full deployment manifest into $GITHUB_STEP_SUMMARY.
# Job summaries and uploaded artifacts on a public repo are readable without
# authentication; the manifest also carries the subscription ID embedded in
# every ARM resource ID (CLAUDE.md hard rule 5: that ID lives in GitHub
# environment variables and is never committed).
#
# Deliberately NOT the task brief's literal `infra/bicep/**/*.bicep` glob:
# PowerShell's wildcard provider resolves `**` as a LITERAL two-segment
# wildcard, not a bash-style recursive globstar, so that pattern matches only
# files exactly two path segments below infra/bicep/ — it misses
# infra/bicep/naming.bicep (one segment) and infra/bicep/apps/modules/*.bicep
# (three segments), which is exactly backwards for a test whose entire job is
# "no .bicep file anywhere leaks a secret". Get-ChildItem -Recurse is used
# instead so every .bicep file under infra/ is actually covered. Deliberately NOT the
# whole repository tree: compliance/tests/fixtures/ carries a valueless secret-shaped
# output on purpose, as a negative fixture for the repo-static collector.
#
# Also deliberately NOT the brief's literal `Key` alternative on its own: two
# entirely legitimate, non-secret outputs already exist —
# platform/main.bicep's `keyVaultUri` and `keyVaultResourceId` — and
# Select-String is case-insensitive by default, so `Key` matches the "Key" in
# "KeyVault" every time. Both are a resource locator for the Key Vault
# resource, never a secret value, and F4's fix for them is at the workflow
# layer (stop putting them in the public job summary/artifact), not deleting
# the Bicep output. `Key(?!Vault)` keeps the check's teeth everywhere else —
# `appInsightsConnectionString`, `storageAccountKey`, `mcpAuthTokenSecret` all
# still match — while not flagging a resource name that merely mentions the
# Key Vault *product*.
# =============================================================================

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..')).Path
    $script:BicepFiles = Get-ChildItem -Path (Join-Path -Path $script:RepoRoot -ChildPath 'infra') -Recurse -Filter '*.bicep'
    $script:WorkflowFiles = Get-ChildItem -Path (Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'workflows') -Filter '*.yml'
}

Describe 'deployment manifests leak nothing' {
    It 'no Bicep output name suggests a connection string, key, or secret' {
        $hits = $script:BicepFiles | Select-String -Pattern '^output\s+\w*(ConnectionString|Key(?!Vault)|Secret)\w*\s'
        $hits | Should -BeNullOrEmpty
    }

    It 'no workflow cats a manifest into the job summary' {
        $hits = $script:WorkflowFiles | Select-String -Pattern 'cat .*manifest\.json'
        $hits | Should -BeNullOrEmpty
    }
}
