#Requires -Version 7.0
<#
.SYNOPSIS
    L8 Verifier audit - the Copilot Studio agent (showpiece #1). READ-ONLY.

.DESCRIPTION
    Implements the five master-plan Verify criteria owned by
    docs/runbooks/layers/L08.md section Validation cycle, and nothing else:

      V8.1  Deployed agent's solution unique name + version + component list match the
            committed solution exactly, and its published state is current.
      V8.2  Eval suite passes >= 9/10 against the deployed agent, with each answer's
            number independently re-derived by the Verifier from the lakehouse.
      V8.3  No tool invoked outside the tool allowlist and the agent declares exactly
            those tools. The master plan wrote "five-tool allowlist" in 2026-08-22, when
            there were five; the 2026-08-26 compliance-platform design added a sixth,
            query_compliance (apps/mcp-tools/tests/allowlist.test.ts pins the server at
            exactly six). The criterion is unchanged - no tool outside the DECLARED
            allowlist - so -AllowedTool below carries six names, and a deployed server
            advertising the old five would now fail this criterion for being short.
      V8.4  Every visual answer is an Adaptive Card payload that validates against the
            pinned Adaptive Cards schema; zero HTML/JS/JSX in any response.
      V8.5  p95 latency < 20 s.

    NOTHING IN THIS LAYER EXISTS BEFORE L8 DEPLOYS: Copilot Studio is cloud-only, the
    Power Platform environment and Direct Line channel arrive at L8, and the Fabric data
    agent additionally needs paid F2 capacity (the 60-day trial explicitly does not
    support data agents). Each criterion therefore records a clearly labelled SKIP with
    its reason when its evidence does not exist yet - never a pass. Evidence that exists
    but is wrong is a FAIL.

    The Verifier consumes the eval artifact as CLAIMS and re-derives the facts itself:
    V8.2 re-runs the eval fixture's pinned reference SQL on the lakehouse as mls-verifier
    (workspace Viewer, granted at L5). On the Fabric data-agent path the agent's own SQL
    is generated inside Fabric and never exposed, which is exactly why truth is
    re-derived from the seed rather than from the agent.

.EXAMPLE
    ./layer-08-audit.ps1 -EnvironmentUrl https://org.crm.dynamics.com -EvalResultPath ./agent-eval-results.json
#>
[CmdletBinding()]
param(
    [string]$EnvironmentUrl,
    [string]$DataverseToken,
    [string]$SolutionPath,
    [string]$EvalResultPath,
    [string]$McpServerUrl,
    # The allowlist the deployed MCP server must advertise, exactly. Kept in step with
    # apps/mcp-tools/src/tools/index.ts; query_compliance is the sixth (compliance-platform
    # design 2026-08-26 section 5.3). Test-ToolAllowlist below compares as a SET, so a name
    # missing here fails the criterion just as loudly as an extra one on the server.
    [string[]]$AllowedTool = @(
        'query_lakehouse_sql', 'query_log_analytics', 'get_github_security',
        'get_defender_posture', 'get_cost_series', 'query_compliance'
    ),
    [string]$AdaptiveCardVersion = '1.5',
    [double]$LatencyBudgetSeconds = 20,
    [int]$EvalPassBar = 9,
    [string]$SqlEndpoint,
    # Entra token for https://database.windows.net, used by V8.2's re-derivation. Omit it in
    # CI and pass $env:MLS_SQL_ACCESS_TOKEN instead - process arguments are visible on the
    # runner - or omit both and MlsAudit mints one from the mls-verifier login.
    [string]$SqlAccessToken,
    [string]$LakehouseName = 'mls_operations',
    [string]$ReportRoot,
    [switch]$NoRetry,
    # Run only these criteria (e.g. -OnlyCriterion V8.2). Everything else reports SKIP
    # naming the reason, and the run exits 3 - a DIAGNOSTIC, never a sign-off (P-10).
    [string[]]$OnlyCriterion = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'MlsAudit.psm1') -Force

function Get-CommittedSolution {
    <#
    .SYNOPSIS
        The unpacked solution in the repo, read as the THREE files that between them
        name every component Dataverse will report (F145).

    .DESCRIPTION
        V8.1 used to build its expected set from `Other/Solution.xml`'s RootComponents
        alone. That file lists ONE component - the connector - while Dataverse's
        msdyn_solutioncomponentsummaries reports seventeen, because a Copilot Studio
        agent's topics are components of the solution without being roots of it. Set
        equality between those two lists could never hold, so V8.1 reported

            components missing [] extra [Conversation Start, Fallback, Greeting, ...]

        on a perfectly correct deployment: sixteen confident, specific, WRONG names a
        reader would go hunting for. The register recorded the cause as a missing
        Verifier permission, which it never was - the read succeeded every time.

        The committed side is fully enumerable, and this is where it lives:

          Other/Solution.xml                          RootComponent/@schemaName  (1)
          botcomponents/<x>/botcomponent.xml          <name>                     (15)
          Assets/botcomponent_connectionreferenceset.xml
                                    @connectionreferenceid.connectionreferencelogicalname (1)

        `<name>` is the display name Dataverse returns verbatim in msdyn_name - down to
        the trailing space in 'Sign in ' - so the comparison is exact rather than
        normalised. Reading all three makes the check STRONGER than it was ever able to
        be: it now covers all fifteen topics and the connection reference, where before
        it covered the connector and nothing else.

        Returns $null when the manifest is absent. `ComponentReadable` is $false when the
        manifest parsed but the component files could not be enumerated - the caller must
        report that as unobservable rather than comparing against a short list, because
        a truncated expected set turns every deployed component into an "extra".
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    [xml]$document = Get-Content -LiteralPath $Path -Raw
    # XPath rather than property access: an unpacked Solution.xml omits attributes freely,
    # and Set-StrictMode turns a missing property into a terminating error.
    $uniqueNameNode = $document.SelectSingleNode('//SolutionManifest/UniqueName')
    $versionNode = $document.SelectSingleNode('//SolutionManifest/Version')
    $component = [System.Collections.Generic.List[string]]::new()
    $rootComponent = [System.Collections.Generic.List[string]]::new()
    foreach ($node in $document.SelectNodes('//SolutionManifest/RootComponents/RootComponent')) {
        $name = $node.GetAttribute('schemaName')
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $node.GetAttribute('id') }
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $component.Add($name)
            $rootComponent.Add($name)
        }
    }
    $connectionReference = [System.Collections.Generic.List[string]]::new()

    # Other/Solution.xml -> the solution folder that contains it.
    $solutionFolder = Split-Path -Parent (Split-Path -Parent $Path)
    $readable = $true

    $botComponentDir = Join-Path -Path $solutionFolder -ChildPath 'botcomponents'
    if (Test-Path -LiteralPath $botComponentDir) {
        $files = @(Get-ChildItem -LiteralPath $botComponentDir -Filter 'botcomponent.xml' -Recurse -File)
        if ($files.Count -eq 0) { $readable = $false }
        foreach ($file in $files) {
            try {
                [xml]$bot = Get-Content -LiteralPath $file.FullName -Raw
                $nameNode = $bot.SelectSingleNode('//botcomponent/name')
                # InnerText, NOT a trim: Dataverse returns 'Sign in ' with its trailing
                # space and the comparison is exact. Normalising here would hide a real
                # rename behind a cosmetic one.
                if ($nameNode -and -not [string]::IsNullOrWhiteSpace($nameNode.InnerText)) {
                    $component.Add($nameNode.InnerText)
                }
            } catch {
                $readable = $false
            }
        }
    } else {
        $readable = $false
    }

    $connectionFile = Join-Path -Path $solutionFolder -ChildPath 'Assets' -AdditionalChildPath 'botcomponent_connectionreferenceset.xml'
    if (Test-Path -LiteralPath $connectionFile) {
        try {
            [xml]$connections = Get-Content -LiteralPath $connectionFile -Raw
            foreach ($node in $connections.SelectNodes('//botcomponent_connectionreference')) {
                $logical = $node.GetAttribute('connectionreferenceid.connectionreferencelogicalname')
                if (-not [string]::IsNullOrWhiteSpace($logical)) {
                    $component.Add($logical)
                    $connectionReference.Add($logical)
                }
            }
        } catch {
            $readable = $false
        }
    }

    return [pscustomobject]@{
        UniqueName          = $(if ($uniqueNameNode) { $uniqueNameNode.InnerText } else { '' })
        Version             = $(if ($versionNode) { $versionNode.InnerText } else { '' })
        # Everything, for V8.1's set equality against what Dataverse reports.
        Component           = @($component)
        # The EXTERNAL ATTACHMENTS, for V8.3. Kept separate on purpose: V8.3 asks how many
        # connectors and agents the solution declares, and once Component carried topic
        # DISPLAY names a topic called 'Meridian Ops Tools' counted as a tool. Widening one
        # check's input silently widened another's - the two questions need two lists.
        RootComponent       = @($rootComponent)
        ConnectionReference = @($connectionReference)
        ComponentReadable   = $readable
    }
}

function Test-DeployedSolution {
    <# V8.1 - unique name and version identical, component set equal, no unmanaged layer.
       An unmanaged layer means somebody edited the agent in the browser after the
       pipeline imported it, which fails principle 1 and fails this criterion. #>
    param(
        [AllowNull()]$Committed,
        [AllowEmptyString()][string]$EnvironmentUrl,
        [AllowNull()][hashtable]$Header
    )
    if ($null -eq $Committed) {
        return New-MlsCheckResult -Status 'SKIP' -Observed 'no committed solution found' `
            -Detail 'infra/copilot-studio/solution/ still holds only its .gitkeep placeholder: the agent solution has not been exported into the repo yet (L8 deploy step 3 does that through the copilot-alm-starter pattern). Nothing to compare a deployment against.'
    }
    if ([string]::IsNullOrWhiteSpace($EnvironmentUrl)) {
        return New-MlsCheckResult -Status 'SKIP' `
            -Observed "committed solution $($Committed.UniqueName) v$($Committed.Version) with $(@($Committed.Component).Count) component(s); no deployed environment to compare against" `
            -Detail 'No Power Platform environment URL supplied (-EnvironmentUrl / $env:MLS_POWER_PLATFORM_ENV_URL). The agent is a G0 item C5 prerequisite and does not exist before L8 deploys.'
    }
    $solutions = @(Get-MlsCollection -Response (Invoke-MlsRest -Header $Header `
                -Uri "$EnvironmentUrl/api/data/v9.2/solutions?`$filter=uniquename eq '$($Committed.UniqueName)'"))
    if ($solutions.Count -eq 0) {
        return New-MlsCheckResult -Passed $false `
            -Observed "no solution with uniquename '$($Committed.UniqueName)' in $EnvironmentUrl" `
            -Detail 'The import did not land, or it landed under a different unique name.'
    }
    $deployed = $solutions[0]
    $deployedVersion = "$(Get-MlsProperty -InputObject $deployed -Name 'version')"
    $solutionId = "$(Get-MlsProperty -InputObject $deployed -Name 'solutionid')"
    $components = @(Get-MlsCollection -Response (Invoke-MlsRest -Header $Header `
                -Uri "$EnvironmentUrl/api/data/v9.2/msdyn_solutioncomponentsummaries?`$filter=msdyn_solutionid eq $solutionId"))
    # Compared by component NAME: the repo carries schema names, Dataverse carries
    # msdyn_name, and the type vocabularies differ between the two representations.
    $deployedComponent = @($components | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'msdyn_name')" } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $unmanaged = @($components | Where-Object {
            $layer = Get-MlsProperty -InputObject $_ -Name 'msdyn_iscustomizable'
            $hasLayer = Get-MlsProperty -InputObject $_ -Name 'msdyn_unmanagedlayer'
            $hasLayer -eq $true -or "$layer" -eq 'unmanaged'
        })
    $problem = [System.Collections.Generic.List[string]]::new()
    if ($deployedVersion -ne $Committed.Version) { $problem.Add("version deployed=$deployedVersion committed=$($Committed.Version)") }

    # AN AUDIT THAT CANNOT SEE A THING SAYS SO; it never reports the thing as absent, and
    # it never reports what it could not enumerate as unexpected. A truncated expected set
    # makes every deployed component an "extra" - which is exactly how V8.1 spent a week
    # naming sixteen legitimate topics as though they were drift (F145).
    if (-not $Committed.ComponentReadable) {
        $problem.Add('UNOBSERVABLE: the committed component files could not be enumerated, so the deployed set cannot be compared against anything')
    } elseif (@($Committed.Component).Count -eq 0) {
        $problem.Add('UNOBSERVABLE: the committed solution declares no components, which is not a state this solution can legitimately be in')
    } else {
        $comparison = Test-MlsSetEquality -Actual $deployedComponent -Expected @($Committed.Component)
        if (-not $comparison.Equal) {
            $problem.Add("components missing [$($comparison.Missing -join ', ')] extra [$($comparison.Extra -join ', ')]")
        }
    }
    if ($unmanaged.Count -gt 0) {
        $problem.Add("$($unmanaged.Count) component(s) carry an unmanaged layer - the agent was edited in the browser after import")
    }
    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true `
            -Observed "uniquename=$($Committed.UniqueName) version=$deployedVersion components=$($deployedComponent.Count), no unmanaged layer"
    }
    return New-MlsCheckResult -Passed $false -Observed ($problem -join ' | ') `
        -Detail 'Never fix this in the browser: a portal edit makes the eval pass and V8.1 fail, and it breaks the demo''s central claim (L08.md Rollback).'
}

function Get-EvalArtifact {
    <# The eval run's artifact, as claims to be re-derived. #>
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    return Get-MlsJsonFile -Path $Path -Purpose 'L8 eval run artifact (eval-results.json from copilot-eval.yml)'
}

function Test-EvalArtifactIsAgentRun {
    <# The tools-only harness (npm run eval) writes a superficially similar artifact. It
       proves the tool surface, not the agent, so it must not satisfy V8.2. #>
    param([Parameter(Mandatory)]$Artifact)
    $mode = "$(Get-MlsProperty -InputObject $Artifact -Name 'mode')"
    $path = "$(Get-MlsProperty -InputObject $Artifact -Name 'path')"
    return ($mode -eq 'agent' -or $path -in @('fabric-data-agent', 'mcp-tools-only'))
}

function Test-EvalSuite {
    <# V8.2 - two independent checks per question: the agent's answer equals the golden
       expectation, and the Verifier re-derives the number itself from the lakehouse. #>
    param(
        [AllowNull()]$Artifact,
        [Parameter(Mandatory)][int]$PassBar,
        [AllowEmptyString()][string]$SqlEndpoint,
        [AllowEmptyString()][AllowNull()][string]$SqlAccessToken,
        [Parameter(Mandatory)][string]$LakehouseName
    )
    if ($null -eq $Artifact) {
        return New-MlsCheckResult -Status 'SKIP' -Observed 'no eval artifact' `
            -Detail 'copilot-eval.yml has not produced an agent eval artifact yet (apps/mcp-tools/evals/run-agent.ts is the placeholder that lands with L8, and it refuses to fake a run). Pass -EvalResultPath / $env:MLS_EVAL_RESULTS once the deployed agent has been evaluated over Direct Line.'
    }
    if (-not (Test-EvalArtifactIsAgentRun -Artifact $Artifact)) {
        return New-MlsCheckResult -Passed $false `
            -Observed "the artifact is not an agent run (mode='$(Get-MlsProperty -InputObject $Artifact -Name 'mode')')" -Final `
            -Detail 'This looks like the tools-only harness output (npm run eval), which proves the MCP tool surface, not the deployed agent. V8.2 measures the agent over Direct Line.'
    }
    if ([string]::IsNullOrWhiteSpace($SqlEndpoint)) {
        return New-MlsCheckResult -Status 'SKIP' `
            -Observed "artifact reports $(Get-MlsProperty -InputObject $Artifact -Name 'passed')/$(Get-MlsProperty -InputObject $Artifact -Name 'total') passing" `
            -Detail 'The criterion requires the Verifier to re-derive every number from the lakehouse itself, and no SQL analytics endpoint was available (-SqlEndpoint / $env:MLS_SQL_ENDPOINT, capacity resumed). Accepting the artifact''s own score would be trusting the claim the criterion exists to check.'
    }
    $questions = @(Get-MlsProperty -InputObject $Artifact -Name 'questions')
    if ($questions.Count -eq 0) {
        return New-MlsCheckResult -Passed $false -Observed 'the eval artifact carries no questions' -Final
    }
    $passing = 0
    $problem = [System.Collections.Generic.List[string]]::new()
    foreach ($question in $questions) {
        $id = "$(Get-MlsProperty -InputObject $question -Name 'id')"
        $claimed = [bool](Get-MlsProperty -InputObject $question -Name 'pass')
        $answer = "$(Get-MlsProperty -InputObject $question -Name 'answer')$(Get-MlsProperty -InputObject $question -Name 'responseText')"
        $card = Get-MlsProperty -InputObject $question -Name 'card'
        if ($card) { $answer += ($card | ConvertTo-Json -Depth 12 -Compress) }
        $referenceSql = "$(Get-MlsProperty -InputObject $question -Name 'referenceSql')"
        if ([string]::IsNullOrWhiteSpace($referenceSql)) {
            $problem.Add("$id has no referenceSql for the Verifier to re-derive from")
            continue
        }
        $rows = @(Invoke-MlsSqlQuery -ServerName $SqlEndpoint -DatabaseName $LakehouseName -Query $referenceSql -AccessToken $SqlAccessToken)
        if ($rows.Count -eq 0) {
            $problem.Add("$id reference SQL returned no rows")
            continue
        }
        $firstRow = $rows[0]
        $derived = @($firstRow.PSObject.Properties | ForEach-Object { "$($_.Value)" })
        $agrees = $true
        foreach ($value in $derived) {
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            if ($answer -notlike "*$value*") { $agrees = $false }
        }
        if ($claimed -and $agrees) { $passing++ }
        elseif (-not $claimed) { $problem.Add("$id marked failing by the eval run") }
        else { $problem.Add("$($id): the agent's answer does not carry the Verifier-re-derived value(s) [$($derived -join ', ')]") }
    }
    $observed = "$passing of $($questions.Count) questions pass both checks (agent answer + Verifier re-derivation)"
    if ($passing -ge $PassBar) {
        return New-MlsCheckResult -Passed $true -Observed $observed -Detail (($problem | Select-Object -First 3) -join ' | ')
    }
    return New-MlsCheckResult -Passed $false -Observed ($observed + ' | ' + ($problem -join ' | ')) -Final `
        -Detail 'Answer-content failures are not retried away - nondeterminism on deterministic questions is itself a defect (L08.md V8.2). Never loosen the golden expectations to pass.'
}

function Test-ToolAllowlist {
    <# V8.3 - runtime plus static, both required. #>
    param(
        [AllowNull()]$Artifact,
        [AllowEmptyString()][string]$McpServerUrl,
        [Parameter(Mandatory)][string[]]$AllowedTool,
        [AllowNull()]$Committed
    )
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()
    $checked = 0

    if ($null -ne $Artifact) {
        $checked++
        $invoked = @(Get-MlsProperty -InputObject $Artifact -Name 'questions' | ForEach-Object {
                @(Get-MlsProperty -InputObject $_ -Name 'toolCalls') | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'name')" }
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $outside = @($invoked | Where-Object { $_ -notin $AllowedTool } | Sort-Object -Unique)
        $observed.Add("runtime: $($invoked.Count) tool call(s) across the eval trace")
        if ($outside.Count -gt 0) { $problem.Add("tools invoked outside the allowlist: $($outside -join ', ')") }
    }

    if (-not [string]::IsNullOrWhiteSpace($McpServerUrl)) {
        # READ FROM /healthz, NOT tools/list. Everything under MCP_PATH is behind the
        # shared-secret gate, so this half used to 401 - an anonymous probe of an
        # authenticated endpoint, F89's shape a second time (F100).
        #
        # The fix is not to hand the Verifier `mcp-auth-token`. That token is compared
        # with timingSafeEqual: it IS the capability, and an auditor holding a working
        # credential for the thing it audits is a far bigger concession than this
        # criterion is worth. /healthz is unauthenticated BY DESIGN, for exactly this -
        # apps/mcp-tools/src/app.ts says it is "what lets the L7/L8 audits assert from
        # outside" - and it now publishes the declared tool names beside the count.
        $checked++
        $health = "$McpServerUrl" -replace '/[^/]*$', '/healthz'
        $response = Invoke-MlsHttp -Uri $health -TimeoutSec 30
        $status = "$(Get-MlsProperty -InputObject $response -Name 'StatusCode')"
        if ($status -ne '200') {
            $problem.Add("GET /healthz returned $status, so the declared tool set could not be read")
        }
        else {
            $payload = "$(Get-MlsProperty -InputObject $response -Name 'Content')" | ConvertFrom-Json
            $advertised = @(Get-MlsProperty -InputObject $payload -Name 'toolNames')
            if ($advertised.Count -eq 0) {
                # An older image predates the toolNames field. Say which, rather than
                # reporting an empty set as "the server declares no tools".
                $problem.Add("GET /healthz carries no toolNames field (deployed image predates F100); the declared tool set could not be read")
            }
            else {
                $comparison = Test-MlsSetEquality -Actual $advertised -Expected $AllowedTool
                $observed.Add("declared: $($advertised.Count) tool(s)")
                if (-not $comparison.Equal) {
                    $problem.Add("declared set missing [$($comparison.Missing -join ', ')] extra [$($comparison.Extra -join ', ')]")
                }
            }
        }
    }

    if ($null -ne $Committed) {
        $checked++
        # Roots and connection references only - NOT the full component set, which
        # carries every topic's display name (F145).
        $toolComponent = @(@($Committed.RootComponent) + @($Committed.ConnectionReference) |
                Where-Object { $_ -match '(?i)connector|connection|tool|agent' })
        $observed.Add("solution declares $($toolComponent.Count) tool/connector component(s)")
        if ($toolComponent.Count -gt 2) {
            $problem.Add("the solution declares $($toolComponent.Count) tool/connector/agent components; expected the one MCP connection and, on the Fabric path, the single connected data agent")
        }
    }

    if ($problem.Count -gt 0) {
        return New-MlsCheckResult -Passed $false -Observed (($observed -join '; ') + ' | ' + ($problem -join ' | ')) -Final
    }
    if ($checked -eq 0) {
        return New-MlsCheckResult -Status 'SKIP' -Observed 'neither an eval trace, a reachable MCP server, nor a committed solution' `
            -Detail 'V8.3 needs at least one of: the eval artifact (runtime half), the deployed MCP server URL (-McpServerUrl / $env:MLS_MCP_SERVER_URL), or the exported solution. None exists before L8 deploys.'
    }
    if ($null -eq $Artifact) {
        # The criterion is runtime AND static, both required. Passing on the static halves
        # alone would claim "no tool invoked outside the allowlist" with no invocations
        # ever observed - green by omission.
        return New-MlsCheckResult -Status 'SKIP' -Observed (($observed -join '; ') + ' - static halves only') `
            -Detail 'No eval trace, so the runtime half ("no tool INVOKED outside the allowlist") could not be checked. The static halves that were available are recorded above and raised no problem.'
    }
    return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ') `
        -Detail "Checked $checked of the 3 halves (runtime trace, tools/list, solution declaration)."
}

function Test-AdaptiveCardAnswer {
    <# V8.4 - every visual answer validates against the pinned profile, and no response
       carries generated UI code. A single generated-UI response fails outright: that is
       the governance claim the demo makes on stage. #>
    param(
        [AllowNull()]$Artifact,
        [Parameter(Mandatory)][string]$Version
    )
    if ($null -eq $Artifact) {
        return New-MlsCheckResult -Status 'SKIP' -Observed 'no eval artifact' `
            -Detail 'Card payloads are recorded by the eval run against the deployed agent; none exists yet. The card BUILDERS are already unit-tested against the pinned 1.5 schema in apps/mcp-tools (L08.md Deferred validation).'
    }
    $questions = @(Get-MlsProperty -InputObject $Artifact -Name 'questions')
    $cardCount = 0
    $problem = [System.Collections.Generic.List[string]]::new()
    foreach ($question in $questions) {
        $id = "$(Get-MlsProperty -InputObject $question -Name 'id')"
        $card = Get-MlsProperty -InputObject $question -Name 'card'
        if ($null -ne $card) {
            $cardCount++
            $validation = Test-MlsAdaptiveCard -Card $card -Version $Version
            if (-not $validation.Valid) { $problem.Add("$id card: $($validation.Problem -join '; ')") }
        }
        $response = "$(Get-MlsProperty -InputObject $question -Name 'answer')$(Get-MlsProperty -InputObject $question -Name 'responseText')"
        if (Test-MlsGeneratedUi -Text $response) { $problem.Add("$id response contains generated UI code") }
    }
    if ($questions.Count -gt 0 -and $cardCount -eq 0) {
        return New-MlsCheckResult -Passed $false -Observed 'no Adaptive Card payload was recorded for any question' -Final `
            -Detail 'Every visual answer must be a card; an eval artifact with none means the surface was not exercised or cards were not captured.'
    }
    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed "$cardCount card(s) valid against the pinned $Version profile; no HTML/JS/JSX in any response"
    }
    return New-MlsCheckResult -Passed $false -Observed ($problem -join ' | ') -Final `
        -Detail 'The repo pins schema 1.5 and Action.Submit so one payload renders identically in the Web Chat embed and in Teams (L08.md V8.4).'
}

function Test-LatencyBudget {
    <# V8.5 - p95 over the eval suite's per-question end-to-end latencies. #>
    param(
        [AllowNull()]$Artifact,
        [Parameter(Mandatory)][double]$BudgetSeconds
    )
    if ($null -eq $Artifact) {
        return New-MlsCheckResult -Status 'SKIP' -Observed 'no eval artifact' `
            -Detail 'p95 is computed over the eval run''s per-question latencies (Direct Line activity posted -> final agent activity received); no controlled sample exists before the agent is deployed.'
    }
    $latency = @(Get-MlsProperty -InputObject $Artifact -Name 'questions' |
            ForEach-Object { Get-MlsProperty -InputObject $_ -Name 'latencySeconds' } |
            Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($latency.Count -eq 0) {
        return New-MlsCheckResult -Passed $false -Observed 'the eval artifact records no per-question latency' -Final
    }
    $p95 = Get-MlsPercentile -Value $latency -Percentile 0.95
    $path = "$(Get-MlsProperty -InputObject $Artifact -Name 'path')"
    if ($p95 -lt $BudgetSeconds) {
        return New-MlsCheckResult -Passed $true -Observed "p95 = $([math]::Round($p95, 2))s over $($latency.Count) questions (path: $path)" `
            -Detail 'The Fabric data-agent path adds an agent-to-agent hop the tools-only path does not, so the report names the path the number describes.'
    }
    return New-MlsCheckResult -Passed $false -Observed "p95 = $([math]::Round($p95, 2))s over $($latency.Count) questions (path: $path), budget $BudgetSeconds s" `
        -Detail 'A breach on a clean run - capacity resumed, MCP container warm, conversation already open - is a FAIL, not a retry (L08.md V8.5).'
}

function Invoke-Main {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is consumed inside the criterion scriptblocks; PSSA cannot see through scriptblock closures.')]
    param(
        [string]$EnvironmentUrl,
        [string]$DataverseToken,
        [string]$SolutionPath,
        [string]$EvalResultPath,
        [string]$McpServerUrl,
        [string[]]$AllowedTool = @(),
        [string]$AdaptiveCardVersion = '1.5',
        [double]$LatencyBudgetSeconds = 20,
        [int]$EvalPassBar = 9,
        [string]$SqlEndpoint,
        [string]$SqlAccessToken,
        [string]$LakehouseName = 'mls_operations',
        [string]$ReportRoot,
        [switch]$NoRetry,
        [string[]]$OnlyCriterion = @()
    )
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $solutionFile = $SolutionPath
    if ([string]::IsNullOrWhiteSpace($solutionFile)) {
        # pac solution unpack writes solution/<SolutionName>/Other/Solution.xml, NOT
        # solution/Other/Solution.xml (README section 4; confirmed by the first real export,
        # 2026-08-31). The old default could never match, so V8.1 returned SKIP -- "still
        # holds only its .gitkeep placeholder" -- however complete the export actually was.
        # No test caught it because every test passes -SolutionPath explicitly.
        # Globbing rather than hardcoding keeps this correct under POWERPLATFORM_SOLUTION_NAME.
        $solutionRoot = Join-Path -Path $repoRoot -ChildPath 'infra' -AdditionalChildPath 'copilot-studio', 'solution'
        $found = Get-ChildItem -Path $solutionRoot -Filter 'Solution.xml' -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Directory.Name -eq 'Other' } | Select-Object -First 1
        $solutionFile = if ($found) { $found.FullName } else {
            Join-Path -Path $solutionRoot -ChildPath 'Other' -AdditionalChildPath 'Solution.xml'
        }
    }
    $committed = Get-CommittedSolution -Path $solutionFile

    $environment = $EnvironmentUrl
    if ([string]::IsNullOrWhiteSpace($environment)) { $environment = [Environment]::GetEnvironmentVariable('MLS_POWER_PLATFORM_ENV_URL') }
    $header = $null
    if (-not [string]::IsNullOrWhiteSpace($environment)) {
        $token = $DataverseToken
        if ([string]::IsNullOrWhiteSpace($token)) { $token = [Environment]::GetEnvironmentVariable('MLS_DATAVERSE_TOKEN') }
        if ([string]::IsNullOrWhiteSpace($token)) {
            $response = Invoke-MlsAz -AllowFailure -Argument @('account', 'get-access-token', '--resource', $environment, '--output', 'json')
            $token = "$(Get-MlsProperty -InputObject $response -Name 'accessToken')"
        }
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            $header = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
        }
        else {
            $environment = ''
        }
    }

    $evalPath = $EvalResultPath
    if ([string]::IsNullOrWhiteSpace($evalPath)) { $evalPath = [Environment]::GetEnvironmentVariable('MLS_EVAL_RESULTS') }
    $artifact = Get-EvalArtifact -Path $evalPath
    $serverUrl = $McpServerUrl
    if ([string]::IsNullOrWhiteSpace($serverUrl)) { $serverUrl = [Environment]::GetEnvironmentVariable('MLS_MCP_SERVER_URL') }
    $endpoint = $SqlEndpoint
    if ([string]::IsNullOrWhiteSpace($endpoint)) { $endpoint = [Environment]::GetEnvironmentVariable('MLS_SQL_ENDPOINT') }
    # V8.2 re-derives every figure over TDS against the Entra-only analytics endpoint, so it
    # needs a bearer token: explicit, then the environment, then minted by MlsAudit from the
    # mls-verifier login. Never logged.
    $sqlToken = $SqlAccessToken
    if ([string]::IsNullOrWhiteSpace($sqlToken)) { $sqlToken = [Environment]::GetEnvironmentVariable('MLS_SQL_ACCESS_TOKEN') }

    $context = New-MlsAuditContext -Layer 8 -Title 'Copilot: custom Copilot Studio agent' `
        -ScriptName 'verification/layer-08-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry `
        -OnlyCriterion $OnlyCriterion
    Add-MlsPreflight -Context $context -Name 'Committed solution' -Value $solutionFile -Status $(if ($committed) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Power Platform environment' -Value "$environment" -Status $(if ($environment) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Eval artifact' -Value "$evalPath" -Status $(if ($artifact) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'MCP server' -Value "$serverUrl" -Status $(if ($serverUrl) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Lakehouse SQL endpoint' -Value "$endpoint" -Status $(if ($endpoint) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'SQL access token' `
        -Value $(if ($sqlToken) { 'supplied (value never logged)' } else { 'minted from the current az login at query time' })
    if ($null -ne $artifact) {
        $path = "$(Get-MlsProperty -InputObject $artifact -Name 'path')"
        Add-MlsNote -Context $context -Message "Eval path recorded by the run: '$path' (fabric-data-agent or mcp-tools-only). Both paths must pass V8.2 identically; the report names the path so the evidence is unambiguous (L08.md fallback)."
    }

    Invoke-MlsCriterion -Context $context -Id 'V8.1' -Control @('3.4.1', '3.4.3') `
        -Description "Deployed agent's solution unique name + version + component list match the committed solution exactly, and its published state is current" `
        -Command "GET <envUrl>/api/data/v9.2/solutions?`$filter=uniquename eq '<name>'`nGET <envUrl>/api/data/v9.2/msdyn_solutioncomponentsummaries?`$filter=msdyn_solutionid eq <id>`nSelect-Xml -Path $solutionFile -XPath '//Version','//UniqueName'`nthe committed component set: Solution.xml RootComponents + every botcomponents/*/botcomponent.xml <name> + Assets/botcomponent_connectionreferenceset.xml logical names" `
        -Expected 'unique name and version identical; component set equal against ALL THREE committed sources, not RootComponents alone (F145); no unmanaged layer on the agent component' `
        -RetryWindowMinutes 5 `
        -Test { Test-DeployedSolution -Committed $committed -EnvironmentUrl $environment -Header $header } | Out-Null

    # -Control @(): answer-accuracy eval for the agent's chat responses - a quality/
    # correctness measure, not a CUI protection assertion.
    Invoke-MlsCriterion -Context $context -Id 'V8.2' -Control @() `
        -Description "Eval suite passes >= 9/10 against the deployed agent, with each answer's number independently re-derived by the Verifier from the lakehouse" `
        -Command "read eval-results.json`nfor each question: run the fixture's pinned reference SQL on the lakehouse SQL analytics endpoint as mls-verifier and compare with the agent's stated figure" `
        -Expected ">= $EvalPassBar questions pass both checks; canonical: weekday argmax of launches = Saturday" -NoRetry `
        -Test { Test-EvalSuite -Artifact $artifact -PassBar $EvalPassBar -SqlEndpoint $endpoint -SqlAccessToken $sqlToken -LakehouseName $LakehouseName } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V8.3' -Control @('3.1.2', '3.4.6') `
        -Description "No tool invoked outside the $($AllowedTool.Count)-tool allowlist and the agent declares exactly those $($AllowedTool.Count) (master plan wrote 'five-tool'; query_compliance was added 2026-08-26)" `
        -Command "runtime: every tool call recorded across every eval question`nstatic: MCP tools/list against the deployed server`nstatic: tool/connector components declared by the unpacked solution" `
        -Expected "runtime filter empty; tools/list returns exactly $($AllowedTool -join ', '); no additional tool, connector, agent flow or knowledge source beyond the MCP connection and (Fabric path) the single connected data agent" -NoRetry `
        -Test { Test-ToolAllowlist -Artifact $artifact -McpServerUrl $serverUrl -AllowedTool $AllowedTool -Committed $committed } | Out-Null

    Invoke-MlsCriterion -Context $context -Id 'V8.4' -Control @('3.14.2') `
        -Description 'Every visual answer is an Adaptive Card payload that validates against the pinned Adaptive Cards schema; zero HTML/JS/JSX in any response' `
        -Command "validate each recorded card payload against the pinned Adaptive Cards $AdaptiveCardVersion profile`ngrep every response body for generated UI code" `
        -Expected "every card `"type`":`"AdaptiveCard`" with `"version`":`"$AdaptiveCardVersion`", no Action.Execute; the code-grep returns empty" -NoRetry `
        -Test { Test-AdaptiveCardAnswer -Artifact $artifact -Version $AdaptiveCardVersion } | Out-Null

    # -Control @(): latency SLA, not CUI protection.
    Invoke-MlsCriterion -Context $context -Id 'V8.5' -Control @() `
        -Description 'p95 latency < 20 s' `
        -Command '$lat = $r.questions.latencySeconds | Sort-Object; $p95 = $lat[[math]::Ceiling(0.95 * $lat.Count) - 1]' `
        -Expected "p95 < $LatencyBudgetSeconds seconds" -NoRetry `
        -Test { Test-LatencyBudget -Artifact $artifact -BudgetSeconds $LatencyBudgetSeconds } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -EnvironmentUrl $EnvironmentUrl -DataverseToken $DataverseToken `
            -SolutionPath $SolutionPath -EvalResultPath $EvalResultPath -McpServerUrl $McpServerUrl `
            -AllowedTool $AllowedTool -AdaptiveCardVersion $AdaptiveCardVersion `
            -LatencyBudgetSeconds $LatencyBudgetSeconds -EvalPassBar $EvalPassBar -SqlEndpoint $SqlEndpoint `
            -SqlAccessToken $SqlAccessToken -LakehouseName $LakehouseName -ReportRoot $ReportRoot -NoRetry:$NoRetry `
            -OnlyCriterion $OnlyCriterion
    }
    catch {
        Write-MlsStatus -Message "layer-08-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
