# Amendment: Copilot Studio replaces the Anthropic API for all runtime LLM work

**Date:** 2026-08-24 · **Status:** sponsor-directed, in force
**Supersedes:** spec finding F4 and G1 decision 2 in
`2026-08-22-azure-devsecops-demo-design.md`
**Affects:** L8 (copilot service), L10 (self-healing), L5 (Fabric), L6/L7 (platform/apps),
G0 (bootstrap items), and the "no stored secrets" principle

## 1. How the superseded decision was actually made (provenance)

The sponsor asked how the Anthropic choice got locked. The honest record:

- The **sponsor's own brief** (`docs/BRIEF.md`, "Stack decisions") pre-framed the choice:
  *"Copilot service (showpiece #1): LLM-backed service (**Anthropic API or Azure AI
  Foundry**)…"* — two options, both named in the founding document.
- At G1 the Orchestrator turned that line into a **two-option question** and marked one
  Recommended:
  > *"LLM provider for the copilot service and self-healing triage (spec F4)?"*
  > 1. **Anthropic API (Recommended)** — "One key serves both showpieces; best model
  >    quality; simplest wiring. Key stored once as a GitHub Actions secret (the
  >    system's only stored secret)."
  > 2. **Azure AI Foundry** — "Keeps the story all-Azure; adds a Foundry resource, model
  >    quota, and a second SKU to manage."
- The sponsor selected option 1, in a batch of four G1 questions answered together.

**So the selection is real and on the record — but the menu was incomplete.**
Microsoft Copilot Studio was never offered. The Orchestrator inherited the brief's
binary framing instead of widening it, which it should have done for a demo whose
stated audience is Microsoft-shop enterprise leaders and whose principle #5 is
"Microsoft-native and standards-based." Recording this as an orchestration fault, not a
sponsor reversal: **the sponsor answered the question asked; the question was wrong.**

Process correction adopted: when a G1-class decision option list is inherited from the
brief, the Orchestrator must still state what the list *excludes* and why, so a
pre-framed binary cannot silently become a locked decision.

## 2. The decision now in force

All runtime LLM work moves inside the Microsoft/Azure landscape. **No Anthropic API key
exists anywhere in the system** — the "no stored secrets in CI" principle becomes
absolute rather than a documented exception (F4's exception is void).

### Showpiece #1 — copilot (L8), rebuilt as a custom Copilot Studio agent

| Layer | Technology |
|---|---|
| Agent | **Custom Copilot Studio agent**, authored as a Power Platform solution, exported to this repo and deployed by pipeline (Microsoft's `copilot-alm-starter` GitHub Actions pattern) — repo stays source of truth |
| NL → SQL over the lakehouse | **Fabric data agent** over `mls_operations`, attached as a **connected agent** (Copilot Studio's own term — *not* a "knowledge source"; corrected 2026-08-24 after verification). Native NL2SQL for Lakehouse/Warehouse. **Requires paid F2+ capacity — the Fabric trial capacity explicitly does not support AI experiences including Data agent**, so this path is a G2 upgrade and the tools-only MCP fallback is the default during the trial phase |
| Ops / Sec / Cost tools | The existing five tool implementations, re-hosted as an **MCP server** (Streamable HTTP; SSE is unsupported) on the Container Apps environment and attached to the agent as tools |
| Answer surface | **Embedded in the control-tower app via Direct Line** (sponsor decision, 2026-08-24), rendering **Adaptive Cards** — Microsoft's declarative JSON UI |
| Auth | Entra ID / managed identity throughout |
| Billing | Copilot Credits, pay-as-you-go at $0.01/credit through the Azure subscription — **zero idle cost**, draws on the same $200 credit |

The governance story is preserved in Microsoft's idiom: the agent returns **declarative
Adaptive Cards, never generated UI code**. The `@mls/spec-renderer` contract remains in
force for the apps' own dashboards.

### Showpiece #3 — self-healing (L10), rebuilt on GitHub Copilot Autofix

**Corrected 2026-08-24 after verification — this is two tracks, not one.** Copilot
Autofix covers **CodeQL code-scanning alerts only**; it does **not** act on Dependabot
alerts, which this amendment originally implied. So:

- **Code flaws** → Copilot Autofix generates the fix → PR. GA, free on all public repos,
  no Copilot subscription, on by default with CodeQL. Non-deterministic and may be
  incomplete, so the workflow must not assume a fix always arrives.
- **Dependency CVEs** (the seeded `vuln-lab` pins) → **Dependabot security updates**
  open the PR; the alert closes on merge.

Both feed the same CI gauntlet, auto-merge-on-green, deploy and alert-closure chain,
which is unchanged. The authored Claude triage script
(`.github/scripts/self-heal-triage.mjs`) is retired.

Consequence: `vuln-lab` seeds only dependency CVEs today, so Autofix would have nothing
to act on. A **CodeQL-detectable code flaw** must be seeded as well for the Autofix
track to be demoable.

Accepted trade: less control over triage narrative text than a custom prompt gave. The
PR trail remains the demo.

## 3. Consequences, including the ones that cost us

**Preserved:** the Fabric lakehouse, generators and seed data (now *more* central — the
Fabric data agent reads them); all five tool implementations and their tests; the
Container Apps environment, SQL, observability and cost exports; `@mls/spec-renderer`
for app dashboards; the golden-question eval suite, re-pointed at the deployed agent
via Direct Line.

**Discarded:** the Anthropic tool-use loop, prompt handling, and the MOCK_LLM driver in
`copilot-svc`; the Key Vault `anthropic-api-key` secret wiring and the copilot app's
secret-reference identity plumbing; the self-heal triage script.

**Lost capability — stated plainly:** Copilot Studio is cloud-only. Showpiece #1 is
today demoable on a laptop with no tenant and no credentials; after this change it
requires the tenant, a Power Platform environment, and Fabric capacity. Given the
sponsor's scaffold-before-spend posture this is a real cost: the copilot can no longer
be proven before money is spent. The MCP tool layer stays locally testable.

**New G0 items:** Power Platform environment (a developer environment is free);
Copilot Studio pay-as-you-go meter bound to the Azure subscription; Fabric data agent
enablement (preview — confirm region availability on the trial capacity); Direct Line
channel/key for the embedded surface. **Removed G0 item:** Anthropic API key.

**New open risk:** the Fabric data agent → Copilot Studio integration is in **preview**.
Preview services can change or be region-limited; L5/L8 playbooks must carry a fallback
(query the lakehouse SQL analytics endpoint through the MCP server instead, keeping the
agent but not the Fabric knowledge source).

## 4. Sources

- [Copilot ALM starter (GitHub Actions for agent solutions)](https://github.com/microsoft/copilot-alm-starter)
- [Solution management in Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/authoring-solutions-overview)
- [Fabric data agent concept](https://learn.microsoft.com/en-us/fabric/data-science/concept-data-agent)
- [Consume a Fabric data agent in Copilot Studio (preview)](https://learn.microsoft.com/en-us/fabric/data-science/data-agent-microsoft-copilot-studio)
- [Connect an agent to an existing MCP server](https://learn.microsoft.com/en-us/microsoft-copilot-studio/mcp-add-existing-server-to-agent)
- [Copilot Studio pay-as-you-go pricing](https://azure.microsoft.com/en-us/pricing/details/copilot-studio/)
