# =============================================================================
# F17 (compliance/findings/2026-08-26-prepublication-review.md#f17, Task 19): a
# grep for metricAlerts|scheduledQueryRules|actionGroups|activityLogAlert across
# every .bicep, .ps1 and .yml/.yaml file in the repo returned ZERO matches. F9
# (Task 13) wired diagnosticSettings for Key Vault and the SQL database to the
# Log Analytics workspace; nothing was ever subscribed to the result. This is
# the second half of F9 -- collection versus reaction.
#
# Scope discipline (this task's own brief): do not build a monitoring suite.
# Two rules, not three or four -- both named verbatim by F17's own Fix text
# ("Key Vault access-denied spikes, SQL failed-login spikes"), which is their
# justification:
#   - Key Vault AuditEvent denied-result spike (the vault holds the Direct
#     Line secret and mcp-auth-token)
#   - Azure SQL failed-login spike (the Entra-only server F13's workload
#     grants authenticate against)
#
# NOT covered by either rule: F1 (unauthenticated data-api), F2 (inert MCP
# auth gate) and F3 (fail-open Direct Line token) are app-layer authentication
# bypasses -- an unauthenticated caller reaches the app, and the app's OWN
# already-privileged managed identity then talks to Key Vault and SQL
# successfully, with no access-denied event and no failed login anywhere in
# that path. Neither rule would ever fire for that exploit class; they detect
# a narrower, different signal (direct probing/misconfiguration against Key
# Vault and SQL), not F1-F3 coverage.
#
# Deliberately NOT added:
#   - Container Apps restart counts (the brief's own suggestion). The
#     individual container app resources a meaningful restart metric would
#     attach to do not exist at L6 -- they deploy at L7 (apps/main.bicep) --
#     so a metricAlert cannot be authored here without an app resource id
#     this template never sees, and a log-based proxy at the environment
#     scope has no Microsoft-documented column/category contract precise
#     enough to write with confidence absent a live workspace to check it
#     against.
#   - A KQL-approximated cost/usage-spike rule. Task 17/F15 already added
#     Forecasted (same-day) budget notifications for exactly this gap; a
#     second, approximate mechanism would be redundant noise against an
#     existing, purpose-built one.
#
# Both rules evaluate every 15 minutes. Azure's scheduled-query-rule cost
# boundary sits at 5 minutes -- any interval >= 5 minutes is flat-priced, and
# only sub-5-minute frequencies cost materially more (per azure.cn's published
# price list, the clearest public breakdown by tier). 15 minutes sits inside
# that flat band, not at some specially cheap point within it, comfortably
# inside the $200/30-day credit and the workspace's 1 GB/day ingestion cap.
#
# F17 also requires the action group's email receiver to be discoverable, not
# just deployable-but-empty: MLS_ALERT_EMAIL must be documented in the G0
# runbook's "Optional tuning" table (docs/runbooks/g0-bootstrap.md), the same
# convention every other optional deploy-time env var in this repo follows
# (SQL_AAD_ADMIN_LOGIN, KEY_VAULT_CREATE_MODE). A review round caught a first
# pass of this task that left it undocumented -- the action group would have
# deployed with emailReceivers: [] and fired into nothing, while the register
# said the gap was closed.
# =============================================================================

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..')).Path
    $script:MainBicepPath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'platform', 'main.bicep'
    $script:MainBicep = Get-Content -LiteralPath $script:MainBicepPath -Raw
    $script:G0Path = Join-Path -Path $script:RepoRoot -ChildPath 'docs' -AdditionalChildPath 'runbooks', 'g0-bootstrap.md'
    $script:G0 = Get-Content -LiteralPath $script:G0Path -Raw
}

Describe 'platform alerting on the signals F9 collects (F17)' {
    It 'defines exactly one action group' {
        ($script:MainBicep | Select-String "br/public:avm/res/insights/action-group" -AllMatches).Matches.Count | Should -Be 1
    }

    It 'defines exactly two scheduled query rules -- not a monitoring suite' {
        ($script:MainBicep | Select-String "br/public:avm/res/insights/scheduled-query-rule" -AllMatches).Matches.Count | Should -Be 2
    }

    It 'alerts on Key Vault AuditEvent denied-result spikes' {
        $script:MainBicep | Should -Match 'MICROSOFT\.KEYVAULT'
        $script:MainBicep | Should -Match 'AuditEvent'
        $script:MainBicep | Should -Match 'httpStatusCode_d\s*>=\s*300'
    }

    It 'alerts on Azure SQL failed-login spikes' {
        $script:MainBicep | Should -Match 'SQLSecurityAuditEvents'
        $script:MainBicep | Should -Match 'succeeded_s\s*==\s*"false"'
    }

    It 'scopes both rules at the Log Analytics workspace F9 routes diagnostics to' {
        $matches = [regex]::Matches($script:MainBicep, 'scopes:\s*\[[^\]]*\]')
        $matches.Count | Should -Be 2
        foreach ($m in $matches) {
            $m.Value | Should -Match 'logAnalytics\.outputs\.resourceId'
        }
    }

    It 'wires both rules to the action group, not a silent alert nobody receives' {
        ($script:MainBicep | Select-String 'alertActionGroup\.outputs\.resourceId' -AllMatches).Matches.Count | Should -BeGreaterOrEqual 2
    }

    It 'evaluates inside the flat-priced frequency band (15 minutes), not the costlier sub-5-minute tier' {
        ($script:MainBicep | Select-String "evaluationFrequency:\s*'PT15M'" -AllMatches).Matches.Count | Should -Be 2
        $script:MainBicep | Should -Not -Match "evaluationFrequency:\s*'PT1M'"
    }

    It 'does not duplicate a cost/usage-spike rule -- Task 17/F15 already covers that gap' {
        $script:MainBicep | Should -Not -Match 'Usage\s*\|\s*summarize'
    }

    It 'does not claim F1/F2/F3 detection coverage -- those are app-layer bypasses neither rule can see' {
        # F1/F2/F3 succeed via the app's own already-privileged managed identity
        # against Key Vault/SQL -- no denial, no failed login, so no comment in
        # this template may claim either rule covers them.
        $script:MainBicep | Should -Not -Match 'F1 unauthenticated data-api'
    }
}

Describe 'the action group email receiver is discoverable, not deployable-but-empty (F17)' {
    It 'documents MLS_ALERT_EMAIL in the G0 runbook''s Optional tuning table' {
        $script:G0 | Should -Match '\|\s*`MLS_ALERT_EMAIL`\s*\|'
    }

    It 'states what leaving it unset costs -- the action group deploys with zero receivers' {
        # Same row, not just somewhere in the document: an operator reading only
        # the table must learn the consequence, not go hunting for it.
        $lines = @($script:G0 -split "`n")
        $matching = @($lines | Where-Object { $_ -match 'MLS_ALERT_EMAIL' })
        $matching.Count | Should -Be 1
        $matching[0] | Should -Match '(?i)zero receivers'
    }
}
