# `infra/copilot-studio` — the Copilot Studio agent as code (L8)

Showpiece #1, rebuilt per
[`docs/superpowers/specs/2026-08-24-amendment-copilot-studio.md`](../../docs/superpowers/specs/2026-08-24-amendment-copilot-studio.md).

Authored and **review-validated only**. Nothing in this tree has been run against a
tenant: no `pac` command, no Power Platform API call, no Fabric or Azure write. Live
deployment happens at L8 after G1b + G0, exactly like every other layer.

> ### The shape of the agent during the trial phase
>
> **Tools-only via MCP is the default.** Fabric data agents require a **paid F2+
> capacity**, and the Fabric 60-day trial capacity explicitly does not support Fabric AI
> experiences — data agents included. So on the demo's trial-first capacity the agent
> ships with the MCP tool server alone, which answers lakehouse questions against the SQL
> analytics endpoint as well as carrying the Ops/Sec/Cost tools.
>
> The **connected Fabric data agent is the paid-F2 upgrade**, and moving to paid F2 is a
> G2-gated spend increase. `layer-08-copilot-studio.yml` reflects this: the data agent
> job is opt-in (`enable_fabric_data_agent`, default `false`) and independent of the
> agent import.
>
> **Terminology:** Copilot Studio attaches a Fabric data agent under **Agents** — it is a
> *connected agent* reached through the Microsoft Fabric connector, **not** a "knowledge
> source" and not a tool. The amendment's original wording was wrong and has been
> corrected; this repo uses Copilot Studio's own terms.

```
infra/copilot-studio/
├── README.md              # this file — topology, pipeline, and the principle-#1 argument
├── agent-definition.md    # THE source of truth: prompt, bindings, auth, cards
├── export-agent.ps1       # portal -> repo   (pwsh 7 wrapper over pac)
├── import-agent.ps1       # repo -> portal   (pwsh 7 wrapper over pac)
└── solution/              # unpacked Power Platform solution source (see §4)
```

---

## 1. The uncomfortable part first — principle #1 vs. a portal product

**Principle #1 is "the repo is the source of truth".** Copilot Studio is a portal-authored
SaaS product. An agent is created by clicking, and the clicking happens in a tenant this
repo does not own. Pretending otherwise would be the easiest way to quietly break the
principle the whole demo is built on, so here is the actual position.

### What is genuinely true

1. **`agent-definition.md` is the specification, and it is reviewed like code.** The
   prompt, the data bindings, the tool binding, the conversation starters, the card
   rules and the auth model are all written down, in a PR, before they exist in a tenant.
   Someone can read this repo and know exactly what the agent is supposed to be without
   ever logging in.
2. **The exported solution is committed as unpacked source**, so every portal change
   arrives as a reviewable diff. A change made by clicking still has to survive a pull
   request before it counts.
3. **Deployment is one-directional and automated.** The `demo` environment is written
   only by `layer-08-copilot-studio.yml`, from `main`. A human editing the demo agent
   directly is drift, and the next pipeline run overwrites it.
4. **Everything downstream of the agent is fully IaC.** The MCP server, its identity and
   its ingress are Bicep. The Fabric data agent is a script in `infra/fabric/`. Only the
   agent shell itself is portal-shaped.

### Known limitations of the Fabric path (paid-F2 upgrade only)

Verified, and the reason §2's default is tools-only:

* **Paid F2+ capacity required.** The Fabric trial capacity does not support Fabric AI
  experiences, data agents included. Upgrading is a **G2** spend decision.
* **Preview integration.** Consuming a Fabric data agent from Copilot Studio is in
  preview.
* **Only validated for Microsoft Teams.** Quoted: *"Copilot Studio agent with a connected
  Fabric data agent is only validated for Microsoft Teams. Other channels may also work
  but haven't been formally tested."* This demo's channel is a **custom website over
  Direct Line**, so it is in the untested column even on paid capacity.
* **Cross-geo AI tenant settings required**, and responses *"may be sent outside of
  Fabric's compliance boundary or geographic region."*
* Responses capped at 25 rows × 25 columns; max 5 data sources; English only; read-only;
  lakehouse tables only; no cross-region data sources.

**Fallback in all of these cases is the same, and it is also the default:** keep the
Copilot Studio agent exactly as authored — same prompt, cards, channel, auth and
pipeline — and answer lakehouse questions through the MCP tool server. Only
`agent-definition.md` §3 falls away.

### What is not true, and we say so

* **The repo cannot originate the agent.** There is no supported "apply this YAML and
  materialise an agent" path. The first version of any component is created by a human in
  the authoring portal; the repo captures it afterwards. This is capture-and-enforce, not
  declare-and-apply, and the difference is real.
* **The exported solution is not fully human-readable.** Unpacked agent XML is diffable
  but not authorable. Nobody hand-edits it — which is why `agent-definition.md` exists as
  the layer a human actually reads and argues with.
* **Several things do not travel in the solution at all.** Manual authentication
  settings, Direct Line / web channel security, deployed channels, sharing, App Insights
  settings, and knowledge are all documented as not solution-aware — and connections
  (which is how both the Fabric connected agent and the MCP server attach) do not travel
  between environments either. Those are
  reproduced by the post-import checklist in §6 — a runbook, not a pipeline. **This is
  the single biggest honest gap in the "repo as source of truth" claim for L8**, and the
  checklist is the mitigation, not a fix.
* **The agent can no longer be proven on a laptop.** Amendment §3 already states this.
  The MCP tool layer stays locally testable; the agent does not.

**Net:** the repo is the source of truth for *what the agent must be* and the sole
authority for *what reaches the demo environment*. It is not the source of truth for the
bytes of the agent's runtime definition. That is a real limitation of the product and
recording it plainly is better than a slogan.

---

## 2. Environment topology

Two Power Platform environments, both **Developer** type and therefore **free**:

| Purpose | Environment | Written by | Read by |
|---|---|---|---|
| **Authoring** | `mls-authoring` | a human, in the Copilot Studio portal | `export-agent.ps1` / the export job |
| **Demo target** | `mls-demo` | `layer-08-copilot-studio.yml` only | the demo |

This is `copilot-alm-starter`'s dev → test/prod shape, collapsed to the one target this
estate actually has. `mls-demo` is the Power Platform half of the `demo` GitHub
environment: same lifecycle, same variables, same teardown story.

**Why two and not one.** With a single environment, export and import target the same
place and the pipeline proves nothing — you could delete the repo and the agent would be
unaffected. Two environments is the minimum that makes §1's claim #3 testable: the demo
agent is reachable *only* through `main`. The cost of the second environment is zero;
the cost of not having it is that principle #1 becomes unfalsifiable.

> This makes the amendment's G0 line "Power Platform environment (a developer environment
> is free)" into **two** environments. Both are free; it is two portal steps, not one.
> If the sponsor prefers a single environment, the degrade path is: point both scripts at
> it, accept that the round-trip is a tautology, and say so in the demo narration.

**Region:** create both in the geography matching `AZURE_LOCATION` (`eastus2` → United
States). The Fabric data agent cannot query across capacity regions, so keeping Power
Platform, Fabric and Azure in one geography avoids a class of failure that is tedious to
diagnose.

### Variables (GitHub `demo` environment — never committed)

| Variable | Kind | Used by | Notes |
|---|---|---|---|
| `POWERPLATFORM_ENVIRONMENT_URL` | variable | L8 import | the **demo** org URL, e.g. `https://<org>.crm.dynamics.com` |
| `POWERPLATFORM_AUTHORING_URL` | variable | L8 export | the **authoring** org URL |
| `POWERPLATFORM_SOLUTION_NAME` | variable | both | defaults to `MeridianLaunchCopilot` |
| `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` | variable | both | already present; reused for OIDC |
| `MCP_SERVER_URL` | variable | agent config | `mcpToolsEndpoint` output of `infra/bicep/apps/main.bicep` |
| `COPILOT_TOKEN_ENDPOINT` | variable | control-tower | copied from the portal channel panel — **do not construct it** |

`POWERPLATFORM_ENVIRONMENT_URL` joins the three identity variables in the L8 preflight
guard, so the whole layer no-ops cleanly before G0 like every other layer.

---

## 3. Authentication of the pipeline itself — no client secret

`copilot-alm-starter`'s pattern, which this repo follows because it composes with the
OIDC login already used by every other layer:

```yaml
- uses: azure/login@v2                       # federated OIDC, no secret
    with: { client-id: …, tenant-id: …, allow-no-subscriptions: true }
- uses: microsoft/powerplatform-actions/actions-install@v1
- run: pac auth create --environment "$URL" --name l8 --managedIdentity
```

`--managedIdentity` makes `pac` resolve credentials through `DefaultAzureCredential`,
which picks up the `AZURE_*` environment that `azure/login` just set. No client secret
exists anywhere in this path — consistent with the amendment making "no stored secrets in
CI" absolute.

A second documented option is to pass `app-id` + `tenant-id` to the
`microsoft/powerplatform-actions` steps and **omit `client-secret`**, which triggers their
federated-credential path (needs `permissions: id-token: write`). Both work; this repo
uses the first because it reuses the existing `azure/login` step rather than introducing a
second federation subject.

**G0 consequence:** the `mls-github-deployer` app registration needs a **Dynamics CRM /
Power Platform API permission**, a **federated credential** whose subject matches this
repo's workflow, and it must be added as an **application user with a security role in
both Power Platform environments**. That is portal work and it is a new G0 item.

---

## 4. What lives in `solution/`, and what does not

`solution/` receives the **unpacked** solution source produced by
`pac solution unpack` / the `unpack-solution` action:

```
solution/MeridianLaunchCopilot/
├── Other/Solution.xml                # unique name, version, publisher prefix
├── bots/                             # the agent
├── botcomponents/                    # topics, tools, knowledge references
├── Connectors/                       # custom connectors, incl. the MCP connector
└── environmentvariabledefinitions/
```

**Committed:** the unpacked directory tree above, and `settings/` deployment-settings
JSON if environment variables or connection references appear.

**Never committed:** the `.zip` itself. A zip is an opaque blob — it defeats code review,
bloats history, and merges catastrophically. The zip is a build artifact: produced during
export, uploaded to the run, repacked on import from the committed source. `.gitignore`
should carry `infra/copilot-studio/solution/*.zip`.

Format: **unpacked XML** (`--packagetype Unmanaged`), matching `copilot-alm-starter`.
A newer YAML source-control format exists (signalled by a `solutions/` subdirectory,
needs pac ≥ 2.4.1); it is not adopted here because the starter pattern the amendment
names uses XML and mixing the two mid-stream is avoidable churn.

**Export unmanaged, deploy managed.** Verified: a managed solution cannot be exported, so
the repo must hold the unmanaged source; the ALM guidance is to deploy managed. The
import job packs a managed build from the committed unmanaged source.

`solution/.gitkeep` holds the directory until the first export lands.

---

## 5. The round trip

```
   authoring portal (human clicks)
            │
            │  ⚠ FIRST: agent ⋮ → Advanced → Add required objects
            ▼
   export-agent.ps1 ── pac solution export ──▶ .zip ──▶ pac solution unpack
            │                                                   │
            │                                                   ▼
            └──────────────────────────────────▶  solution/  (committed, reviewed in a PR)
                                                                │
                                        merge to main ──────────┤
                                                                ▼
   layer-08-copilot-studio.yml ── pack (managed) ── pac solution import ──▶ mls-demo
                                                                │
                                                                ▼
                                              §6 post-import checklist (by hand)
```

**The `Add required objects` step is not optional.** Verified: *"The imported solution
reflects the agent's state only at the time that you originally exported it."* New
topics, tools, connectors, child agents and MCP servers added after the first export do
not flow to the target unless dependencies are pulled in first. Skipping it produces a
green pipeline that deploys a silently incomplete agent. `export-agent.ps1` prints the
reminder every run.

---

## 6. Post-import checklist (manual, every import)

None of this travels in a solution. Verified, not guessed.

1. **Publish the agent.** *"You must publish your imported agent before it can be
   shared."* Nothing works until this is done.
2. **Reconfigure authentication** (Settings → Security → Authentication → Authenticate
   manually → Entra ID V2). Manual auth settings are explicitly not solution-aware. Auth
   changes take effect only after publishing — so publish again.
3. **Paid-F2 path only:** re-create the Fabric connection and re-attach the data agent
   under **Agents** (a connected agent, not a knowledge source). Skip on the trial
   capacity — tools-only is the default there.
4. **Create the MCP connection** and confirm the tool list populates from the server.
5. **Re-enable generative orchestration** (Settings → Orchestration). MCP requires it,
   and so does the Fabric connected agent.
6. **Configure the channel:** Custom website; Web channel security; capture the Token
   Endpoint into `COPILOT_TOKEN_ENDPOINT`. Channel details import empty.
7. **Re-apply sharing** to the demo users. On the paid-F2 path also grant them read on
   the Fabric data agent and lakehouse (§3.3 of `agent-definition.md` uses user
   authentication).
8. **Re-set the icon** if it matters — icons can take 24 h to propagate and often do not
   survive import at all.
9. **Import order:** custom connectors first, then the connection reference with the
   agent solution.

The L8 audit script (`verification/layer-08-audit.ps1`, the Verifier's deliverable)
should assert as much of this as is readable through an API, so "somebody forgot step 2"
fails a pipeline instead of a demo.

---

## 7. Scripts

Both are pwsh 7, `#Requires -Version 7.0`, support `-WhatIf`, are idempotent, and
**fail before doing anything** when their preconditions are not met — the one behaviour
worth more than any other in a script that mutates a tenant.

| Script | Does |
|---|---|
| `export-agent.ps1` | resolves the authoring env → `pac solution export` → `pac solution unpack` into `solution/` → prints the diff summary |
| `import-agent.ps1` | validates `solution/` → `pac solution pack` (unmanaged and/or managed) → `pac solution import` → optional `pac solution publish` |

Preconditions each checks, with an actionable message and a non-zero exit on failure:

* `pac` is on `PATH` (`pac` ships with the Power Platform CLI or
  `powerplatform-actions/actions-install@v1`),
* an authentication profile exists (`pac auth list`),
* a target environment is resolvable (parameter, or `POWERPLATFORM_ENVIRONMENT_URL` /
  `POWERPLATFORM_AUTHORING_URL`).

`-WhatIf` on either prints the exact `pac` command lines it would run and exits without
invoking `pac` for anything mutating.

### Verified `pac` surface these wrap

| Command | Flags used |
|---|---|
| `pac auth create` | `--environment` `--name` `--managedIdentity` |
| `pac auth list` / `pac auth who` | — |
| `pac env select` / `pac env who` | `--environment` |
| `pac solution export` | `--name` `--path` `--overwrite` `[--managed]` `--async` `--max-async-wait-time` |
| `pac solution unpack` | `--zipfile` `--folder` `--packagetype Unmanaged` `--allowDelete` `--allowWrite` `--clobber` |
| `pac solution pack` | `--zipfile` `--folder` `--packagetype` |
| `pac solution import` | `--path` `--force-overwrite` `--publish-changes` `--async` `--max-async-wait-time` `--stage-and-upgrade` `[--settings-file]` |
| `pac solution create-settings` | `--solution-zip` `--solution-folder` `--settings-file` |
| `pac solution online-version` | `--solution-name` `[--solution-version]` |

`--packagetype` enum is exactly `Unmanaged` | `Managed` | `Both`; unpack and pack both
default to `Unmanaged`.

> Two documented inconsistencies, recorded so nobody rediscovers them: `--targetversion`
> on export is **deprecated and ignored**, and `--managed` is documented as a valueless
> switch while Microsoft's own example and `copilot-alm-starter` pass `--managed true` /
> `--managed false`. These scripts omit `--managed` for unmanaged and pass the bare
> switch for managed — the form the reference documents.

---

## 8. Cost

Copilot Studio pay-as-you-go, **$0.01 per Copilot Credit**, billed through the same Azure
subscription and the same $200 credit. **Zero idle cost** — no meter runs when nobody is
asking questions. Developer environments are free. The MCP container app is
`minReplicas: 0`, so it is free at idle too.

Enabling the pay-as-you-go meter against the subscription is a G0 item. It is a new
billable meter, so the first enablement should be stated as a spend-profile change (G2)
even though the idle delta is $0.

---

## 9. Related

* [`agent-definition.md`](agent-definition.md) — the specification
* [`infra/fabric/create-data-agent.ps1`](../fabric/create-data-agent.ps1) — the connected Fabric agent (paid-F2 upgrade)
* [`infra/bicep/apps/main.bicep`](../bicep/apps/main.bicep) — the MCP tool server
* [`.github/workflows/layer-08-copilot-studio.yml`](../../.github/workflows/layer-08-copilot-studio.yml) — the deploy path
* [copilot-alm-starter](https://github.com/microsoft/copilot-alm-starter) — the pattern
* [Solution management in Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/authoring-solutions-overview)
* [Import and export agents with solutions](https://learn.microsoft.com/en-us/microsoft-copilot-studio/authoring-solutions-import-export)
* [Agent solution mapping / drift](https://learn.microsoft.com/en-us/troubleshoot/power-platform/copilot-studio/lifecycle-management/agents-solution-mapping)
* [pac solution reference](https://learn.microsoft.com/en-us/power-platform/developer/cli/reference/solution)
* [powerplatform-actions](https://github.com/microsoft/powerplatform-actions)
* [Consume a Fabric data agent in Copilot Studio (preview)](https://learn.microsoft.com/en-us/fabric/data-science/data-agent-microsoft-copilot-studio)
* [Fabric trial capacity — AI experiences not supported](https://learn.microsoft.com/en-us/fabric/fundamentals/fabric-trial)
* [Connect an agent to an existing MCP server](https://learn.microsoft.com/en-us/microsoft-copilot-studio/mcp-add-existing-server-to-agent)
