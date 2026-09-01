#Requires -Version 7.0
<#
.SYNOPSIS
    L7 Verifier audit - spec-renderer, launch-ops, control tower, per-app CI. READ-ONLY.

.DESCRIPTION
    Implements the five master-plan Verify criteria owned by
    docs/runbooks/layers/L07.md section Validation cycle, and nothing else:

      V7.1  Public endpoints return 200 with correct content hash markers.
      V7.2  Renderer schema validation passes on golden specs.
      V7.3  OTel spans from a synthetic request visible in App Insights via KQL.
      V7.4  Per-app CI green on a canary PR (including the path-filter assertion).
      V7.5  Replicas scale 0 -> N -> 0.

    The Ask tab is deliberately not part of any of them - it ships dark at L7, so a dark
    tab cannot fail this layer (L07.md Purpose).

    Everything here is a read: health GETs, tagged probe GETs (explicitly permitted to the
    Verifier by L07.md V7.3), Log Analytics queries, GitHub reads and ARM reads. The load
    phase of V7.5 issues concurrent GETs against a public endpoint - traffic, not mutation.

.EXAMPLE
    ./layer-07-audit.ps1 -CanaryPrNumber 42 -DeployManifestPath ./l7-manifest.json
#>
[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'mls-rg-apps',
    [string[]]$AppName = @('mls-launch-ops-demo-ca', 'mls-control-tower-demo-ca'),
    [string]$DeployManifestPath,
    [string]$LogAnalyticsWorkspaceId,
    [string]$Repository,
    [string]$CanaryPrNumber,
    [string]$HealthPath = '/healthz',
    [string]$ProbePath = '/api/tables/launches',
    # V7.6's floor. The seed is deterministic (L5 loads 1,200 launches), so any positive
    # number proves the path works; 1 is deliberately the weakest useful assertion,
    # because this criterion is about "answers at all" and V5.3 owns exact counts.
    [int]$MinimumRow = 1,
    [int]$LoadRequestCount = 20,
    [double]$ScaleInWaitMinutes = 15,
    [double]$ScaleInDeadlineMinutes = 30,
    [string]$ReportRoot,
    [switch]$NoRetry,

    # Run only these criteria (e.g. -OnlyCriterion V7.3). Everything else reports SKIP
    # naming the reason, and the run exits 3 - a DIAGNOSTIC, never a sign-off.
    #
    # Why this exists: V7.5 waits up to 15 minutes per app for a real scale-in cycle, so a
    # full audit is ~55 minutes. Four consecutive runs were spent testing one criterion
    # with the other four along for the ride, which is the "a run is an expensive,
    # rate-limited observation" rule pointing at its own audit.
    [string[]]$OnlyCriterion = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'MlsAudit.psm1') -Force

function Get-AppFqdn {
    <# Ingress FQDN of one container app. #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )
    $fqdn = Invoke-MlsAz -AllowFailure -Raw -Argument @(
        'containerapp', 'show', '--resource-group', $ResourceGroupName, '--name', $Name,
        '--query', 'properties.configuration.ingress.fqdn', '--output', 'tsv'
    )
    return "$fqdn".Trim()
}

function Get-ExpectedDigest {
    <# The image digest the deploy run recorded, per app, from the layer manifest. #>
    param(
        [AllowNull()]$Manifest,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Manifest) { return '' }
    $apps = @(Get-MlsProperty -InputObject $Manifest -Name 'apps')
    foreach ($app in $apps) {
        if ("$(Get-MlsProperty -InputObject $app -Name 'name')" -eq $Name) {
            return "$(Get-MlsProperty -InputObject $app -Name 'imageDigest')"
        }
    }
    return ''
}

function Test-PublicEndpoint {
    <# V7.1 - 200 from both apps, and the health payload's content-hash marker equal to
       the image digest recorded in the deploy run (binding endpoint to build). #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string[]]$AppName,
        [Parameter(Mandatory)][string]$HealthPath,
        [AllowNull()]$Manifest
    )
    if ($null -eq $Manifest) {
        return New-MlsCheckResult -Passed $false -Observed 'no deploy manifest supplied' -Final `
            -Detail 'V7.1 binds "endpoint is up" to "endpoint serves the audited build", so it needs the per-app image digests the deploy run stamped. The app CI workflows must publish a manifest {"apps":[{"name":...,"imageDigest":...}]} for the Verifier; pass it with -DeployManifestPath / $env:MLS_L7_MANIFEST. Refusing to pass on liveness alone.'
    }
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $AppName) {
        $fqdn = Get-AppFqdn -ResourceGroupName $ResourceGroupName -Name $name
        if ([string]::IsNullOrWhiteSpace($fqdn)) {
            $problem.Add("$name has no ingress FQDN")
            continue
        }
        $response = Invoke-MlsHttp -Uri "https://$fqdn$HealthPath" -TimeoutSec 60
        $observed.Add("$name -> $($response.StatusCode)")
        if ($response.StatusCode -ne 200) {
            $problem.Add("$name returned $($response.StatusCode) $(Format-MlsValue -Value $response.Error -MaximumLength 120)")
            continue
        }
        $expectedDigest = Get-ExpectedDigest -Manifest $Manifest -Name $name
        if ([string]::IsNullOrWhiteSpace($expectedDigest)) {
            $problem.Add("$name has no imageDigest in the deploy manifest")
            continue
        }
        if ("$($response.Content)" -notlike "*$expectedDigest*") {
            $problem.Add("$name health payload does not carry the deployed image digest $expectedDigest")
        }
    }
    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed (($observed -join '; ') + ' with matching content-hash markers')
    }
    return New-MlsCheckResult -Passed $false -Observed ($problem -join ' | ') `
        -Detail 'First request may cold-start from 0 replicas: up to 60 s is normal, and the retry window absorbs it (L07 failure mode 1).'
}

function Test-GoldenSpec {
    <# V7.2 - deterministic local check, run from the audited commit. #>
    param([Parameter(Mandatory)][string]$RepoRoot)
    $rendererPath = Join-Path -Path $RepoRoot -ChildPath 'apps' -AdditionalChildPath 'shared', 'spec-renderer'
    if (-not (Test-Path -LiteralPath $rendererPath)) {
        return New-MlsCheckResult -Passed $false -Observed "spec-renderer not found at $rendererPath" -Final
    }
    $result = Invoke-MlsLocalCommand -FilePath 'npm' -WorkingDirectory $RepoRoot `
        -Argument @('--prefix', 'apps/shared/spec-renderer', 'run', 'validate:golden')
    if ($result.ExitCode -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed 'npm run validate:golden exited 0 - every golden spec validates against the component-spec JSON Schema'
    }
    return New-MlsCheckResult -Passed $false `
        -Observed "npm run validate:golden exited $($result.ExitCode): $(($result.Line | Select-Object -Last 5) -join ' / ')" -Final `
        -Detail 'V7.2 rolls back in the repo only - no cloud state is involved; fix the schema or the fixtures via PR and re-run.'
}

function Get-AppEasyAuthClientId {
    <# The Entra client id an app's Easy Auth validates tokens against, read from the
       running app rather than supplied. It is the audience the probe must request, and
       Easy Auth publishes it in its own WWW-Authenticate `resource_id` on a 401. #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )
    return "$(Invoke-MlsAz -AllowFailure -Raw -Argument @(
            'containerapp', 'auth', 'show', '--resource-group', $ResourceGroupName, '--name', $Name,
            '--query', 'identityProviders.azureActiveDirectory.registration.clientId', '--output', 'tsv'
        ))".Trim()
}

function New-MlsHexToken {
    <# Cryptographically random lowercase hex - W3C trace-context ids are 16 bytes
       (trace id) and 8 bytes (span id), and both must be non-zero. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a random string; the audit changes no state anywhere.')]
    param([Parameter(Mandatory)][int]$ByteCount)
    $byte = [byte[]]::new($ByteCount)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($byte)
    # An all-zero trace id is invalid per the spec and would be dropped silently rather
    # than rejected loudly, so force one bit rather than trusting 2^-128.
    $byte[0] = $byte[0] -bor 1
    return -join ($byte | ForEach-Object { $_.ToString('x2') })
}

function Test-OtelSpan {
    <# V7.3 - a tagged synthetic request per app that actually REACHES application code,
       then look for its span in App Insights via KQL.

       WHY THE PROBE IS AUTHENTICATED. This criterion spent two runs failing against an
       App Insights resource that was correctly wired - right component, right
       instrumentation key on every container - and completely empty. The cause was not
       ingestion latency and not sampling:

         * the three dashboards are nginx serving a static React bundle, and Easy Auth's
           ONLY excluded path is /healthz, which nginx answers from its own config. No
           application code runs, so nothing emits a span.
         * every other path returns 401 AT EASY AUTH, so it never reaches data-api - the
           one app in the request chain that would emit an AppRequests row.
         * the browser SDK in each frontend never executes, because the probe is curl.

       So there was no request an ANONYMOUS probe could make that would produce a span,
       and no retry window could have changed that (F89).

       The fix is not to open an unauthenticated path - that would add anonymous surface
       to the app tier of a compliance demo to satisfy a check, which is backwards. Easy
       Auth already publishes the way in, and the Verifier already federates as
       mls-verifier, so it needs a token rather than a new credential. The deploy path
       grants it a probe role that confers NO application capability; a 403 from the app
       is a perfectly good result here, because the claim is "the request traversed Easy
       Auth and reached the application", not "the Verifier may read data".

       The emitting role is data-api, not the frontend, because the frontends emit
       nothing server-side. So AppRoleName cannot say which front door a request came
       through, and per-app attribution needs a carrier of its own.

       WHY THE CARRIER IS TRACEPARENT AND NOT A URL MARKER. The first version of this
       criterion hung `?probe=<run>-<app>` on the probe URL and looked for it in the
       span's Url. It matched nothing, for a reason worth writing down: data-api's
       AppRequests rows have Url EMPTY, always, and that is not a bug. Its span
       attributes come from an allowlist (apps/data-api/src/telemetry/attributes.ts)
       which deliberately excludes the raw path and query string as caller-controlled
       free text, along with every header and any SQL. So the criterion was not merely
       reading the wrong column - it was asking the application to record caller-supplied
       text in telemetry to satisfy an audit, in a demo whose stated design is that it
       never does. A check may not ask the system to weaken itself in order to pass.

       W3C trace context is the carrier the application already implements: the request
       middleware calls propagation.extract on the incoming headers, so a probe sending
       `traceparent: 00-<traceId>-<spanId>-01` produces an AppRequests row whose
       OperationId IS that trace id. One trace id per frontend gives exact per-app
       attribution with no application change, and it strengthens the claim: V7.3 now
       evidences end-to-end trace correlation - the feature the demo advertises - rather
       than the bare existence of a span. #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string[]]$AppName,
        [Parameter(Mandatory)][string]$ProbePath,
        [AllowEmptyString()][string]$WorkspaceId,
        # roleName -> W3C trace id. Minted once per run by the caller so that retries
        # re-probe under the SAME ids and spans from every attempt accumulate against one
        # query, instead of each attempt starting the evidence over.
        [Parameter(Mandatory)][hashtable]$TraceIdByApp
    )
    if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
        return New-MlsCheckResult -Passed $false -Observed 'no Log Analytics workspace (customer) id available' -Final `
            -Detail 'Pass -LogAnalyticsWorkspaceId / $env:MLS_LAW_CUSTOMER_ID (the L6 deployment output).'
    }
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()
    $statusByApp = @{}
    foreach ($name in $AppName) {
        $roleName = ($name -replace '^mls-', '') -replace '-demo-ca$', ''
        $fqdn = Get-AppFqdn -ResourceGroupName $ResourceGroupName -Name $name
        if ([string]::IsNullOrWhiteSpace($fqdn)) {
            $problem.Add("$name has no ingress FQDN")
            continue
        }
        $clientId = Get-AppEasyAuthClientId -ResourceGroupName $ResourceGroupName -Name $name
        if ([string]::IsNullOrWhiteSpace($clientId) -or $clientId -eq 'None') {
            $problem.Add("$name has no Easy Auth client id, so no audience to request a token for")
            continue
        }
        $token = "$(Invoke-MlsAz -AllowFailure -Raw -Argument @(
                'account', 'get-access-token', '--resource', $clientId, '--query', 'accessToken', '--output', 'tsv'
            ))".Trim()
        if ([string]::IsNullOrWhiteSpace($token)) {
            # Distinguish "cannot get a token" from "got in and saw nothing": they have
            # completely different fixes, and the old message conflated them.
            $problem.Add("$roleName could not obtain a token for audience $clientId - the app registration needs a service principal and the Verifier needs its probe role (L3 applies both; see F89)")
            continue
        }
        $traceId = "$($TraceIdByApp[$roleName])"
        if ([string]::IsNullOrWhiteSpace($traceId)) {
            $problem.Add("$roleName was not issued a trace id, so its span could not be correlated")
            continue
        }
        $response = Invoke-MlsHttp -Uri "https://$fqdn$ProbePath" -TimeoutSec 60 `
            -Header @{
            Authorization = "Bearer $token"
            traceparent   = "00-$traceId-$(New-MlsHexToken -ByteCount 8)-01"
        }
        $status = "$(Get-MlsProperty -InputObject $response -Name 'StatusCode')"
        $statusByApp[$roleName] = $status
        # 401 means Easy Auth REJECTED the token, and no span can follow. Any other status -
        # including 403 or 404 from the application - means the request got through, which
        # is the whole claim.
        if ($status -eq '401') {
            $problem.Add("$roleName still 401 with a bearer token: Easy Auth rejected it, so the request never reached the application")
        }
    }
    $issued = @($TraceIdByApp.Values | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
    $rows = @()
    if ($issued.Count -gt 0) {
        $idList = ($issued | ForEach-Object { "'$_'" }) -join ', '
        $query = "AppRequests | where OperationId in ($idList) | project TimeGenerated, AppRoleName, OperationId, ResultCode, Name"
        $rows = @(Invoke-MlsAz -AllowFailure -Argument @(
                'monitor', 'log-analytics', 'query', '--workspace', $WorkspaceId,
                '--analytics-query', $query, '--timespan', 'PT1H', '--output', 'json'
            ))
    }
    foreach ($name in $AppName) {
        $roleName = ($name -replace '^mls-', '') -replace '-demo-ca$', ''
        $traceId = "$($TraceIdByApp[$roleName])"
        # Matched on the TRACE ID, not on AppRoleName: the span is emitted by whichever app
        # in the chain runs instrumented code (data-api), while the trace id says which
        # front door the request came through.
        $matched = @($rows | Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'OperationId')" -eq $traceId })
        $status = if ($statusByApp.ContainsKey($roleName)) { $statusByApp[$roleName] } else { 'not probed' }
        $emitter = @($matched | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'AppRoleName')" } |
                Where-Object { $_ } | Sort-Object -Unique) -join '/'
        $observed.Add("$roleName http=$status rows=$($matched.Count)$(if ($emitter) { " via $emitter" })")
        if ($matched.Count -lt 1) { $problem.Add("no AppRequests row correlated to $roleName's trace id $traceId") }
    }
    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ')
    }
    return New-MlsCheckResult -Passed $false -Observed (($observed -join '; ') + ' | ' + ($problem -join ' | ')) `
        -Detail 'A 401 is an ACCESS problem - the probe never reached the app, so no span could exist (L07 failure mode 3). A non-401 status with zero rows is one of three things, in order of likelihood: App Insights ingestion lag (the retry window covers 15 minutes of it); the traceparent header not surviving the hop chain (nginx and the Easy Auth sidecar both forward it by default, so suspect a proxy_set_header that drops it); or a broken connection string. Tell them apart with: AppRequests | where AppRoleName == ''data-api'' | top 5 by TimeGenerated desc - rows there but none here is a correlation problem, no rows at all is an emission problem.'
}

function Test-ApiRowPayload {
    <# V7.6 - THE CRITERION NOBODY WROTE.

       L7 signed off 5/5 for two days over an estate where every /api/tables route
       answered 503, and later 502. Not one of V7.1-V7.5 reads a row: V7.1 checks
       /healthz, which nginx answers from its own config without touching application
       code; V7.2 is a local schema check; V7.3 asks only that a span exists, and a 404
       emits one; V7.4 reads GitHub; V7.5 counts replicas. The layer verified that the
       plumbing existed and never that water came out of the tap (docs/DEMO-READINESS.md
       section D).

       This is the assertion that would have caught F98 (placeholder images serving
       nothing), F101 (data-api cannot authenticate to the lakehouse) and the empty cost
       dashboards on its own, on the day each began.

       It deliberately does NOT accept a 2xx alone. An empty array is a valid, correct,
       well-formed HTTP 200 - and it is exactly what a broken backend and an empty
       lakehouse both produce. "Responds" and "answers" are different claims, and only
       the second is worth a criterion. #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string[]]$AppName,
        [Parameter(Mandatory)][string]$ProbePath,
        [Parameter(Mandatory)][int]$MinimumRow
    )
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()

    foreach ($name in $AppName) {
        $roleName = ($name -replace '^mls-', '') -replace '-demo-ca$', ''
        $fqdn = Get-AppFqdn -ResourceGroupName $ResourceGroupName -Name $name
        if ([string]::IsNullOrWhiteSpace($fqdn)) {
            $problem.Add("$roleName has no ingress FQDN")
            continue
        }
        $clientId = Get-AppEasyAuthClientId -ResourceGroupName $ResourceGroupName -Name $name
        if ([string]::IsNullOrWhiteSpace($clientId) -or $clientId -eq 'None') {
            $problem.Add("$roleName has no Easy Auth client id, so no audience to request a token for")
            continue
        }
        $token = "$(Invoke-MlsAz -AllowFailure -Raw -Argument @(
                'account', 'get-access-token', '--resource', $clientId, '--query', 'accessToken', '--output', 'tsv'
            ))".Trim()
        if ([string]::IsNullOrWhiteSpace($token)) {
            $problem.Add("$roleName could not obtain a token for audience $clientId (see F89)")
            continue
        }

        $response = Invoke-MlsHttp -Uri "https://$fqdn$ProbePath" -TimeoutSec 60 `
            -Header @{ Authorization = "Bearer $token" }
        $status = "$(Get-MlsProperty -InputObject $response -Name 'StatusCode')"

        if ($status -ne '200') {
            # 502/503 is the F101 signature: the app is up, its upstream is not.
            $observed.Add("$roleName http=$status rows=n/a")
            $problem.Add("$roleName returned $status from $ProbePath, so it served no data")
            continue
        }

        # A BARE JSON ARRAY, not an envelope. GET /tables/:table answers `res.json(result.rows)`
        # - app.ts says so in its own header comment - and reports truncation in the
        # X-MLS-Truncated header instead. The first version of this criterion parsed
        # `payload.rows`, which is $null against an array, so it would have reported rows=0
        # and FAILED A WORKING API. Found because Paul opened the app and its error text
        # named the provider's `rows<T>` helper, which throws unless the body is an array.
        $rowCount = -1
        $body = "$(Get-MlsProperty -InputObject $response -Name 'Content')".Trim()
        # ARRAY-NESS COMES FROM THE RAW TEXT, NOT THE PARSED OBJECT. ConvertFrom-Json turns
        # `[]` into $null, so an EMPTY array and a NON-array are indistinguishable after
        # parsing - and those are two different findings: zero rows is a seeding problem,
        # a non-array is a contract violation. Deciding from the leading `[` keeps them apart.
        if (-not $body.StartsWith('[')) {
            $problem.Add("$roleName returned 200 but the body is not a JSON array; /tables/:table answers a bare array of rows")
            $observed.Add("$roleName http=200 rows=not-an-array")
            continue
        }
        try {
            $payload = $body | ConvertFrom-Json
            $rowCount = @($payload).Count
        }
        catch {
            $problem.Add("$roleName returned 200 but its body did not parse as JSON: $($_.Exception.Message)")
            $observed.Add("$roleName http=200 rows=unparseable")
            continue
        }

        $observed.Add("$roleName http=200 rows=$rowCount")
        if ($rowCount -lt $MinimumRow) {
            $problem.Add("$roleName returned $rowCount row(s) from $ProbePath, expected at least $MinimumRow")
        }
    }

    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ')
    }
    return New-MlsCheckResult -Passed $false -Observed (($observed -join '; ') + ' | ' + ($problem -join ' | ')) `
        -Detail 'A 502 or 503 here means the app is running and its data backend is not - as of 2026-09-01 that is F101: data-api authenticates as a user-assigned managed identity, and Fabric''s SQL endpoint accepts only users and application objects. A 200 with zero rows means the lakehouse is reachable but empty, which is an L5 seeding problem, not this one. The two are different failures and this criterion names which.'
}

function Test-InteractiveSignIn {
    <# V7.7 - CAN A HUMAN ACTUALLY SIGN IN?

       Nobody could, for the entire life of this project, and no criterion noticed
       (F110). Easy Auth's AAD provider signs users in with the implicit flow -
       `response_type=id_token&response_mode=form_post` - and Entra refuses that unless
       the app registration has web.implicitGrantSettings.enableIdTokenIssuance = true.
       It defaults to FALSE and nothing in infra/entra ever set it, so Entra posted an
       error back to the callback and the browser SAVED IT AS A FILE.

       Three existing checks pass straight over this. V7.1 gets 200 from /healthz, which
       Easy Auth explicitly excludes. V7.3 presents a bearer token, which never touches
       the interactive flow. frontend-auth.Tests.ps1 reads configuration, not behaviour.
       None of them signs in, so none of them could see it.

       This does not drive a browser - that is still the open half of
       docs/DEMO-READINESS.md section D. It asserts the two things that must be true for
       a browser to succeed, both readable without one:

         1. Easy Auth is IN FRONT of the app. /.auth/me must answer 401 from the auth
            middleware, identified by its own x-ms-middleware-request-id header. If nginx
            answers instead - serving index.html through the SPA fallback - the callback
            has nowhere to land and sign-in cannot complete however well Entra behaves.
         2. The registration will ISSUE the token the flow asks for. Without
            enableIdTokenIssuance the redirect to Entra still looks perfect, the sign-in
            page still renders, and the flow dies at the callback.

       A 401 here is the PASS. That reads oddly until you notice what the criterion is
       asking: not "is the door open" but "is there a door, and does the key exist". #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string[]]$AppName
    )
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()

    foreach ($name in $AppName) {
        $roleName = ($name -replace '^mls-', '') -replace '-demo-ca$', ''
        $fqdn = Get-AppFqdn -ResourceGroupName $ResourceGroupName -Name $name
        if ([string]::IsNullOrWhiteSpace($fqdn)) {
            $problem.Add("$roleName has no ingress FQDN")
            continue
        }

        # 1. Easy Auth must own /.auth, not the container behind it.
        $auth = Invoke-MlsHttp -Uri "https://$fqdn/.auth/me" -TimeoutSec 30
        $status = "$(Get-MlsProperty -InputObject $auth -Name 'StatusCode')"
        $headers = Get-MlsProperty -InputObject $auth -Name 'Headers'
        $middleware = ''
        if ($null -ne $headers) {
            foreach ($key in @($headers.Keys)) {
                if ("$key" -ieq 'x-ms-middleware-request-id') { $middleware = "$($headers[$key])" }
            }
        }
        if ($status -ne '401' -or [string]::IsNullOrWhiteSpace($middleware)) {
            $problem.Add("$roleName /.auth/me answered $status$(if (-not $middleware) { ' with no x-ms-middleware-request-id' }) - Easy Auth is not handling /.auth, so the sign-in callback has nowhere to land")
        }

        # 2. The registration must be able to issue the token the flow requests.
        $clientId = Get-AppEasyAuthClientId -ResourceGroupName $ResourceGroupName -Name $name
        if ([string]::IsNullOrWhiteSpace($clientId) -or $clientId -eq 'None') {
            $problem.Add("$roleName has no Easy Auth client id, so it is not published for interactive sign-in")
            $observed.Add("$roleName auth=$status idToken=n/a")
            continue
        }
        $idToken = "$(Invoke-MlsAz -AllowFailure -Raw -Argument @(
                'ad', 'app', 'show', '--id', $clientId,
                '--query', 'web.implicitGrantSettings.enableIdTokenIssuance', '--output', 'tsv'
            ))".Trim()
        $observed.Add("$roleName auth=$status idToken=$(if ($idToken) { $idToken } else { '<unreadable>' })")

        if ($idToken -ieq 'false') {
            $problem.Add("$roleName registration $clientId has enableIdTokenIssuance=false, so Entra will refuse the id_token Easy Auth asks for and the callback receives an error the browser saves as a file (F110)")
        }
        elseif ($idToken -inotlike 'true') {
            $problem.Add("$roleName registration $clientId - could not read enableIdTokenIssuance, so this criterion could not confirm sign-in is possible")
        }
    }

    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ')
    }
    return New-MlsCheckResult -Passed $false -Observed (($observed -join '; ') + ' | ' + ($problem -join ' | ')) `
        -Detail 'Fix with: az ad app update --id <clientId> --enable-id-token-issuance true. L7''s redirect-URI step does this for every published dashboard on each run, so a failure here means that step was skipped or the registration was changed outside the pipeline. This criterion does not open a browser - that gap is DEMO-READINESS section D - it asserts the two preconditions a browser needs.'
}

function Test-CanaryPipeline {
    <# V7.4 - every required check green on the canary PR, and the path filters behaving:
       both app pipelines when the canary touches apps/shared/**, only the matching app's
       pipeline when it touches a single app path. #>
    param(
        [Parameter(Mandatory)][string]$Repository,
        [AllowEmptyString()][string]$PullRequestNumber
    )
    if ([string]::IsNullOrWhiteSpace($PullRequestNumber)) {
        return New-MlsCheckResult -Passed $false -Observed 'no canary PR number supplied' -Final `
            -Detail 'The L7 lead opens the canary PR (the Verifier never writes to the repo) and posts its number; pass -CanaryPrNumber / $env:MLS_L7_CANARY_PR.'
    }
    $pullRequest = Invoke-MlsGh -AllowFailure -Argument @(
        'pr', 'view', $PullRequestNumber, '--repo', $Repository, '--json', 'number,headRefOid,files,state'
    )
    if ($null -eq $pullRequest) {
        return New-MlsCheckResult -Passed $false -Observed "canary PR #$PullRequestNumber could not be read"
    }
    $headSha = "$(Get-MlsProperty -InputObject $pullRequest -Name 'headRefOid')"
    $path = @(Get-MlsProperty -InputObject $pullRequest -Name 'files' | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'path')" })
    $checkRuns = @(Get-MlsCollection -Response (Invoke-MlsGh -Argument @('api', "repos/$Repository/commits/$headSha/check-runs")))
    $conclusion = @($checkRuns | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'conclusion')" })
    $names = @($checkRuns | ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'name')" })
    # SKIPPED IS NOT A FAILURE, AND THIS CRITERION USED TO SAY IT WAS.
    #
    # A canary that touches only apps/shared/** is a documentation-shaped change: the five
    # per-app pipelines build and scan, and their `deploy to Container Apps` jobs SKIP,
    # because the guard added for F83 declines to roll an image onto an app when nothing
    # about that app changed. That is the guard working. Counting it as "not green" failed
    # V7.4 on a canary whose CI was entirely correct - five skips out of 28 checks.
    #
    # The repo already knows this: `skipped` is not `failure` is written into the workflow
    # comments that F58 came from. The criterion had not learned it.
    #
    # `neutral` joins it for the same reason: a check that declines to judge has not failed.
    # Everything else - failure, cancelled, timed_out, action_required - still fails, and a
    # check still RUNNING is caught by the null conclusion.
    $acceptable = @('success', 'skipped', 'neutral')
    $notSuccess = @($checkRuns | Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'conclusion')" -notin $acceptable } |
            ForEach-Object { "$(Get-MlsProperty -InputObject $_ -Name 'name')=$(Get-MlsProperty -InputObject $_ -Name 'conclusion')" })
    $skipped = @($checkRuns | Where-Object { "$(Get-MlsProperty -InputObject $_ -Name 'conclusion')" -eq 'skipped' })
    if ($checkRuns.Count -eq 0) {
        return New-MlsCheckResult -Passed $false -Observed "no check runs on canary head $headSha yet"
    }
    if ($notSuccess.Count -gt 0) {
        return New-MlsCheckResult -Passed $false -Observed "checks not green: $($notSuccess -join ', ') (of $($conclusion.Count))"
    }

    # Path-filter assertion: working path filters are part of the criterion's intent.
    $touchesShared = @($path | Where-Object { $_ -like 'apps/shared/*' }).Count -gt 0
    $touchedApp = @($path | Where-Object { $_ -like 'apps/*' -and $_ -notlike 'apps/shared/*' } |
            ForEach-Object { ($_ -split '/')[1] } | Sort-Object -Unique)
    $ranLaunchOps = @($names | Where-Object { $_ -like '*launch-ops*' }).Count -gt 0
    $ranControlTower = @($names | Where-Object { $_ -like '*control-tower*' }).Count -gt 0
    $filterProblem = [System.Collections.Generic.List[string]]::new()
    if ($touchesShared) {
        if (-not ($ranLaunchOps -and $ranControlTower)) {
            $filterProblem.Add('canary touches apps/shared/** but not both app pipelines ran')
        }
    }
    elseif ($touchedApp.Count -eq 1) {
        if ($touchedApp[0] -eq 'launch-ops' -and $ranControlTower) { $filterProblem.Add('canary touches only launch-ops but the control-tower pipeline also ran') }
        if ($touchedApp[0] -eq 'control-tower' -and $ranLaunchOps) { $filterProblem.Add('canary touches only control-tower but the launch-ops pipeline also ran') }
    }
    if ($filterProblem.Count -gt 0) {
        return New-MlsCheckResult -Passed $false -Observed ($filterProblem -join ' | ') -Final `
            -Detail 'Path-filter drift is exactly what turns "per-app CI" into "monolithic CI" silently (L07 failure mode 4).'
    }
    return New-MlsCheckResult -Passed $true `
        -Observed "$($conclusion.Count) check run(s) on #$PullRequestNumber; $($skipped.Count) skipped (deploy jobs the F83 guard declined), rest success; paths touched: $($path -join ', ')"
}

function Test-ReplicaScaling {
    <# V7.5 - three phases per app: 0 before load, >= 1 under load, back to 0 after the
       idle window. Phase 3 waits 15 minutes before the first read; a nonzero count at
       +30 minutes is a FAIL (idle-cost model broken).

       Phase 0 first waits for the app to BE at zero, because V7.1 has already curled every
       endpoint by the time this runs and left them warm (F89). #>
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string[]]$AppName,
        [Parameter(Mandatory)][string]$HealthPath,
        [Parameter(Mandatory)][int]$LoadRequestCount,
        [Parameter(Mandatory)][double]$ScaleInWaitMinutes,
        [Parameter(Mandatory)][double]$ScaleInDeadlineMinutes
    )
    $problem = [System.Collections.Generic.List[string]]::new()
    $observed = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $AppName) {
        # PHASE 0 - ESTABLISH THE PRECONDITION, DO NOT ASSERT IT.
        #
        # This criterion used to open by reading the replica count and failing if it was
        # not 0. It observed launch-ops at 1->1->0 and failed, while control-tower next to
        # it managed 0->1->0 - not because the apps differ, but because V7.1 runs FIRST in
        # the same audit and curls every endpoint, which wakes them. An earlier criterion
        # in the same run guaranteed the precondition of a later one was false, and which
        # app happened to have scaled back down by then was a race (F89).
        #
        # "Starts at 0" is not the claim. The claim is "goes 0 -> N -> 0". So wait for the
        # app to be at 0 before starting, and if it will not settle, THAT is the finding -
        # an app that never scales to zero is exactly what this criterion exists to catch,
        # and it is now reported as itself rather than as a corrupted phase 1.
        $settleWaited = 0.0
        $phaseOne = -1
        while ($true) {
            $phaseOne = [int](Invoke-MlsAz -AllowFailure -Raw -Argument @(
                    'containerapp', 'replica', 'list', '--resource-group', $ResourceGroupName, '--name', $name,
                    '--query', 'length(@)', '--output', 'tsv'
                ))
            if ($phaseOne -eq 0 -or $settleWaited -ge $ScaleInDeadlineMinutes) { break }
            Wait-MlsRetryInterval -Seconds ([math]::Min($ScaleInWaitMinutes, [math]::Max($ScaleInDeadlineMinutes - $settleWaited, 0)) * 60)
            $settleWaited += $ScaleInWaitMinutes
        }
        if ($phaseOne -ne 0) {
            $observed.Add("$name never settled to 0 (still $phaseOne after $settleWaited min idle)")
            $problem.Add("$name did not scale to 0 within $ScaleInDeadlineMinutes min before the probe, so the 0->N->0 cycle could not be observed")
            continue
        }
        $fqdn = Get-AppFqdn -ResourceGroupName $ResourceGroupName -Name $name
        if ([string]::IsNullOrWhiteSpace($fqdn)) {
            $problem.Add("$name has no ingress FQDN")
            continue
        }
        for ($i = 0; $i -lt $LoadRequestCount; $i++) {
            Invoke-MlsHttp -Uri "https://$fqdn$HealthPath" -TimeoutSec 60 | Out-Null
        }
        $phaseTwo = [int](Invoke-MlsAz -AllowFailure -Raw -Argument @(
                'containerapp', 'replica', 'list', '--resource-group', $ResourceGroupName, '--name', $name,
                '--query', 'length(@)', '--output', 'tsv'
            ))
        $waited = 0.0
        $phaseThree = -1
        while ($true) {
            Wait-MlsRetryInterval -Seconds ([math]::Min($ScaleInWaitMinutes, [math]::Max($ScaleInDeadlineMinutes - $waited, 0)) * 60)
            $waited += $ScaleInWaitMinutes
            $phaseThree = [int](Invoke-MlsAz -AllowFailure -Raw -Argument @(
                    'containerapp', 'replica', 'list', '--resource-group', $ResourceGroupName, '--name', $name,
                    '--query', 'length(@)', '--output', 'tsv'
                ))
            if ($phaseThree -eq 0 -or $waited -ge $ScaleInDeadlineMinutes) { break }
        }
        $observed.Add("$name 0->N->0 observed as $phaseOne->$phaseTwo->$phaseThree (settled after $settleWaited min, phase 3 at +$waited min)")
        # No phase-1 assertion: phase 0 above establishes it or reports why it could not.
        if ($phaseTwo -lt 1) { $problem.Add("$name did not scale out under load (still $phaseTwo)") }
        if ($phaseThree -ne 0) { $problem.Add("$name still has $phaseThree replica(s) at +$waited min") }
    }
    if ($problem.Count -eq 0) {
        return New-MlsCheckResult -Passed $true -Observed ($observed -join '; ')
    }
    return New-MlsCheckResult -Passed $false -Observed (($observed -join '; ') + ' | ' + ($problem -join ' | ')) -Final `
        -Detail 'Replicas that never return to 0 mean health-probe traffic keeping the app warm or a scale-rule floor set to 1 by a template change - an unrequested drift, so a defect rather than a G2 question (L07 failure mode 5).'
}

function Invoke-Main {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is consumed inside the criterion scriptblocks; PSSA cannot see through scriptblock closures.')]
    param(
        [string]$ResourceGroupName = 'mls-rg-apps',
        [string[]]$AppName = @(),
        # The path V7.3 probes THROUGH Easy Auth. It must reach application code, unlike
        # $HealthPath, which nginx answers from its own config.
        #
        # Any /api/* path emits a span - even a 404 - so the criterion is satisfiable
        # whatever this is set to. It names a REAL route anyway. nginx's trailing-slash
        # proxy_pass strips the /api prefix, so this arrives at data-api as
        # /tables/launches, one of the ten allowlisted tables. The previous default,
        # /api/launches, arrived as /launches and 404'd on every probe of every run: the
        # criterion was technically satisfiable while only ever exercising a route the
        # product does not have, which is not a demonstration anyone wants to give.
        [string]$ProbePath = '/api/tables/launches',
        [int]$MinimumRow = 1,
        [string]$DeployManifestPath,
        [string]$LogAnalyticsWorkspaceId,
        [string]$Repository,
        [string]$CanaryPrNumber,
        [string]$HealthPath = '/healthz',
        [int]$LoadRequestCount = 20,
        [double]$ScaleInWaitMinutes = 15,
        [double]$ScaleInDeadlineMinutes = 30,
        [string]$ReportRoot,
        [switch]$NoRetry,
        [string[]]$OnlyCriterion = @()
    )
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $repositoryName = Resolve-MlsInput -Name 'Repository' -Value $Repository -EnvironmentVariable @('MLS_GITHUB_REPO', 'MLS_REPOSITORY') `
        -Hint 'The repo whose per-app CI V7.4 reads.'

    $manifestPath = $DeployManifestPath
    if ([string]::IsNullOrWhiteSpace($manifestPath)) { $manifestPath = [Environment]::GetEnvironmentVariable('MLS_L7_MANIFEST') }
    $manifest = $null
    if (-not [string]::IsNullOrWhiteSpace($manifestPath) -and (Test-Path -LiteralPath $manifestPath)) {
        $manifest = Get-MlsJsonFile -Path $manifestPath -Purpose 'L7 deploy manifest: per-app image digests recorded by the app CI runs'
    }
    $workspaceId = $LogAnalyticsWorkspaceId
    if ([string]::IsNullOrWhiteSpace($workspaceId)) { $workspaceId = [Environment]::GetEnvironmentVariable('MLS_LAW_CUSTOMER_ID') }
    $canary = $CanaryPrNumber
    if ([string]::IsNullOrWhiteSpace($canary)) { $canary = [Environment]::GetEnvironmentVariable('MLS_L7_CANARY_PR') }
    # One trace id per frontend, minted once for the whole run - see Test-OtelSpan on why
    # the correlation key is W3C trace context rather than a marker in the URL.
    $traceIdByApp = @{}
    foreach ($frontend in $AppName) {
        $traceIdByApp[(($frontend -replace '^mls-', '') -replace '-demo-ca$', '')] = New-MlsHexToken -ByteCount 16
    }

    $context = New-MlsAuditContext -Layer 7 -Title 'Apps: spec-renderer, launch-ops, control tower, per-app CI' `
        -ScriptName 'verification/layer-07-audit.ps1' -ReportRoot $ReportRoot -NoRetry:$NoRetry `
        -OnlyCriterion $OnlyCriterion
    Add-MlsPreflight -Context $context -Name 'Resource group' -Value $ResourceGroupName
    Add-MlsPreflight -Context $context -Name 'Apps' -Value ($AppName -join ', ')
    Add-MlsPreflight -Context $context -Name 'Deploy manifest' -Value "$manifestPath" -Status $(if ($manifest) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'LAW customer id' -Value "$workspaceId" -Status $(if ($workspaceId) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Canary PR' -Value "$canary" -Status $(if ($canary) { 'OK' } else { 'ABSENT' })
    Add-MlsPreflight -Context $context -Name 'Probe path' -Value $ProbePath
    Add-MlsPreflight -Context $context -Name 'Probe trace ids' -Value (($traceIdByApp.GetEnumerator() | Sort-Object -Property Key |
                ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')
    Add-MlsNote -Context $context -Message 'The control tower''s Ask tab ships dark at L7 and is deliberately not part of any L7 criterion, so a dark tab cannot fail this layer (L07.md Purpose).'

    # L07: Container Apps revision readiness
    Invoke-MlsCriterion -Context $context -Id 'V7.1' -Control @('3.4.1') `
        -Description 'Public endpoints return 200 with correct content hash markers' `
        -Command "az containerapp show -g $ResourceGroupName -n <app> --query properties.configuration.ingress.fqdn -o tsv`nGET https://<fqdn>$HealthPath" `
        -Expected 'HTTP 200 from both apps; health payload content-hash marker equals the image digest recorded in the deploy run' `
        -PollIntervalSeconds 60 `
        -RetryWindowMinutes 10 `
        -Test { Test-PublicEndpoint -ResourceGroupName $ResourceGroupName -AppName $AppName -HealthPath $HealthPath -Manifest $manifest } | Out-Null

    # -Control @(): schema-validation of the renderer's own output against golden fixtures
    # is a functional-correctness/code-quality check for the UI library, not a CUI
    # protection assertion.
    Invoke-MlsCriterion -Context $context -Id 'V7.2' -Control @() `
        -Description 'Renderer schema validation passes on golden specs' `
        -Command 'npm --prefix apps/shared/spec-renderer run validate:golden' `
        -Expected 'exit 0; every golden spec valid against the component-spec JSON Schema' -NoRetry `
        -Test { Test-GoldenSpec -RepoRoot $repoRoot } | Out-Null

    # L07: App Insights ingestion latency is typically 2-10 min
    Invoke-MlsCriterion -Context $context -Id 'V7.3' -Control @('3.3.1') `
        -Description 'OTel spans from a synthetic request visible in App Insights via KQL' `
        -Command "az account get-access-token --resource <easy-auth-client-id>`nGET https://<fqdn>$ProbePath  -H 'Authorization: Bearer <token>'  -H 'traceparent: 00-<traceId>-<spanId>-01'   # one per app`naz monitor log-analytics query --workspace <lawCustomerId> --analytics-query `"AppRequests | where OperationId in ('<traceId>', ...) | project TimeGenerated, AppRoleName, OperationId, ResultCode, Name`" --timespan PT1H" `
        -Expected '>= 1 AppRequests row per app whose OperationId is that app''s probe trace id; the row''s AppRoleName is the instrumented app in the chain (data-api), not the static frontend' `
        -RetryWindowMinutes 15 `
        -Test {
        Test-OtelSpan -ResourceGroupName $ResourceGroupName -AppName $AppName -ProbePath $ProbePath `
            -WorkspaceId $workspaceId -TraceIdByApp $traceIdByApp
    } | Out-Null

    # -Control @(): validates CI/CD path-filter plumbing (the right app pipeline runs for
    # the right change) and that its checks are green - pipeline correctness, not a formal
    # change-approval or change-logging assertion (there is no human-review-required gate
    # in play here, and "checks are green" does not by itself evidence 3.4.3's
    # track/review/approve/log workflow).
    # L07: waits on a canary PR s CI run
    Invoke-MlsCriterion -Context $context -Id 'V7.4' -Control @() `
        -Description 'Per-app CI green on a canary PR' `
        -Command "gh pr view <canary-pr> --json number,headRefOid,files,state`ngh api repos/$repositoryName/commits/<canary-sha>/check-runs" `
        -Expected 'every required check concludes success; path filters fire for the touched app(s) only' `
        -RetryWindowMinutes 15 `
        -Test { Test-CanaryPipeline -Repository $repositoryName -PullRequestNumber $canary } | Out-Null

    # -Control @(): autoscale/idle-cost behaviour check, not CUI protection.
    Invoke-MlsCriterion -Context $context -Id 'V7.5' -Control @() `
        -Description 'Replicas scale 0 -> N -> 0' `
        -Command "az containerapp replica list -g $ResourceGroupName -n <app> --query `"length(@)`"   # phase 1: expect 0`n# phase 2: $LoadRequestCount concurrent GETs, then re-read: expect >= 1`n# phase 3: after the scale-in window: expect 0" `
        -Expected "0 before load; >= 1 under load; back to 0 within $ScaleInDeadlineMinutes minutes of idle" -NoRetry `
        -Test {
        Test-ReplicaScaling -ResourceGroupName $ResourceGroupName -AppName $AppName -HealthPath $HealthPath `
            -LoadRequestCount $LoadRequestCount -ScaleInWaitMinutes $ScaleInWaitMinutes -ScaleInDeadlineMinutes $ScaleInDeadlineMinutes
    } | Out-Null

    # L07: the criterion that closes DEMO-READINESS section D.
    Invoke-MlsCriterion -Context $context -Id 'V7.6' -Control @('3.4.1') `
        -Description 'The data API answers with rows, not merely with a status code' `
        -Command "az account get-access-token --resource <easy-auth-client-id>`nGET https://<fqdn>$ProbePath  -H 'Authorization: Bearer <token>'`n# assert HTTP 200 AND (.rows | length) >= $MinimumRow" `
        -Expected "HTTP 200 from every frontend with at least $MinimumRow row(s) in the bare JSON array /tables/:table returns. A 2xx alone is NOT sufficient: an empty array is a well-formed 200, and is what both a broken backend and an empty store return." `
        -PollIntervalSeconds 30 `
        -RetryWindowMinutes 5 `
        -Test {
        Test-ApiRowPayload -ResourceGroupName $ResourceGroupName -AppName $AppName `
            -ProbePath $ProbePath -MinimumRow $MinimumRow
    } | Out-Null

    # L07: the criterion that would have caught F110 - see DEMO-READINESS section D.
    Invoke-MlsCriterion -Context $context -Id 'V7.7' -Control @('3.5.1', '3.5.2') `
        -Description 'A human can complete an interactive sign-in' `
        -Command "GET https://<fqdn>/.auth/me   # expect 401 WITH x-ms-middleware-request-id`naz ad app show --id <easy-auth-client-id> --query web.implicitGrantSettings.enableIdTokenIssuance" `
        -Expected 'Easy Auth answers /.auth itself (401 carrying x-ms-middleware-request-id, not the SPA fallback), and every published dashboard''s registration has enableIdTokenIssuance=true so Entra will issue the token the login flow requests' `
        -RetryWindowMinutes 5 `
        -Test { Test-InteractiveSignIn -ResourceGroupName $ResourceGroupName -AppName $AppName } | Out-Null

    return $context
}

if (-not $env:MLS_SKIP_MAIN) {
    try {
        $auditContext = Invoke-Main -ResourceGroupName $ResourceGroupName -AppName $AppName `
            -DeployManifestPath $DeployManifestPath -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId `
            -Repository $Repository -CanaryPrNumber $CanaryPrNumber -HealthPath $HealthPath -ProbePath $ProbePath -MinimumRow $MinimumRow `
            -LoadRequestCount $LoadRequestCount -ScaleInWaitMinutes $ScaleInWaitMinutes `
            -ScaleInDeadlineMinutes $ScaleInDeadlineMinutes -ReportRoot $ReportRoot -NoRetry:$NoRetry `
            -OnlyCriterion $OnlyCriterion
    }
    catch {
        Write-MlsStatus -Message "layer-07-audit could not start: $($_.Exception.Message)" -Color Red
        exit 2
    }
    $reportFile = Write-MlsReport -Context $auditContext
    Write-MlsStatus -Message "report: $($reportFile.MarkdownPath)"
    exit (Get-MlsExitCode -Context $auditContext)
}
