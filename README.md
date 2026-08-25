# Meridian Launch Systems — Azure DevSecOps Demo

An agent-team-built, fully code-defined enterprise Azure environment themed for the space
launch industry. The **repo is the product; the Azure environment is a build artifact** —
it can be destroyed and rebuilt from nothing via pipelines to keep idle cost near zero.

*Meridian Launch Systems* is a fictional company. All data is synthetic.

## Status

**Turn-key. Phase Q complete (2026-08-25)** —
[completion report](verification/reports/phase-q-completion.md), preceded by
[Phase P](verification/reports/phase-p-completion.md).

Everything that does not require a live tenant is authored, tested and wired: data
generators and seeding, the SQL schema, the Fabric lakehouse loaders, the renderer
library, both frontends, the data API, the MCP tool server with real cloud adapters,
the Copilot Studio agent definition and ALM, OpenTelemetry throughout, the full
DevSecOps chain, **all 11 Verifier audit scripts wired into their layer workflows**, and
the `up.ps1` / `down.ps1` fuse. Gates: 597 Pester, 30 pytest, 7 green npm packages,
PowerShell analyzer at zero across every severity, actionlint clean on 22 workflows,
every Bicep layer building clean.

**Nothing has been written to Azure** — no `az login` has ever existed on this machine —
and the public repo has not been published. Both await sponsor go-ahead.

**Architecture amendment, 2026-08-24 (sponsor-directed):** all runtime LLM work moves
inside the Microsoft landscape.
[The amendment](docs/superpowers/specs/2026-08-24-amendment-copilot-studio.md) replaces
the self-hosted copilot service with a **custom Microsoft Copilot Studio agent**, and the
authored triage script with **GitHub Copilot Autofix**. There is now **no LLM API key
anywhere in the system** — CI authenticates only by OIDC/workload identity federation.
Decisions in force: monorepo, dual E5 trials, Fabric trial capacity first; the
2026-08-22 LLM-provider decision is void.

| Gate | Meaning | Status |
|------|---------|--------|
| G0 | Human bootstrap (tenant, OIDC root, Fabric capacity, licensing, Power Platform environment + Copilot Studio meter) | Deferred by sponsor — trial-rate strategy in `docs/runbooks/g0-bootstrap.md` |
| G1 | One-time master plan approval | **Amended 2026-08-22:** scaffold phase approved (Phase P); Azure deploy authorization (G1b) awaits tenant activation. **Amended 2026-08-24:** L8 and L10 rebuilt on Copilot Studio / Copilot Autofix |
| G2 | Spend-profile changes (per occurrence) | n/a — but note: the Fabric data agent needs a **paid F2**, so showpiece #1's knowledge source will require a G2 (or runs on its documented tools-only fallback) |
| G3 | Tenant-level destructive ops (per occurrence) | n/a — now also covers the Power Platform environment, the agent and its solution |
| G4 | Exception escalation (event-driven) | n/a |

## Key documents

- [Project brief (decision record)](docs/BRIEF.md)
- [Design spec + pressure-test findings](docs/superpowers/specs/2026-08-22-azure-devsecops-demo-design.md)
- [Copilot Studio amendment (in force)](docs/superpowers/specs/2026-08-24-amendment-copilot-studio.md)
- [G1 master plan](docs/superpowers/plans/2026-08-22-g1-master-plan.md)
- [Working agreements for all agents](CLAUDE.md)

## Run locally

The apps and the MCP tool layer run pre-tenant in **local data mode** — no Azure, no
credentials. Requires Node 20+ and Python 3.11+.

```sh
# 1. Generate the synthetic dataset (deterministic, seed 20260822; gitignored output)
cd data && python -m generators build && cd ..

# 2. Install the npm workspaces (root manifest covers apps/* and apps/shared/*)
npm install

# 3. Run an app — http://localhost:5173 and http://localhost:5174
npm run dev:launch-ops
npm run dev:control-tower

# 4. Run the MCP tool server and exercise the five tools against local data
npm run dev:mcp-tools
```

`launch-ops` reads `data/generated/*.json`; `control-tower` reads committed feed
fixtures for its Dev/Sec tabs and `data/generated/` for Ops. Dev mode defaults to
local data; set `LOCAL_DATA=1` to force it for a production build, or
`VITE_DATA_MODE=api` to point at the live backends wired at L7.

`npm run build` and `npm test` at the root run across all workspaces.

**What you cannot run locally, stated plainly.** Since the 2026-08-24 amendment,
showpiece #1's *agent* is **cloud-only**: Microsoft Copilot Studio has no local runtime,
so the agent cannot be started, tested, or demoed on a laptop. It requires the tenant, a
Power Platform environment, and a published agent. What remains locally runnable is
everything around it — both frontends, the shared renderer, and the **MCP tool layer**
with its five tools and their tests, which is where the copilot's data access actually
lives. The golden-question eval suite runs locally against the MCP tools and only against
the deployed agent once it exists. This is a real capability the previous design had and
this one does not; it is recorded as open item P-8 in the
[Phase P plan](docs/superpowers/plans/2026-08-22-phase-p-pre-tenant-scaffold.md).

## The three showpieces

1. **Copilot — a custom Microsoft Copilot Studio agent** answering cross-domain
   natural-language questions, embedded in the control tower's **Ask** tab over Direct
   Line and replying in **Adaptive Cards** (declarative JSON UI, never generated code).
   Its knowledge is a **Fabric data agent** over the lakehouse (preview integration, and
   it needs a paid F2 capacity — there is a documented tools-only fallback); its tools are
   the five ops/sec/cost tools re-hosted as an **MCP server** on Container Apps. The
   agent is a Power Platform solution that lives in this repo and deploys by pipeline —
   edit it in a browser and the auditor fails the layer.
2. **Control tower** — Dev / Sec / Ops posture on Well-Architected pillars, fed by live
   Azure, GitHub, and Defender APIs plus cost exports in the lakehouse. Now also the host
   for showpiece #1.
3. **Self-healing pipeline** — vulnerability finding → **GitHub Copilot Autofix** writes
   the code fix (Dependabot writes the dependency ones) → patch PR → CI gauntlet →
   auto-merge on green → deploy → finding closed. Both healers are GitHub platform
   features, free on a public repo; we wrote neither. The PR trail is the demo.
