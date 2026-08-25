# G0 Bootstrap Runbook (human-only)

Status as verified on 2026-08-22 from this machine. Agents never execute these steps;
where a step is scriptable, agents author the script and you run it. Items marked ⚠ are
**missing/unverified** and block the layer noted.

> **2026-08-22 amendment (sponsor decision):** tenant activation is deliberately
> deferred. Phase P (pre-tenant scaffold, see
> `docs/superpowers/plans/2026-08-22-phase-p-pre-tenant-scaffold.md`) proceeds now;
> this runbook executes when you are ready to switch the tenant on. The trial-rate
> strategy below is designed so the entire demo window can run at ~$0 licensing cost.
>
> **2026-08-24 amendment (sponsor decision, `specs/2026-08-24-amendment-copilot-studio.md`):**
> the **Anthropic API key item is gone** — there is no LLM key anywhere in the system.
> In its place, four Microsoft-side items: a Power Platform environment, the Copilot
> Studio pay-as-you-go meter bound to this Azure subscription, the Fabric data agent's
> tenant enablement, and the Direct Line channel for the embedded surface. See § B for
> what this does — and does not — cost, and § C items 5–7.

## A. Local toolchain (agents install these — no action needed from you)

| Item | Status | Notes |
|---|---|---|
| Git 2.48 / Node 24 / Python 3.14 / winget | ✅ present | |
| GitHub CLI auth (`paulcfuqua`, scopes: repo, workflow, read:org, gist) | ✅ logged in | sufficient for repo create + Actions + GHAS on own repos |
| Azure CLI + Bicep | ⚠ not installed | agents install via winget (Bicep user-scope; az CLI may prompt UAC — approve it once) |
| PowerShell 7, Graph + ExchangeOnlineManagement modules, Pester | ⚠ not installed | agents install (CurrentUser scope, no admin needed for modules) |
| Agent Teams env (`.claude/settings.json`) | ✅ set | **restart the Claude Code session to activate teammates** |

## B. Trial-rate strategy (answers "can I do this at a demo/trial rate?")

Yes — the whole demo window can run on free trials:

| Need | Free path | Duration | Covers |
|---|---|---|---|
| Azure subscription | **Azure free account** ($200 credit) — or Visual Studio subscriber monthly credit if you have one | 30 days credit, then PAYG on the same sub | All ARM resources. At <$5/mo idle and ~$1/hr active, $200 outlasts the credit window comfortably |
| Identity licensing | **EMS E5 trial** | 90 days, 25 seats | Entra P1+P2 (CA, sign-in risk), AIP P2 |
| Purview/compliance portal | **Microsoft 365 E5 trial** | 30 days, 25 seats | Exchange-backed tenant → Security & Compliance PowerShell + label management work reliably; also includes Entra P2 + AIP P2 |
| Fabric capacity | **Fabric 60-day free trial capacity** (enable "Users can try Microsoft Fabric" tenant setting, start trial as your admin user) | 60 days | F4 or F64 CU, 1 TB OneLake. Replaces paying for F2 during bring-up. Capacity ID is a config variable — moving to paid F2 later is one variable + G2. **Does not cover the L8 Fabric data agent** — see the caveat below |
| Copilot Studio (showpiece #1) | **Pay-as-you-go meter** on this Azure subscription + the *Copilot Studio authors* role for the maker — no licence purchase | indefinite | Authoring and running the agent. $0.01/credit, nothing when idle. See "Copilot Studio licensing" below |
| Everything GitHub | Public repo | indefinite | Actions minutes, CodeQL, Dependabot, secret scanning, **and Copilot Autofix (showpiece #3)** all free — [Autofix is GA and free on all public repositories](https://github.blog/changelog/2024-09-17-now-available-for-free-on-all-public-repositories-copilot-autofix-for-codeql-code-scanning-alerts/) and needs no Copilot subscription |

> ⚠ **Trial-capacity caveat, new on 2026-08-24.** The Fabric trial capacity does **not**
> support Fabric data agents:
> ["AI Experiences such as Data agent, AI functions and AI services aren't supported"](https://learn.microsoft.com/en-us/fabric/fundamentals/fabric-trial),
> and the data agent's own prerequisite is
> [a paid F2 or higher capacity (or Power BI Premium P1+)](https://learn.microsoft.com/en-us/fabric/data-science/concept-data-agent).
> So the trial covers L5 completely, but **not** L8's Fabric knowledge source. You have
> two honest options and the demo works either way: (a) file the G2 to move to paid F2
> before the L8 demo — ~$0.36/hr only while resumed, still paused the rest of the time;
> or (b) run L8 in its documented tools-only fallback, where lakehouse questions go
> through the MCP server's `query_lakehouse_sql` tool instead. Option (b) costs $0 and
> answers the same golden questions; what it gives up is Fabric's native NL2SQL as the
> story on stage.

If you have Microsoft partner access, a CDX (Microsoft Customer Digital Experiences)
demo tenant is the true "demo rate" — a pre-licensed M365 E5 tenant for 90 days.
Otherwise the two trials above reproduce it.

### E3 vs E5 — what actually needs what (sponsor question, 2026-08-22)

| Demo feature | Minimum license | In E3 (EMS/M365) | Only in E5 |
|---|---|---|---|
| Users, groups, app registrations, MFA | Entra free tier | ✅ | |
| Conditional Access policies (L3) | Entra ID **P1** | ✅ | |
| Sensitivity labels — create/manage via PowerShell (L4) | AIP **P1** | ✅ | |
| Sign-in risk / Identity Protection (control-tower Sec tab) | Entra ID **P2** | ❌ | ✅ |
| Risk-based CA conditions | Entra ID **P2** | ❌ | ✅ |
| Auto-labeling (optional, documented) | AIP **P2** | ❌ | ✅ |

So E3 covers ~80% of the identity story. **E5 buys exactly two things this demo uses:
the sign-in-risk feed and auto-labeling.** In production you'd mix (E3 workforce + P2
add-ons for privileged users); for 6 fictional demo users, mixing saves $0 during trials
and adds admin friction — hence one E5 trial. Post-trial paid options, if you keep the
tenant warm: EMS E5 ≈ $16.40/user/mo (full fidelity, ~$100/mo for 6), EMS E3 ≈
$10.60/user/mo (lose the two E5 features, ~$65/mo), or descope to the spec-F1 degrade
path ($0). Recommended sequence: activate **both trials the same day you switch the
tenant on** — M365 E5 gives everything for the first 30 days (and the compliance portal
needed to *create* labels, which persist afterward); EMS E5 keeps CA + sign-in risk
licensed through day 90.

### Copilot Studio licensing — researched 2026-08-24, answering "is the free maker licence plus the PAYG meter enough?"

**Short answer: not quite, and the fix is free.** There are four documented ways to get
into Copilot Studio, and the one that sounds cheapest has a hidden purchase in it
([access options](https://learn.microsoft.com/en-us/microsoft-copilot-studio/billing-licensing)):

| Path | Cost | Verdict for this demo |
|---|---|---|
| **Copilot Studio user licence** — "free of charge", assigned in the M365 admin center | $0 for the licence, **but** the same doc says "You need a Copilot Studio tenant **prepaid Copilot Credit pack** subscription before you can get this user licence" — that's $200/pack/month for 25,000 credits | ❌ The "free maker licence" is gated behind a real purchase. Not the path |
| **Copilot Studio authors role** — a security group assigned to that setting in the Power Platform admin center | $0, no purchase | ✅ **This is the path.** Licence-free authoring rights |
| **Microsoft 365 Copilot licence** | Paid add-on | Not needed. Note the Fabric→Copilot Studio doc lists an M365 Copilot licence among its prerequisites; that governs zero-rated M365-surface usage, and it is not required to author an agent that is consumed over Direct Line and billed on the meter [derived — no doc states this combination outright, so treat it as the first thing to re-verify at G0 item C5] |
| **Copilot Studio trial licence** — individual self-signup, extendable +30 days, agent keeps working up to 90 days after expiry | $0 | ❌ Deal-breaker for *this* demo: [the trial "gives you access to Copilot Studio to create agents… However, you can't publish the agent"](https://learn.microsoft.com/en-us/microsoft-copilot-studio/requirements-licensing-subscriptions). No publish means no Direct Line channel and no Ask tab. Fine for a sandbox, not for showpiece #1 |

So the working combination is **the *Copilot Studio authors* role for authoring + the
pay-as-you-go meter for runtime** — $0 fixed, $0.01 per Copilot Credit consumed
([rate and mechanics](https://learn.microsoft.com/en-us/microsoft-copilot-studio/billing-licensing);
[Power Platform PAYG](https://learn.microsoft.com/en-us/power-platform/admin/pay-as-you-go-overview)).
Billing flows through a Power Platform billing plan attached to this Azure subscription,
so Copilot Studio spend lands on the same bill, under the same $75 budget, drawing on the
same $200 credit. Nothing accrues while the agent is idle. Published rates: classic
answer 1 credit, generative answer 2, agent action 5, tenant graph grounding 10
([rate table](https://learn.microsoft.com/en-us/microsoft-copilot-studio/requirements-messages-management))
— so a tool-backed question is ≈ 7 credits ≈ $0.07 [derived], and the 10-question eval
suite ≈ $0.70 per run.

**One trap worth knowing before you click.** The amendment says "a developer environment
is free", and it is —
[the Power Apps Developer Plan](https://learn.microsoft.com/en-us/power-platform/developer/plan)
gives any work/school account a free developer environment (2 GB Dataverse, 750 flow
runs/month, up to three environments, auto-disabled after 30 days of inactivity). But
**pay-as-you-go cannot be attached to it**:
["Pay-as-you-go is available for **production** and **sandbox** environments"](https://learn.microsoft.com/en-us/power-platform/admin/pay-as-you-go-set-up).
A developer environment is therefore fine for experimenting, and wrong for the demo's
published agent. Create a **production or sandbox** environment for L8 and link that one
to the billing plan. If you also want a free scratch environment to poke at Copilot
Studio before committing, the Developer Plan is exactly right for that — just don't
publish the demo agent there. Creating a production/sandbox environment consumes tenant
Dataverse capacity, so confirm you have some available (Power Platform admin center →
Resources → Capacity) as part of item C5.

**How this interacts with the E3/E5 table above:** it doesn't, and that is the useful
finding. Copilot Studio authoring rights come from a Power Platform admin-center role,
not from an M365 or EMS SKU, and runtime comes from an Azure meter. Neither E3 nor E5
changes what showpiece #1 costs. The E3-vs-E5 decision above stays exactly as written —
it is still about sign-in risk and auto-labeling, nothing else.

## C. Human-only checklist (when you're ready to switch the tenant on)

1. ⚠ **Azure tenant + subscription with billing** (free-account credit qualifies).
   Confirm Global Administrator on the tenant. After toolchain install, run `az login`
   when prompted by the bootstrap script.
2. ⚠ **Activate trials** per section B: M365 E5 + EMS E5 (M365 admin center → Billing →
   Purchase services → free trials), assign to your admin user; Fabric trial from
   fabric.microsoft.com.
3. ⚠ **Run `scripts/bootstrap/01-root-oidc.ps1`** (agent-authored in Phase P). Under
   your login it: creates app registration `mls-github-deployer` with federated
   credentials for this repo; grants Owner on the subscription; prints the
   admin-consent URL for Graph application permissions (`User.ReadWrite.All`,
   `Group.ReadWrite.All`, `Application.ReadWrite.All`,
   `Policy.ReadWrite.ConditionalAccess`, `Directory.Read.All`) — you click consent;
   and creates the read-only `mls-verifier` app (Reader + `Directory.Read.All`).
4. ⚠ **Fabric SP API toggle:** in the Fabric admin portal enable **"Service principals
   can use Fabric APIs"** and add `mls-github-deployer` as admin on the trial capacity
   (~2 min, portal-only).
5. ⚠ **Power Platform environment + Copilot Studio pay-as-you-go meter** (blocks L8).
   Three sub-steps, all portal, ~15 minutes total:
   1. In the [Power Platform admin center](https://admin.powerplatform.microsoft.com/),
      create an environment of type **Production** or **Sandbox** with a Dataverse
      database. Not a Developer-Plan environment — those cannot carry the meter (§ B).
      Check **Resources → Capacity** first for available Dataverse capacity.
   2. **Licensing → Pay-as-you-go plans → New billing plan**: pick this Azure
      subscription and a resource group, select **Copilot Studio** under Power Platform
      products, and add the environment you just created. This creates a hidden *Power
      Platform account* resource in that resource group — tag it like anything else. You
      need Owner/Contributor on the subscription and Power Platform (or Global) admin, or
      Environment admin on that environment, to do this.
   3. Grant yourself authoring rights the free way: create an Entra security group, add
      yourself, and assign it to the **Copilot Studio authors** setting in the Power
      Platform admin center tenant settings. Do *not* buy a Copilot Credit pack; the
      meter is the payment path.

   Verify: the environment is listed under the billing plan, and
   [copilotstudio.microsoft.com](https://copilotstudio.microsoft.com) opens with that
   environment selectable.
6. ⚠ **Fabric data agent enablement** (blocks L8's knowledge source only — L8 has a
   documented fallback, see § B and `docs/runbooks/layers/L08.md`). In the Fabric admin
   portal, enable the **cross-geo processing for AI** and **cross-geo storing for AI**
   tenant settings, which the data agent requires. Then confirm your capacity is a
   **paid F2 or higher**: the trial capacity cannot run data agents, so on the trial this
   item is *knowingly deferred* and L8 runs tools-only until the G2 to paid F2. Note the
   compliance point Microsoft states plainly: with this integration, "responses returned
   by Fabric data agents may be sent outside of Fabric's compliance boundary or geographic
   region" — fine for synthetic launch data, worth saying out loud on stage.
7. ⚠ **Direct Line channel for the embedded surface** (blocks L8's Ask tab). After the
   L8 pipeline first publishes the agent, in Copilot Studio open **Settings → Security →
   Web channel security**, turn **Require secured access** on, and copy one of the two
   Direct Line secrets. Store it in the L6 Key Vault as `directline-secret`:

   ```
   az keyvault secret set --vault-name <kv> --name directline-secret --value <secret>
   ```

   `apps/directline-token` reads it through a Key Vault reference and exchanges it for
   short-lived, origin-pinned chat tokens; the browser never receives the secret. Two
   practical notes: Copilot Studio keeps **two live secrets** so you can rotate without
   downtime, and toggling secured access **can take up to two hours to propagate** — do
   not schedule this against a demo start time. This is the system's only stored runtime
   secret and it never goes near CI or the repo: GitHub Actions still authenticates by
   federation with no stored secret at all.
8. ⚠ **Budget guard:** run `scripts/bootstrap/03-budget.ps1` — $75/month budget with
   alerts at 50/80/100% to your email. Backstop behind gate G4's cost-anomaly trigger.
   Copilot Studio's meter bills to this same subscription, so it sits inside this budget.

## D. What "G0 complete" means

The Orchestrator re-runs `scripts/bootstrap/verify-g0.ps1` (read-only) and gets: a
logged-in CLI context; `mls-github-deployer` with federation + Owner + consented Graph
permissions; `mls-verifier` present; Fabric capacity visible with SP API access on;
trial licenses assigned; a production-or-sandbox Power Platform environment linked to a
Copilot Studio pay-as-you-go billing plan on this subscription; budget in place. Only
then does Layer 1 deploy.

Items C6 and C7 are **not** G0-complete blockers for Layer 1 — C7 cannot even be done
until L8 has published an agent, and C6 is deferred by design while the Fabric capacity
is on the trial SKU. Both block L8 only, and `verify-g0.ps1` reports them as
informational rather than failing the gate.
