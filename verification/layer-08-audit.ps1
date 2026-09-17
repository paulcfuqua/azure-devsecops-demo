#Requires -Version 7.0
<#
.SYNOPSIS
    L8 Verifier audit - the Copilot Studio agent (showpiece #1). READ-ONLY.

.DESCRIPTION
    Implements the Verify criteria owned by docs/runbooks/layers/L08.md section Validation
    cycle, and nothing else. Five came from the master plan; V8.6 and V8.7 were derived for
    the 2026-09-16 AWS lakehouse link and are written up in that same section:

      V8.1  Deployed agent's solution unique name + version + component list match the
            committed solution exactly, and its published state is current.
      V8.2  Eval suite passes >= 9/10 against the deployed agent, with each answer's
            number independently re-derived by the Verifier from the lakehouse.
      V8.3  No tool invoked outside the tool allowlist and the agent declares exactly
            those tools. The master plan wrote "five-tool allowlist" in 2026-08-22, when
            there were five; the 2026-08-26 compliance-platform design added a sixth,
            query_compliance, and the 2026-09-16 AWS lakehouse link added a seventh,
            query_aws_lakehouse_sql (apps/mcp-tools/src/tools/index.ts's ALLOWED_TOOL_NAMES
            is the source of truth; verification/tests/layer-08-audit.Tests.ps1 asserts this
            default stays in step with it, so a future eighth tool fails a test rather than
            silently going unaudited). The criterion is unchanged - no tool outside the
            DECLARED allowlist - so -AllowedTool below carries seven names, and a deployed
            server advertising only the prior six would now fail this criterion for being
            short until the AWS backend is actually wired up and deployed (Task 9).
      V8.4  Every visual answer is an Adaptive Card payload that validates against the
            pinned Adaptive Cards schema; zero HTML/JS/JSX in any response.
      V8.5  p95 latency < 20 s.
      V8.6  The AWS Athena lakehouse answers through the deployed query_aws_lakehouse_sql
            tool with ROWS, not merely with a status code - V7.6's rule, one cloud over,
            and against a base table AND a Glue VIEW.
      V8.7  A denial from that lakehouse is never reported as an empty dataset: the
            criterion establishes it could observe the Glue catalog before reporting
            anything about what is in it, and fails UNOBSERVABLE when it could not.

    V8.6 AND V8.7 ARE THE ONLY TWO THINGS IN THIS REPOSITORY THAT INVOKE A TOOL. Every
    other criterion reads metadata, and MlsAudit's own contract said "the audit never
    invokes a tool" for exactly as long as that was enough. It is not enough here: a ROW is
    only observable by asking for one. Invoke-MlsMcpToolCall is the single narrow route,
    gated by Assert-MlsReadOnlyMcpToolCall to one named tool and one SELECT-or-WITH
    statement, so the audit cannot send a write even if the server's own gate regressed.

    THE CREDENTIAL IS NOT GRANTED ANYWHERE. mcp-auth-token lives in Key Vault, mls-verifier
    cannot read it, and this script never tries: -McpAuthToken / $env:MLS_MCP_AUTH_TOKEN is
    an explicit input and absence is a labelled SKIP. So V8.6's row assertion and the whole
    of V8.7 are dark until somebody decides, deliberately, to supply it. The half that runs
    with no credential at all is still worth having: /healthz declares its tool set, and a
    rebuild whose six AWS settings never reached the container advertises six tools instead
    of seven, which V8.6 fails on.

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
    # apps/mcp-tools/src/tools/index.ts's ALLOWED_TOOL_NAMES; query_compliance is the sixth
    # (compliance-platform design 2026-08-26 section 5.3) and query_aws_lakehouse_sql is the
    # seventh (2026-09-16 AWS lakehouse link). Test-ToolAllowlist below compares as a SET, so
    # a name missing here fails the criterion just as loudly as an extra one on the server.
    # verification/tests/layer-08-audit.Tests.ps1 cross-checks this literal list against the
    # TypeScript source so the two cannot silently drift again (F145's shape: a list feeding
    # one check widened without checking what else reads it).
    [string[]]$AllowedTool = @(
        'query_lakehouse_sql', 'query_aws_lakehouse_sql', 'query_log_analytics',
        'get_github_security', 'get_defender_posture', 'get_cost_series', 'query_compliance'
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
    # --- V8.6 / V8.7: the AWS Athena lakehouse behind query_aws_lakehouse_sql -------------
    #
    # THE CREDENTIAL IS AN EXPLICIT INPUT AND NOTHING ELSE. The audit never reads it from
    # Key Vault, never mints it, never stores it and never logs it, and this repository
    # grants mls-verifier no way to obtain it. Without it V8.6/V8.7 report SKIP naming
    # exactly what is missing - never a pass, and never a claim about the lakehouse.
    #
    # That is a deliberate stop rather than an oversight: mcp-auth-token is compared with
    # timingSafeEqual, so it IS the capability, and an auditor holding a working credential
    # for the thing it audits is a concession somebody has to make on purpose. Wiring it
    # into the L8 verify job is a decision for whoever owns the estate's credential list
    # (CLAUDE.md hard rule 5), not one an audit script may make by reading a vault.
    [string]$McpAuthToken,
    # The base table and the VIEW V8.6 queries. Both, deliberately: a Glue view needs
    # glue:GetTable on its OWN arn, so a role granted the three base tables answers every
    # base-table question perfectly and AccessDenies the view - a partial failure that reads
    # like a data problem, in front of an audience. V8.7's expected inventory is derived
    # from these two names rather than restated, because a second list is the thing that
    # drifts (F145).
    [string]$AwsBaseTable = 'launches',
    [string]$AwsView = 'launches_latest',
    # FLOORS, NOT EQUALITIES, and the distinction is the criterion's own reasoning: this
    # lakehouse belongs to the sponsor and refreshes from an upstream launch feed, so an
    # exact count is guaranteed to go stale and a stale equality FAILS ON CORRECT DATA. The
    # criterion asks whether the link answers with real data, not whether the feed stopped;
    # V5.3 owns exact counts, over a dataset this repo seeds. Observed 2026-09-16:
    # launches 286,473 and launches_latest 7,969, so both floors sit far below a live value
    # and far above the zero a broken link returns.
    [int]$AwsBaseTableFloor = 100000,
    [int]$AwsViewFloor = 1000,
    # The Glue database the catalog probe asks about. Resolved from the RUNNING container's
    # own MLS_GLUE_DATABASE when not supplied, because a value the estate derives cannot
    # disagree with the estate (F129).
    [string]$AwsGlueDatabase,
    [int]$AwsQueryTimeoutSeconds = 120,
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

$script:AwsToolName = 'query_aws_lakehouse_sql'

# A refusal, spelled however the upstream spells it. Athena surfaces a missing Glue or S3
# grant as a message, never as a status code this side can read, and the whole of V8.7 is
# the difference between "denied" and "empty".
$script:AwsDenialPattern = '(?i)AccessDenied|not authorized|is not allowed|Insufficient (permissions|Lake Formation)|Unauthorized|AssumeRoleWithWebIdentity|EntityNotFound|HIVE_METASTORE_ERROR'

function Get-McpHealth {
    <#
    .SYNOPSIS
        The unauthenticated /healthz payload of the deployed MCP server.
    .DESCRIPTION
        The one place the backend selection is observable from outside the process, and the
        only thing V8.6 can read WITHOUT a credential. Returns the status code alongside the
        payload so the caller can tell three different situations apart, which is the whole
        point: nothing answered (unobservable), the server answered badly (the app), or the
        server answered and declared what it serves (a fact about the estate).
    #>
    param([AllowEmptyString()][string]$McpServerUrl)
    $health = "$McpServerUrl" -replace '/[^/]*$', '/healthz'
    $response = Invoke-MlsHttp -Uri $health -TimeoutSec 30
    $status = [int](Get-MlsProperty -InputObject $response -Name 'StatusCode')
    $payload = $null
    if ($status -eq 200) {
        try { $payload = "$(Get-MlsProperty -InputObject $response -Name 'Content')" | ConvertFrom-Json }
        catch { $payload = $null }
    }
    return [pscustomobject]@{ Uri = $health; StatusCode = $status; Payload = $payload }
}

function Get-AwsQueryObservation {
    <#
    .SYNOPSIS
        Run one read-only SQL probe through the deployed tool and reduce it to an
        observation line plus a verdict.
    .DESCRIPTION
        The observation line is the point, not a by-product. An authenticated scan and a
        blocked one once produced byte-identical reports, so nothing in the artifact could
        answer "did this work" at all (F162); one recorded line per target fixed it and
        found a real bug on its first run. So every probe records what it SAW - row count,
        elapsed milliseconds, and the first value - whether it passed, failed or could not
        be read, and the wording for "could not be read" is never the wording for "empty".
    #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Sql,
        [AllowEmptyString()][AllowNull()][string]$AuthToken,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    $call = Invoke-MlsMcpToolCall -Uri $Uri -ToolName $script:AwsToolName -Argument @{ sql = $Sql } `
        -AuthToken $AuthToken -TimeoutSec $TimeoutSeconds

    if ($call.Outcome -eq 'unobservable') {
        return [pscustomobject]@{
            Label = $Label; Observable = $false; Denied = $false
            Line = "$Label -> UNOBSERVABLE after $($call.ElapsedMs) ms: $($call.Reason)"
            Reason = $call.Reason; RowCount = -1; FirstValue = $null; Row = @(); ElapsedMs = $call.ElapsedMs
        }
    }
    if ($call.Outcome -eq 'tool-error') {
        $denied = [bool]($call.ToolError -match $script:AwsDenialPattern)
        return [pscustomobject]@{
            Label = $Label; Observable = $true; Denied = $denied
            Line = "$Label -> $(if ($denied) { 'DENIED' } else { 'TOOL ERROR' }) after $($call.ElapsedMs) ms: $($call.ToolError)"
            Reason = $call.ToolError; RowCount = -1; FirstValue = $null; Row = @(); ElapsedMs = $call.ElapsedMs
        }
    }

    $rowCount = Get-MlsProperty -InputObject $call.Payload -Name 'rowCount'
    $rows = @(Get-MlsProperty -InputObject $call.Payload -Name 'rows')
    if ($null -eq $rowCount) { $rowCount = $rows.Count }
    $first = $null
    if ($rows.Count -gt 0) { $first = @($rows[0])[0] }
    return [pscustomobject]@{
        Label = $Label; Observable = $true; Denied = $false
        # The exact line the brief asks for, per probe, so the artifact can distinguish
        # success from silence without a reader inferring anything.
        Line = "$Label -> authenticated Athena query -> $([int]$rowCount) rows, $($call.ElapsedMs) ms$(if ($null -ne $first) { ", first value $first" })"
        Reason = ''; RowCount = [int]$rowCount; FirstValue = $first; Row = $rows; ElapsedMs = $call.ElapsedMs
    }
}

function Get-AwsGlueDatabaseName {
    <#
    .SYNOPSIS
        The Glue database the deployed tool is pointed at, preferring the value the estate
        DERIVES over any a human stored.
    .DESCRIPTION
        Explicit argument, then the environment, then the running container's own
        MLS_GLUE_DATABASE read over ARM with the Verifier's Reader credential. The last is
        the one that cannot disagree with the estate: a database name typed into a variable
        can outlive the deployment that used it, and a rebuild is exactly when this
        criterion matters (F129). Returns '' when none of the three answers - the caller
        reports that as UNOBSERVABLE, never as an empty catalog.
    #>
    param(
        [AllowEmptyString()][string]$Supplied,
        [AllowEmptyString()][string]$McpServerUrl,
        [AllowEmptyString()][string]$ResourceGroupName
    )
    if (-not [string]::IsNullOrWhiteSpace($Supplied)) { return $Supplied }
    $fromEnvironment = [Environment]::GetEnvironmentVariable('MLS_GLUE_DATABASE')
    if (-not [string]::IsNullOrWhiteSpace($fromEnvironment)) { return $fromEnvironment }
    if ([string]::IsNullOrWhiteSpace($McpServerUrl) -or [string]::IsNullOrWhiteSpace($ResourceGroupName)) { return '' }
    # The app NAME is the first label of the host in the URL the workflow already resolved
    # from ARM, so nothing here reconstructs a hostname that a rebuild invalidates.
    $appName = ''
    try { $appName = ([uri]$McpServerUrl).Host.Split('.')[0] } catch { $appName = '' }
    if ([string]::IsNullOrWhiteSpace($appName)) { return '' }
    $value = "$(Invoke-MlsAz -AllowFailure -Raw -Argument @(
        'containerapp', 'show', '--resource-group', $ResourceGroupName, '--name', $appName,
        '--query', "properties.template.containers[0].env[?name=='MLS_GLUE_DATABASE'].value | [0]",
        '--output', 'tsv'))".Trim()
    if ($value -eq 'None') { return '' }
    return $value
}

function Test-AwsLakehouseRow {
    <# V8.6 - THE AWS LAKEHOUSE ANSWERS WITH ROWS, NOT WITH A STATUS CODE.

       V7.6's rule, one cloud over. On 2026-09-16 the link began working - 286,473 rows in
       4,431 ms through the live MCP endpoint against the sponsor's real Athena lakehouse -
       and the evidence was a scratch script that no longer exists. An estate that answers
       from AWS with no criterion asserting it is one teardown away from the position
       docs/DEMO-READINESS.md section D describes: plumbing verified, water unverified,
       which is how an empty estate signed off 5/5 for two days.

       Three assertions, in the order they can be made:

         1. The deployed server DECLARES the tool. /healthz is unauthenticated, so this
            half runs on every audit with no credential at all - and it is the half that
            catches a rebuild where the six AWS settings never reached the container
            (F122/F124/F125), because the tool is gated on configuration and a server with
            no AWS config advertises six tools instead of seven.
         2. A known-answer query against the BASE TABLE returns rows, above a floor.
         3. The same against a VIRTUAL_VIEW, which needs glue:GetTable on its own arn.

       Declaring the tool is NECESSARY AND NOT SUFFICIENT, so step 1 alone is never a pass:
       "the tool is registered" is the artefact that usually accompanies "the lakehouse
       answers", and this criterion exists because the two came apart once already. #>
    param(
        [AllowEmptyString()][string]$McpServerUrl,
        [AllowEmptyString()][AllowNull()][string]$McpAuthToken,
        [Parameter(Mandatory)][string]$BaseTable,
        [Parameter(Mandatory)][int]$BaseTableFloor,
        [Parameter(Mandatory)][string]$View,
        [Parameter(Mandatory)][int]$ViewFloor,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    if ([string]::IsNullOrWhiteSpace($McpServerUrl)) {
        return New-MlsCheckResult -Status 'SKIP' -Observed 'no deployed MCP server to ask' `
            -Detail 'Pass -McpServerUrl / $env:MLS_MCP_SERVER_URL. The AWS lakehouse is reachable only through the deployed query_aws_lakehouse_sql tool: this estate holds no AWS credential, by design, so there is no second route to the same fact.'
    }

    $health = Get-McpHealth -McpServerUrl $McpServerUrl
    if ($health.StatusCode -eq 0) {
        return New-MlsCheckResult -Passed $false -Final `
            -Observed "UNOBSERVABLE: GET $($health.Uri) produced no HTTP response, so the declared tool set could not be read" `
            -Detail 'UNOBSERVABLE, never "the AWS tool is missing": a request that never arrived says nothing about what the server declares.'
    }
    if ($health.StatusCode -ne 200 -or $null -eq $health.Payload) {
        return New-MlsCheckResult -Passed $false -Final `
            -Observed "UNOBSERVABLE: GET $($health.Uri) returned HTTP $($health.StatusCode) with no readable payload" `
            -Detail 'The MCP server answered, but not with something this criterion can read. Fix the server or the path before reading anything into the AWS link.'
    }

    $declared = @(Get-MlsProperty -InputObject $health.Payload -Name 'toolNames')
    if ($declared.Count -eq 0) {
        return New-MlsCheckResult -Passed $false -Final `
            -Observed 'UNOBSERVABLE: /healthz carries no toolNames field, so the declared tool set could not be read' `
            -Detail 'A deployed image predating F100 publishes no tool names. Absent evidence, not evidence of absence - this is never "the server declares no AWS tool".'
    }
    $adapter = "$(Get-MlsProperty -InputObject (Get-MlsProperty -InputObject $health.Payload -Name 'adapters') -Name $script:AwsToolName)"
    if ($script:AwsToolName -notin $declared) {
        return New-MlsCheckResult -Passed $false -Final `
            -Observed "the deployed server declares $($declared.Count) tool(s) and none of them is $($script:AwsToolName): $($declared -join ', ')" `
            -Detail 'OBSERVED, not unobservable: /healthz answered and listed what it serves. The AWS tool registers only when all six AWS settings resolve INSIDE the running process, so this is the signature of a rebuild where infra/bicep/apps/main.bicep''s AWS parameters did not reach the container - a value that exists, is spelled correctly, and cannot be seen by the thing that reads it (F122/F124/F125).'
    }

    $declaredLine = "declared: $($script:AwsToolName) present on /healthz, adapter $(if ($adapter) { $adapter } else { '(unnamed)' })"

    if ([string]::IsNullOrWhiteSpace($McpAuthToken)) {
        return New-MlsCheckResult -Status 'SKIP' -Observed "$declaredLine - no credential, so no row was read" `
            -Detail 'The tool is DECLARED and no row was read, which is necessary and nowhere near sufficient: an empty lakehouse and a broken link both declare exactly this. The MCP endpoint is behind mcp-auth-token (Key Vault) and this audit is given no way to obtain it; pass -McpAuthToken / $env:MLS_MCP_AUTH_TOKEN to complete the criterion. Until then L8 is NOT asserting that the AWS lakehouse answers.'
    }

    $observation = [System.Collections.Generic.List[string]]::new()
    $observation.Add($declaredLine)
    $problem = [System.Collections.Generic.List[string]]::new()
    $blind = [System.Collections.Generic.List[string]]::new()

    foreach ($probe in @(
            @{ Label = "base table $BaseTable"; Sql = "SELECT COUNT(*) AS n FROM $BaseTable"; Floor = $BaseTableFloor },
            @{ Label = "view $View"; Sql = "SELECT COUNT(*) AS n FROM $View"; Floor = $ViewFloor })) {
        # A RUN IS AN EXPENSIVE, RATE-LIMITED OBSERVATION: both probes are made and both are
        # reported, so one failure does not hide the other's answer. Stopping at the first
        # would make the discovery rate equal to the audit rate.
        $result = Get-AwsQueryObservation -Label $probe.Label -Uri $McpServerUrl -Sql $probe.Sql `
            -AuthToken $McpAuthToken -TimeoutSeconds $TimeoutSeconds
        $observation.Add($result.Line)
        if (-not $result.Observable) { $blind.Add("$($probe.Label): $($result.Reason)"); continue }
        if ($result.Denied -or $result.RowCount -lt 0) { $problem.Add($result.Line); continue }
        if ($result.RowCount -lt 1) {
            $problem.Add("$($probe.Label) returned $($result.RowCount) row(s); a COUNT query always returns one, so the tool answered with a shape this criterion cannot read")
            continue
        }
        $value = 0L
        if (-not [long]::TryParse("$($result.FirstValue)", [ref]$value)) {
            $problem.Add("$($probe.Label) returned '$($result.FirstValue)', which is not a count")
            continue
        }
        if ($value -lt $probe.Floor) {
            $problem.Add("$($probe.Label) counted $value, below the floor of $($probe.Floor)")
        }
        $observation[$observation.Count - 1] = "$($result.Line) (count $value, floor $($probe.Floor))"
    }

    if ($blind.Count -gt 0) {
        # NEVER PASS AND NEVER "ABSENT". One unreadable probe is enough: an auditor that
        # could not see one half must not report the whole as present, and must not report
        # the lakehouse as empty either.
        return New-MlsCheckResult -Passed $false -Final `
            -Observed ("UNOBSERVABLE: " + ($blind -join ' | ') + ' | ' + ($observation -join '; ')) `
            -Detail 'UNOBSERVABLE, not FAIL-as-absent and not PASS. Something upstream of the tool - the auth gate, a throttle, a 5xx, a body with no envelope - stopped this audit reading the answer. Establish that the query can be made before reading anything into what it returned.'
    }
    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($observation -join '; ')
    }
    return New-MlsCheckResult -Passed $false -Observed (($observation -join '; ') + ' | ' + ($problem -join ' | ')) -Final `
        -Detail 'A DENIED probe on the view with a working base table is the five-table finding regressing: a Glue view needs glue:GetTable on its own arn, and a role built from the base-table names answers everything else perfectly. A count below the floor is a data problem upstream in the sponsor''s account, not a link problem - the two are different failures and the observation lines above name which.'
}

function Test-AwsCatalogObservability {
    <# V8.7 - A DENIAL IS NEVER REPORTED AS AN EMPTY DATASET.

       F105's exact shape, one cloud over. Fabric answered /tables with [] to a caller
       without OneLake read, and V5.2 called the lakehouse empty while its SQL endpoint
       held 1,200 rows: a confident, specific, WRONG answer that looked like an ordinary
       red criterion. Athena does the same thing - information_schema.tables against a Glue
       database the role cannot read can come back EMPTY rather than 403 - so absence is
       unprovable here and a zero-row listing is UNOBSERVABLE, never "the database has no
       tables".

       The criterion therefore establishes that it COULD observe before reporting what it
       saw, and it is structurally incapable of both errors: it cannot report the link
       absent when it could not look, and it cannot report it present either. The expected
       inventory is DERIVED from V8.6's own table and view parameters rather than restated,
       because a second copy of a list is the thing that drifts while nothing about it is
       edited (F145). #>
    param(
        [AllowEmptyString()][string]$McpServerUrl,
        [AllowEmptyString()][AllowNull()][string]$McpAuthToken,
        [AllowEmptyString()][AllowNull()][string]$GlueDatabase,
        [Parameter(Mandatory)][string[]]$ExpectedTable,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )
    if ([string]::IsNullOrWhiteSpace($McpServerUrl)) {
        return New-MlsCheckResult -Status 'SKIP' -Observed 'no deployed MCP server to ask' `
            -Detail 'The Glue catalog is reachable only through the deployed tool; pass -McpServerUrl / $env:MLS_MCP_SERVER_URL.'
    }
    if ([string]::IsNullOrWhiteSpace($McpAuthToken)) {
        return New-MlsCheckResult -Status 'SKIP' -Observed 'no credential for the MCP endpoint, so the catalog was NOT probed' `
            -Detail 'Nothing is claimed about the catalog: not that it is readable, not that it is empty, not that it is denied. Pass -McpAuthToken / $env:MLS_MCP_AUTH_TOKEN to complete the criterion.'
    }
    if ([string]::IsNullOrWhiteSpace($GlueDatabase)) {
        return New-MlsCheckResult -Passed $false -Final `
            -Observed 'UNOBSERVABLE: the Glue database name could not be resolved from -AwsGlueDatabase, $env:MLS_GLUE_DATABASE or the running container''s MLS_GLUE_DATABASE' `
            -Detail 'UNOBSERVABLE, never "the catalog is empty": with no database name there is no question to ask, so nothing here is evidence about the catalog either way.'
    }

    $sql = "SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = '$GlueDatabase' ORDER BY table_name"
    $result = Get-AwsQueryObservation -Label "catalog $GlueDatabase" -Uri $McpServerUrl -Sql $sql `
        -AuthToken $McpAuthToken -TimeoutSeconds $TimeoutSeconds

    if (-not $result.Observable) {
        return New-MlsCheckResult -Passed $false -Final -Observed "UNOBSERVABLE: $($result.Line)" `
            -Detail 'UNOBSERVABLE. Something upstream of the tool stopped this audit reading the catalog, so it reports neither that the tables are there nor that they are missing. A throttled response in particular is not an empty one.'
    }
    if ($result.Denied) {
        return New-MlsCheckResult -Passed $false -Final -Observed $result.Line `
            -Detail 'DENIED, AND SAID SO. This is the criterion working: the role cannot read the Glue catalog, and that is reported as a refusal rather than as an empty database. Fix the role''s glue:GetTables/glue:GetTable grants - do not read this as "the lakehouse has no tables".'
    }
    if ($result.RowCount -lt 0) {
        return New-MlsCheckResult -Passed $false -Final -Observed $result.Line `
            -Detail 'The tool ran and failed for a reason that is not a refusal. Read the message above; it is the engine''s own.'
    }
    if ($result.RowCount -eq 0) {
        # THE WHOLE CRITERION, IN ONE BRANCH. Athena answers a Glue database the role may
        # not read with an empty listing, so zero rows here is exactly as consistent with a
        # denial as with an empty database - and only one of those is a fact.
        return New-MlsCheckResult -Passed $false -Final `
            -Observed "UNOBSERVABLE: $($result.Line) - an empty information_schema listing is what Athena returns BOTH for a database with no tables AND for one this role may not read, so emptiness here is unprovable" `
            -Detail 'Never "the lakehouse is empty" and never a pass. Establish catalog read independently - the base-table probe in V8.6 returning rows is the cheapest proof - before treating this listing as an inventory.'
    }

    # Only now is the listing evidence of anything. The names come from the rows this probe
    # already returned - asking a second time would be a second observation, and the two
    # could disagree.
    $name = @(@($result.Row) | ForEach-Object { "$(@($_)[0])" } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $missing = @($ExpectedTable | Where-Object { $_ -notin $name })
    $observed = "$($result.Line); catalog names [$($name -join ', ')]"
    if ($missing.Count -gt 0) {
        return New-MlsCheckResult -Passed $false -Final `
            -Observed "$observed | missing [$($missing -join ', ')]" `
            -Detail 'OBSERVED MISSING, not unobservable: the catalog answered with a non-empty listing, so this audit could see it, and the named tables are genuinely not in it. That is a real change to the sponsor''s lakehouse or to what this criterion expects of it.'
    }
    return New-MlsCheckResult -Passed $true -Observed $observed
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
        [string]$McpAuthToken,
        [string]$AwsBaseTable = 'launches',
        [string]$AwsView = 'launches_latest',
        [int]$AwsBaseTableFloor = 100000,
        [int]$AwsViewFloor = 1000,
        [string]$AwsGlueDatabase,
        [int]$AwsQueryTimeoutSeconds = 120,
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

    # V8.6/V8.7's credential for the deployed MCP endpoint. Explicit argument or environment
    # ONLY: nothing here reads a vault, and its absence is a labelled SKIP rather than a
    # pass. Never logged, never written to a report - only whether one was supplied.
    $mcpToken = $McpAuthToken
    if ([string]::IsNullOrWhiteSpace($mcpToken)) { $mcpToken = [Environment]::GetEnvironmentVariable('MLS_MCP_AUTH_TOKEN') }
    # Resolved only when there is something to ask: with no credential no catalog probe is
    # made, so an ARM round trip to name the database it would not have queried buys nothing.
    $glueDatabase = ''
    if (-not [string]::IsNullOrWhiteSpace($mcpToken)) {
        $naming = Get-MlsEstateNaming -RepoRoot $repoRoot
        $glueDatabase = Get-AwsGlueDatabaseName -Supplied $AwsGlueDatabase -McpServerUrl $serverUrl `
            -ResourceGroupName "$($naming.Prefix)-rg-apps"
    }
    # ONE SOURCE for both criteria: V8.7's expected inventory is V8.6's two probe targets,
    # not a second list that can drift while nothing about it is edited (F145).
    $awsExpectedTable = @($AwsBaseTable, $AwsView)

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
    Add-MlsPreflight -Context $context -Name 'MCP endpoint credential (V8.6/V8.7)' `
        -Value $(if ($mcpToken) { 'supplied (value never logged)' } else { 'NOT SUPPLIED - no row can be read from the AWS lakehouse, and V8.6/V8.7 report SKIP rather than a pass' }) `
        -Status $(if ($mcpToken) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'AWS Glue database' `
        -Value $(if ($glueDatabase) { $glueDatabase } elseif ($mcpToken) { 'could not be resolved from -AwsGlueDatabase, $env:MLS_GLUE_DATABASE or the running container' } else { 'not resolved - no MCP credential, so no catalog probe is made' }) `
        -Status $(if ($glueDatabase) { 'OK' } else { 'ABSENT' })
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
        -Description "No tool invoked outside the $($AllowedTool.Count)-tool allowlist and the agent declares exactly those $($AllowedTool.Count) (master plan wrote 'five-tool'; query_compliance was added 2026-08-26, query_aws_lakehouse_sql 2026-09-16)" `
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

    # V8.6 - V7.6's rule, one cloud over: the criterion that closes DEMO-READINESS section D
    # for the AWS lakehouse. 4 MINUTES, AND THE NUMBER IS CHOSEN, NOT INHERITED. It waits on
    # two things and neither is Azure propagation: mls-mcp-demo-ca scales to zero with a
    # 900 s cooldown, so the first question after an idle gap pays a container cold start,
    # and Athena is asynchronous - submit, poll, retrieve - so a queued query is a real wait.
    # Observed warm end to end on 2026-09-16: 4,431 ms. Four minutes covers two cold starts
    # and a queue; nothing here gets better by waiting longer than that.
    Invoke-MlsCriterion -Context $context -Id 'V8.6' -Control @('3.4.1') `
        -Description 'The AWS Athena lakehouse answers through the deployed tool with ROWS, not merely with a status code' `
        -Command "GET <mcpServerUrl>/healthz   # assert $($script:AwsToolName) is DECLARED - no credential needed, and this half alone is never a pass`nPOST <mcpServerUrl> tools/call $($script:AwsToolName) {`"sql`":`"SELECT COUNT(*) AS n FROM $AwsBaseTable`"}`nPOST <mcpServerUrl> tools/call $($script:AwsToolName) {`"sql`":`"SELECT COUNT(*) AS n FROM $AwsView`"}   # a VIRTUAL_VIEW: needs glue:GetTable on its own arn" `
        -Expected "the deployed server declares $($script:AwsToolName); the base table counts >= $AwsBaseTableFloor and the view >= $AwsViewFloor. FLOORS, NOT EQUALITIES: this lakehouse is the sponsor's and refreshes from an upstream feed, so a pinned count would fail on correct data - the criterion asks whether the link answers with real data, and V5.3 owns exact counts over a dataset this repo seeds. An HTTP 200 alone is NOT sufficient." `
        -RetryWindowMinutes 4 -PollIntervalSeconds 30 `
        -Test {
        Test-AwsLakehouseRow -McpServerUrl $serverUrl -McpAuthToken $mcpToken `
            -BaseTable $AwsBaseTable -BaseTableFloor $AwsBaseTableFloor `
            -View $AwsView -ViewFloor $AwsViewFloor -TimeoutSeconds $AwsQueryTimeoutSeconds
    } | Out-Null

    # V8.7 - 2 MINUTES, and shorter than V8.6 on purpose. This probe reads Glue catalog
    # metadata with no S3 scan behind it, and it runs after V8.6 on a container V8.6 has
    # already woken - propagation is shared wall clock, and the second criterion does not
    # start the clock again.
    Invoke-MlsCriterion -Context $context -Id 'V8.7' -Control @('3.1.2') `
        -Description 'A denial from the AWS lakehouse is never reported as an empty dataset: observability is established before anything is reported' `
        -Command "POST <mcpServerUrl> tools/call $($script:AwsToolName) {`"sql`":`"SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = '<glueDatabase>'`"}`n# zero rows -> UNOBSERVABLE, because Athena answers a database the role may not read with an EMPTY listing`n# a refusal -> DENIED, reported as a refusal and never as an empty database" `
        -Expected "a non-empty catalog listing containing $($awsExpectedTable -join ', '). An empty listing, a refusal, a throttle or an unreadable response is UNOBSERVABLE or DENIED - never 'the lakehouse is empty', and never a pass." `
        -RetryWindowMinutes 2 -PollIntervalSeconds 30 `
        -Test {
        Test-AwsCatalogObservability -McpServerUrl $serverUrl -McpAuthToken $mcpToken `
            -GlueDatabase $glueDatabase -ExpectedTable $awsExpectedTable -TimeoutSeconds $AwsQueryTimeoutSeconds
    } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -EnvironmentUrl $EnvironmentUrl -DataverseToken $DataverseToken `
            -SolutionPath $SolutionPath -EvalResultPath $EvalResultPath -McpServerUrl $McpServerUrl `
            -AllowedTool $AllowedTool -AdaptiveCardVersion $AdaptiveCardVersion `
            -LatencyBudgetSeconds $LatencyBudgetSeconds -EvalPassBar $EvalPassBar -SqlEndpoint $SqlEndpoint `
            -SqlAccessToken $SqlAccessToken -LakehouseName $LakehouseName -McpAuthToken $McpAuthToken `
            -AwsBaseTable $AwsBaseTable -AwsView $AwsView -AwsBaseTableFloor $AwsBaseTableFloor `
            -AwsViewFloor $AwsViewFloor -AwsGlueDatabase $AwsGlueDatabase `
            -AwsQueryTimeoutSeconds $AwsQueryTimeoutSeconds -ReportRoot $ReportRoot -NoRetry:$NoRetry `
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
