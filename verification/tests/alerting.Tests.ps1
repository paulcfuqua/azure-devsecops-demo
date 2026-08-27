# =============================================================================
# F17 (compliance/findings/2026-08-26-prepublication-review.md#f17, Task 19): a
# grep for metricAlerts|scheduledQueryRules|actionGroups|activityLogAlert across
# every .bicep, .ps1 and .yml/.yaml file in the repo returned ZERO matches. F9
# (Task 13) wired diagnosticSettings for Key Vault and the SQL database to the
# Log Analytics workspace; nothing was ever subscribed to the result. This is
# the second half of F9 -- collection versus reaction.
#
# Scope discipline (this task's own brief): do not build a monitoring suite.
# Two rules, not three or four -- both map directly to the access-pattern
# findings this branch closed (F1 unauthenticated data-api, F2 inert MCP auth
# gate, F3 fail-open Direct Line token) generalised to the estate's two real
# credential-and-data surfaces:
#   - Key Vault AuditEvent denied-result spike (the vault holds the Direct
#     Line secret and mcp-auth-token)
#   - Azure SQL failed-login spike (the Entra-only server F13's workload
#     grants authenticate against)
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
# Both rules evaluate every 15 minutes -- the cheapest scheduled-query-rule
# frequency tier (sub-5-minute tiers cost several times more per
# azure.cn's published price list, the clearest public breakdown by tier)
# -- comfortably inside the $200/30-day credit and the workspace's 1 GB/day
# ingestion cap.
# =============================================================================

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..')).Path
    $script:MainBicepPath = Join-Path -Path $script:RepoRoot -ChildPath 'infra' -AdditionalChildPath 'bicep', 'platform', 'main.bicep'
    $script:MainBicep = Get-Content -LiteralPath $script:MainBicepPath -Raw
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

    It 'evaluates at the cheapest scheduled-query-rule frequency tier (15 minutes), not sub-5-minute' {
        ($script:MainBicep | Select-String "evaluationFrequency:\s*'PT15M'" -AllMatches).Matches.Count | Should -Be 2
        $script:MainBicep | Should -Not -Match "evaluationFrequency:\s*'PT1M'"
    }

    It 'does not duplicate a cost/usage-spike rule -- Task 17/F15 already covers that gap' {
        $script:MainBicep | Should -Not -Match 'Usage\s*\|\s*summarize'
    }
}
