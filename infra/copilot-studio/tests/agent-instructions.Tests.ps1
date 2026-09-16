# Pester tests for the Meridian Launch Copilot's INSTRUCTIONS - the agent's own system
# prompt. No tenant calls: everything here is committed text.
#
# WHY THESE EXIST. On 2026-09-16 the AWS Athena lakehouse was linked end to end at the MCP
# layer - `query_aws_lakehouse_sql` returned real launch-provider rows - and the published
# agent still would not use it. Nothing was broken in the connector. The agent's own
# instructions described ONE lakehouse and asserted that "all data is synthetic", so a tool
# whose description says it reads real external data contradicted a standing instruction,
# and instructions outrank tool descriptions. A tool is not available to an agent that has
# been told its data cannot exist.
#
# That defect was invisible to every check in the repository, because each of them asserts
# the ARTEFACT that usually accompanies the capability - the tool is advertised, the server
# answers, the solution imports - and none of them read the sentence that decides whether
# the agent will reach for it. These assertions read that sentence.
#
# THE SECOND CLASS THIS CATCHES IS DRIFT BETWEEN THE TWO COPIES. agent-definition.md
# section 2 is the documented source of truth; the solution botcomponent is what actually
# imports into Copilot Studio. Only the second one reaches the agent, so the first can be
# wrong indefinitely without anything failing - and it WAS: the solution had carried a
# money-precision rule and the whole `cost_daily` vs `get_cost_series` rule since
# 2026-09-02 (F138) and the markdown had neither. A specification that does not have to
# match the artefact is a comment.

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:DefinitionPath = Join-Path $script:Root 'infra/copilot-studio/agent-definition.md'
    $script:ComponentDir = Join-Path $script:Root `
        'infra/copilot-studio/solution/MeridianLaunchCopilot/botcomponents/mls_MeridianLaunchCopilot.gpt.default'
    $script:DataPath = Join-Path $script:ComponentDir 'data'
    $script:XmlPath = Join-Path $script:ComponentDir 'botcomponent.xml'
    $script:ToolRegistryPath = Join-Path $script:Root 'apps/mcp-tools/src/tools/index.ts'

    # The fenced ```text block in section 2 of the definition, verbatim.
    function Get-DocumentedInstructionText {
        $raw = Get-Content -LiteralPath $script:DefinitionPath -Raw
        $match = [regex]::Match($raw, '(?s)```text\r?\n(You are the Meridian Launch Copilot\..*?)\r?\n```')
        if (-not $match.Success) { return $null }
        $match.Groups[1].Value -replace "`r`n", "`n"
    }

    # The `instructions: |+` literal block from the solution component, de-indented.
    # Parsed by hand rather than with a YAML module so the suite needs no dependency the
    # CI image does not already install.
    function Get-ShippedInstructionText {
        $lines = (Get-Content -LiteralPath $script:DataPath -Raw) -replace "`r`n", "`n" -split "`n"
        $begin = [array]::IndexOf($lines, 'instructions: |+')
        if ($begin -lt 0) { return $null }
        $body = [System.Collections.Generic.List[string]]::new()
        for ($i = $begin + 1; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -eq '') { $body.Add(''); continue }
            # A non-empty line that is not indented ends the literal block.
            if ($line -notmatch '^  ') { break }
            $body.Add($line.Substring(2))
        }
        while ($body.Count -gt 0 -and $body[$body.Count - 1] -eq '') { $body.RemoveAt($body.Count - 1) }
        $body -join "`n"
    }
}

Describe 'the documented instructions and the shipped instructions are the same text' {
    It 'finds an instruction block in both places' {
        Get-DocumentedInstructionText | Should -Not -BeNullOrEmpty `
            -Because 'agent-definition.md section 2 is the human-readable source of truth for showpiece #1'
        Get-ShippedInstructionText | Should -Not -BeNullOrEmpty `
            -Because 'the solution botcomponent is what actually imports into Copilot Studio'
    }

    It 'matches character for character' {
        $documented = Get-DocumentedInstructionText
        $shipped = Get-ShippedInstructionText

        # Report the first divergent line rather than dumping 7 KB of prose twice.
        $a = $documented -split "`n"
        $b = $shipped -split "`n"
        $firstDiff = $null
        for ($i = 0; $i -lt [Math]::Max($a.Count, $b.Count); $i++) {
            $left = if ($i -lt $a.Count) { $a[$i] } else { '<absent>' }
            $right = if ($i -lt $b.Count) { $b[$i] } else { '<absent>' }
            if ($left -cne $right) {
                $firstDiff = "line $($i + 1): definition='$left' solution='$right'"
                break
            }
        }
        $firstDiff | Should -BeNullOrEmpty `
            -Because 'only the solution copy reaches the agent, so a definition that may differ from it is a comment, not a specification - edit both from one source (F138 drifted for a fortnight)'
    }
}

Describe 'the instructions tell the agent the truth about its two lakehouses' {
    BeforeAll { $script:Instructions = Get-ShippedInstructionText }

    It 'names both SQL tools' {
        # The agent cannot route to a tool whose name its instructions never mention.
        $script:Instructions | Should -Match 'query_lakehouse_sql' `
            -Because "Meridian's own operations lakehouse is reached only through this tool"
        $script:Instructions | Should -Match 'query_aws_lakehouse_sql' `
            -Because 'the AWS launch-intelligence lakehouse is reached through no other tool, in either configuration'
    }

    It 'never claims that all the data is synthetic' {
        # THE REGRESSION. This sentence was true until the AWS lakehouse was linked and is
        # now a standing instruction not to trust a tool that describes itself as real.
        $script:Instructions | Should -Not -Match '(?i)all\s+(the\s+)?data\s+is\s+synthetic' `
            -Because 'an agent told all its data is synthetic will not reach a tool whose description says otherwise - instructions outrank tool descriptions'
    }

    It 'keeps the honesty rule by stating BOTH halves' {
        # Corrected, not deleted: the rule exists so the agent never lets a reader believe
        # a fictional company is real. Splitting it must not drop either half.
        $script:Instructions | Should -Match '(?i)Meridian Launch Systems is fictional' `
            -Because 'the agent must still volunteer that Meridian is not a real company'
        $script:Instructions | Should -Match '(?i)synthetic' `
            -Because "Meridian's own operations data is synthetic and the agent must say so"
        $script:Instructions | Should -Match '(?i)real,?\s+public launch-industry data' `
            -Because 'the AWS launch-provider data is real and must not be disclaimed as synthetic'
    }

    It 'warns that the two weekday numberings are different' {
        # The tools disagree: Fabric pins 1=Sunday..7=Saturday, Trino's day_of_week is ISO
        # 1=Monday..7=Sunday. A weekday number carried across is wrong by one day and looks
        # entirely plausible, which is the worst kind of wrong this estate produces.
        $script:Instructions | Should -Match '(?i)1=Sunday' -Because "the Fabric tool's numbering must be stated"
        $script:Instructions | Should -Match '(?i)1=Monday' -Because "the AWS tool's ISO numbering must be stated"
        $script:Instructions | Should -Match '(?i)never carry' `
            -Because 'stating both numberings is not enough; the agent has to be told not to move a weekday number between them'
    }

    It 'tells the agent to ask rather than guess when a question fits either lakehouse' {
        # Both lakehouses hold a table called `launches`. Nothing in the shape of "how many
        # launches were there?" discriminates, so a silent choice is indistinguishable from
        # the right answer - which is why guessing is worse here than elsewhere.
        $script:Instructions | Should -Match '(?i)ambiguous' `
            -Because 'the collision has to be named before a rule about it can be followed'
        $script:Instructions | Should -Match '(?i)never guess|do not guess|you never guess' `
            -Because 'an ambiguous question gets asked about, not resolved by coin flip'
    }

    It 'does not pin a row count the upstream feed is free to change' {
        # The AWS lakehouse refreshes from an upstream feed. A magic number in the prompt
        # would be a fact with an expiry date, and the agent would defend it against the
        # tool. Describe the sources, not the answers.
        # Rule 4 illustrates floating-point residue with a currency figure, which is an
        # example of a FORMAT rather than a fact about either dataset. Remove every
        # currency literal first, then no comma-grouped number should survive.
        $withoutMoney = $script:Instructions -replace '\$[\d,]+(\.\d+)?', '<money>'
        $counts = @([regex]::Matches($withoutMoney, '\b\d{1,3}(,\d{3})+\b') | ForEach-Object { $_.Value })
        $counts -join ', ' | Should -BeNullOrEmpty `
            -Because 'a row count baked into the instructions goes stale the next time the feed refreshes, and the agent would then defend it against the tool'
    }

    It 'names only tools the server is allowed to expose' {
        # A prompt that invents a tool name produces an agent that tries to call it and
        # fails, which reads to a user exactly like the tool being broken.
        $registry = Get-Content -LiteralPath $script:ToolRegistryPath -Raw
        $block = [regex]::Match($registry, '(?s)ALLOWED_TOOL_NAMES\s*=\s*\[(.*?)\]')
        $block.Success | Should -BeTrue -Because 'the allowlist is the only declaration of what the server may expose'
        $allowed = @([regex]::Matches($block.Groups[1].Value, '"([a-z_]+)"') | ForEach-Object { $_.Groups[1].Value })
        $allowed.Count | Should -BeGreaterThan 0 -Because 'finding none means the array shape changed, not that the repo is clean'

        $named = @([regex]::Matches($script:Instructions, '`(query_[a-z_]+|get_[a-z_]+)`') |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $named.Count | Should -BeGreaterThan 0 -Because 'the instructions must name the tools they route to'
        $unknown = @($named | Where-Object { $_ -notin $allowed })
        $unknown -join ', ' | Should -BeNullOrEmpty `
            -Because 'every tool the prompt routes to has to be one the server is allowed to advertise'
    }

    It 'numbers the answering rules without repeating one' {
        # Two rules were both numbered 6 for a fortnight. Harmless to a reader, ambiguous to
        # a model being asked to follow "rule 6", and a signal that the block was edited in
        # two places by two people who never read it end to end.
        $numbers = @([regex]::Matches($script:Instructions, '(?m)^(\d+)\. ') | ForEach-Object { [int]$_.Groups[1].Value })
        $numbers.Count | Should -BeGreaterThan 0 -Because 'the How-to-answer rules are a numbered list'
        $duplicates = @($numbers | Group-Object | Where-Object Count -GT 1 | ForEach-Object Name)
        $duplicates -join ', ' | Should -BeNullOrEmpty -Because 'two rules sharing a number make "rule 6" ambiguous'
        ($numbers -join ',') | Should -Be ((1..$numbers.Count) -join ',') `
            -Because 'the rules are consecutive from 1'
    }

    It 'fits the Copilot Studio instructions field' {
        # Copilot Studio caps the Instructions field at 8,000 characters. Over it, the
        # portal truncates on save - and what gets cut is the end of the prompt, which is
        # where Out-of-scope and the refusal rules live.
        $script:Instructions.Length | Should -BeLessThan 8000 `
            -Because 'a prompt the portal truncates loses its last rules silently'
    }
}

Describe 'the component description tells the same story as the instructions' {
    # The description is what a maker sees in the portal and what the orchestrator of a
    # parent agent would route on. It carried the same blanket synthetic claim.
    BeforeAll {
        $script:Description = ([xml](Get-Content -LiteralPath $script:XmlPath -Raw)).botcomponent.description
    }

    It 'is well-formed XML with a description' {
        $script:Description | Should -Not -BeNullOrEmpty
    }

    It 'does not claim all the data is synthetic' {
        $script:Description | Should -Not -Match '(?i)all\s+(the\s+)?data\s+is\s+synthetic' `
            -Because 'the same false claim in a second place is the same defect, and this copy is the one a maker reads'
    }

    It 'mentions both lakehouses' {
        $script:Description | Should -Match '(?i)mls_operations' -Because "Meridian's own lakehouse is still the primary source"
        $script:Description | Should -Match '(?i)AWS' -Because 'the second lakehouse exists and the description is where a maker learns it does'
    }
}
