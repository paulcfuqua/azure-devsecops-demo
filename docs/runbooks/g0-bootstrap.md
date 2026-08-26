# G0 Bootstrap Runbook (human-only)

Status as verified on 2026-08-22 from this machine; **section A re-verified and completed
2026-08-26** — the local toolchain is now fully installed and every offline gate replays
green. Section C is untouched and still entirely ahead of you. Agents never execute these
steps; where a step is scriptable, agents author the script and you run it. Items marked ⚠
are **missing/unverified** and block the layer noted.

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
>
> **2026-08-26 amendment (sponsor decision — THE BINDING CONSTRAINT):** the tenant is a
> **personal Azure account**. Microsoft partner and Visual Studio subscriber credits
> **cannot be applied to it**, so the free trial's **$200 is the entire budget, and it
> expires 30 days after signup**. Everything this project does now happens inside a
> **single 30-day window**, which is shorter than the EMS E5 (90-day) and Fabric (60-day)
> trials the earlier plan was sequenced around. The Azure credit is therefore the master
> clock and every other trial has slack. The **spending limit stays ON** so the ceiling is
> enforced by Azure rather than watched by a human. See § B's "30-day master clock".

## A. Local toolchain (agents install these — no action needed from you)

| Item | Status | Notes |
|---|---|---|
| Git 2.48 / Node 24 / Python 3.14 / winget | ✅ present | |
| GitHub CLI auth (`paulcfuqua`, scopes: repo, workflow, read:org, gist) | ✅ logged in | sufficient for repo create + Actions + GHAS on own repos |
| Azure CLI | ✅ 2.89.1 | already present at `C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd`; no UAC prompt was needed after all |
| Bicep CLI | ✅ 0.46.1 | installed 2026-08-26 via `az bicep install` → `~/.azure/bin/bicep.exe` (user scope, no admin) |
| PowerShell 7 | ✅ 7.6.5 | |
| Pester | ✅ 6.1.0 | installed 2026-08-26. **The box shipped Pester 3.4.0**, which cannot run this repo's suites at all. See the Pester 6 note below |
| PSScriptAnalyzer | ✅ 1.22.0 | installed 2026-08-26 |
| Microsoft.Graph.Authentication | ✅ 2.15.0 | installed 2026-08-26. The repo only uses `Connect-MgGraph` + `Invoke-MgGraphRequest`, so the full `Microsoft.Graph` meta-module is **not** needed |
| ExchangeOnlineManagement | ✅ 3.9.2 | installed 2026-08-26; provides `Connect-IPPSSession` for L4 labels |
| SqlServer | ✅ 22.4.5.1 | installed 2026-08-26; `Invoke-Sqlcmd` with `-AccessToken` needs v22+ (`data/seed/sql/sql-seed.psm1`) |
| pytest | ✅ 9.1.1 | installed 2026-08-26 for `data/generators` (`requirements.txt` asks for `pytest>=8`) |
| Az PowerShell (`Az.*`) | — not needed | everything Azure-facing shells out to the `az` CLI; no `Az.*` cmdlet appears in the repo |
| Agent Teams env (`.claude/settings.json`) | ✅ set, session restarted 2026-08-26 | |

> **Pester 6 note (2026-08-26).** Both `lint-ci.yml` and this runbook say
> `-MinimumVersion 5.5.0`, which today resolves to **Pester 6.1.0**, a major version the
> 597 tests were never written against. That is no longer an assumption: the full CI
> invocation was replayed locally on 6.1.0 and returned **597 passed / 0 failed**, with
> PSScriptAnalyzer clean at Error/Warning/**Information**. If a future Pester release does
> break the suites, pin `-MaximumVersion` in `lint-ci.yml` rather than editing tests.
>
> Local gate replay on this machine, 2026-08-26: Pester 597/597 · PSScriptAnalyzer 0 ·
> `npm test` exit 0 (7 workspaces) · pytest 30/30. Still zero cloud writes.

## B. Trial-rate strategy (answers "can I do this at a demo/trial rate?")

Yes — the whole demo window can run on free trials:

| Need | Free path | Duration | Covers |
|---|---|---|---|
| Azure subscription | **Azure free account** ($200 credit). Partner/VS-subscriber credits are **not** available on a personal account (2026-08-26) | **30 days, then the credit is forfeited** — unspent balance does not roll over | All ARM resources. At <$5/mo idle and ~$1/hr active, $200 is comfortable *for 30 days* — it is not a standing budget. This is the master clock |
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
add-ons for privileged users); for the 5 fictional demo users, mixing saves $0 during
trials and adds admin friction — hence one E5 trial. Post-trial paid options, if you keep
the tenant warm: EMS E5 ≈ $16.40/user/mo (full fidelity, ~$82/mo for 5), EMS E3 ≈
$10.60/user/mo (lose the two E5 features, ~$53/mo), or descope to the spec-F1 degrade
path ($0).

> **Seat count — sponsor question, 2026-08-26.** "Are we paying for 5 mock users?" **No,
> and not inside the 30-day window at all.** Both trials include 25 free seats, so 5 of 25
> costs exactly what 1 of 25 costs: $0. Nor does anything in the repo assign a licence —
> `apply-entra.ps1` sets `usageLocation` (a *prerequisite* for licensing) and stops. The
> decision only arrives at EMS E5 expiry on day 90 — **60 days after the Azure credit that
> funds this project has already expired** — and it is now a one-line edit, not a rebuild:
> `infra/entra/manifest.json` carries a per-user `"licensed"` flag, and L3's V3.4 asserts
> assignment **only** for flagged users. All five are flagged while the trial lasts; flip
> the ones you no longer sign in as to `false` and the audit narrows with no code change.
> An unlicensed persona still exists and still holds its group memberships — it loses the
> sign-in-risk feed and enforceable CA, nothing else. See L03.md V3.4.
>
> **Real presenters** (colleagues signing in during a live demo) are added in the M365
> admin center **only**, never to `manifest.json` — that file is committed to a public
> repo and CLAUDE.md hard rule 4 keeps it fictional. This is safe for verification: V3.1's
> drift sweep covers `mls`-prefixed *groups and app registrations* only and never sweeps
> users, so extra real accounts do not trip it.

Recommended sequence: activate **every trial on day 0**, alongside the subscription. Under
the 30-day master clock there is no reason to stagger — M365 E5 (30 days) matches the
window exactly, and EMS E5 (90) and Fabric (60) both outlive it. Nothing is saved by
starting them late and a working day is risked by it.

### The 30-day master clock (sponsor constraint, 2026-08-26)

The Azure credit is now the shortest clock in the system, so it governs everything else:

| Clock | Length | Slack against the 30-day window |
|---|---|---|
| **Azure $200 credit** | **30 days** | **none — this is the constraint** |
| M365 E5 trial | 30 days | none, but it only has to outlive label *creation*; the labels persist |
| Fabric trial capacity | 60 days | 30 days spare |
| EMS E5 trial | 90 days | 60 days spare |
| Copilot Studio PAYG meter | indefinite | n/a — a meter, not a trial |

**Keep the spending limit ON.** Azure free accounts enable it by default; when the credit
is exhausted or expires, Azure **disables resources rather than charging the card**. That
makes $200 a ceiling enforced by the platform instead of a number a human has to watch.
The $75 budget in item C8 is early warning layered on top of it, not the stop.

**What day 30 costs you: nothing that matters.** The estate going dark is the designed
steady state — `down.ps1` does it deliberately every cycle. What survives is everything
expensive to rebuild: Entra users/groups/CA policies, Purview labels *and their GUIDs*,
the Power Platform environment and the Copilot Studio agent, and the whole GitHub repo.
What dies is the four resource groups, and those replay from this repo in one `up.ps1`.

**Indicative schedule** — adjust freely; the point is that the demo lands with buffer, not
that these dates are sacred:

| Days | Work | Watch out for |
|---|---|---|
| 0 | Subscription + all trials + § C items 1–5, 8, 9; `verify-g0.ps1` green | The clock starts the moment you click Start |
| 1–7 | L1–L4 (landing zone, Entra, governance, labels) + item C10 licence assignment | Entra/CA propagation runs 15–45 min; label creation needs M365 E5 live |
| 7–14 | L5–L8 (Fabric, platform, apps, Copilot Studio) | The one unavoidable manual step — authoring the agent in the portal — sits here |
| 14–21 | L9–L10 (DevSecOps chain, self-heal showpiece) | **L10's healing trail has a 24-hour deadline** (V10.1/V10.2); it needs a real day, not an hour |
| 21–27 | Rehearsal and demo | **Direct Line secured access can take 2 hours to propagate** (item C7) — never toggle it against a demo start |
| 27–30 | Buffer, then `down.ps1` | Tear down before the credit lapses rather than letting the spending limit do it for you |

**Burn discipline: run `down.ps1` between working sessions.** Torn down is <$5/month;
leaving the estate up for all 30 days at ~$1/hr is roughly $700, and the spending limit
would cut you off long before demo day. Here the teardown path is not housekeeping — it is
what makes the budget arithmetic work at all.

**If the demo slips past day 30**, the Azure credit is gone while EMS E5 and Fabric are
still live, so the tempting move is to carry on under pay-as-you-go. That is real money on
a personal card. Either re-scope to land inside the window, or make the PAYG call
deliberately as a G2 with a number attached — not by drifting into it.

> ⚠ **Verify early, not at demo prep.** Item C5 attaches a Power Platform **pay-as-you-go
> billing plan** to this subscription. Whether that is permitted on a free-trial
> subscription with the spending limit on is **unconfirmed** — PAYG plans generally expect
> a billable subscription, and no Microsoft doc found so far addresses this combination.
> Test it on day 0 by creating the environment and attempting to attach the plan. If it is
> refused, showpiece #1 falls back to the tools-only MCP path already documented above, and
> you will want to know that in week one rather than week four.

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

1. ⚠ **Azure tenant + subscription with billing.** In the portal's "Welcome to Azure!"
   screen, take **Start with an Azure free trial** — not *Azure for Students* (needs
   academic verification) and not *Manage Microsoft Entra ID* (a directory view, no
   subscription). A card is required for identity verification. **Leave the spending
   limit ON** (§ B): it is what makes the $200 a hard ceiling rather than a hope.
   Confirm Global Administrator on the tenant. After toolchain install, run `az login`
   when prompted by the bootstrap script.

   **Clicking Start begins the 30-day clock.** Do not click it until you are ready to
   work — the credit expires on the calendar, not on usage, so a week of hesitation is a
   week of budget gone. Record the signup date; every date in § B's schedule counts from it.
2. ⚠ **Activate all trials on day 0**, per section B: M365 E5 + EMS E5 (M365 admin center
   → Billing → Purchase services → free trials), assign to your admin user; Fabric trial
   from fabric.microsoft.com. Same day as item 1 — under the 30-day master clock every
   trial either matches the window or outlives it, so staggering buys nothing.
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
9. ⚠ **Populate the `demo` GitHub environment** with the variables (and the two
   certificate secrets) in the tables below. `scripts/up.ps1` refuses to dispatch a
   rebuild until the first four exist, precisely because the pre-G0 guard would
   otherwise skip every layer and report success.
10. ⚠ **Assign EMS E5 to the demo users** — *added 2026-08-26; this step was missing and
    L3 failed its own audit without it.* Runs **after** L3 has created the users, not
    before. Nothing in the repo assigns licences: `apply-entra.ps1` sets `usageLocation`
    only, which is the prerequisite Entra requires before any assignment will stick. But
    L3's **V3.4 hard-fails** unless every user flagged `"licensed": true` in
    `infra/entra/manifest.json` shows the `EMSPREMIUM` SKU with `State == Active`.

    In the M365 admin center → **Users → Active users**, select the flagged users and
    assign the **EMS E5** licence. Per-user assignment is fine — despite L03.md's older
    wording, no licensing group is required and none exists in the manifest. Assignment is
    asynchronous; V3.4 allows the full 30-minute retry window.

    All five ship flagged `true`, which costs nothing against the trial's 25 free seats.
    At trial expiry, flip the users you no longer sign in as to `"licensed": false` and
    V3.4 narrows to match — see the seat-count note in § B. `CountViolation` in the audit
    output means the seat pool is exhausted, not that the step failed.

11. ⚠ **Create the MCP inbound auth secret** — *added 2026-08-26; closes the one finding
    from the pre-publication security review.* Runs **after** L6 creates the Key Vault and
    **before** L7 deploys the apps.

    `apps/mcp-tools` runs with **external ingress by design** — Copilot Studio calls it
    from the public internet, so internal-only is not an option. Without a token its five
    tools (lakehouse SQL, Log Analytics, Defender secure score, Cost Management, GitHub
    security) are callable by anyone who finds the FQDN. The SQL tool is already gated
    read-only, so this is not a write path — but it is unauthenticated read access to your
    tenant's cost and security posture, **and a denial-of-wallet vector**: every call
    resumes serverless SQL and consumes Fabric CU against a 30-day $200 credit.

    Generate a token and store it in the L6 vault:

    ```
    az keyvault secret set --vault-name <kv> --name mcp-auth-token       --value "$(openssl rand -base64 32)"
    ```

    The layer-07 workflow reads it with its OIDC identity and passes it as the
    `mcpAuthToken` deploy parameter, which lands as a **container-app secret** — never a
    plain env value, never a GitHub secret, never in CI storage (hard rule 5). Give the
    same value to the Copilot Studio custom connector as its API key; the server accepts
    either `Authorization: Bearer <token>` or `x-api-key: <token>`.

    Verify: `GET /healthz` on the app reports `auth.enforced: true`, and `POST /mcp`
    without a credential returns **401**. If `auth.enforced` is `false`, the endpoint is
    open — the server also says so loudly in its boot log.

    **If you deliberately want an open endpoint** (throwaway environment only), set
    `MCP_ALLOW_UNAUTHENTICATED=true`. Cloud mode otherwise refuses to boot without a
    token, by design: an open endpoint has to be chosen, never defaulted into.

### C9 — the `demo` GitHub environment, variable by variable

These are GitHub **environment variables**, not secrets, and they are never committed
(spec F5 / CLAUDE.md hard rule 5). Create the environment once and set each value:

```
gh api -X PUT repos/paulcfuqua/azure-devsecops-demo/environments/demo
gh variable set <NAME> --env demo --body <value>
```

**Required before anything deploys** — `demo-env-guard` gates every Azure-facing job on
these, and `scripts/up.ps1` refuses to dispatch without them:

| Variable | Value | Read by |
|---|---|---|
| `AZURE_TENANT_ID` | tenant GUID | every `azure/login`; L1 V1.3's committed-identifier sweep |
| `AZURE_SUBSCRIPTION_ID` | subscription GUID | every layer; V2.1, V2.3, V6.x, V9.5, V11.1, V11.5 |
| `AZURE_CLIENT_ID` | `mls-github-deployer` app ID (item C3) | the deployer half of every workflow |
| `FABRIC_CAPACITY_ID` | trial capacity ID, or the paid F2's ARM resource ID (item C4) | L5, L8's data agent, V5.1, V5.4, V11.5 |
| `MLS_GITHUB_REPO` | `<owner>/<repo>` — **your** fork, e.g. `paulcfuqua/azure-devsecops-demo` | Both bootstrap scripts, every Verifier repo read (V1.x, V7.4, V9.x, V10.x, V11.4), and `data-api`'s Dev/Sec feeds via `demo.bicepparam`. **Deliberately has no built-in default** — see below |
| `MLS_OWNER` | value of the policy-enforced `owner` tag, e.g. your GitHub handle | Both `demo.bicepparam` files and `02-fabric-capacity.ps1`. Falls back to the neutral `mls-demo` rather than any personal handle |

> **Why `MLS_GITHUB_REPO` has no default (2026-08-26).** This is a public reference repo,
> and two of its values decide who is trusted rather than merely what is named:
>
> - `01-root-oidc.ps1` writes **federated identity credentials**, which determine *which
>   repository may authenticate as your deployer identity and deploy into your
>   subscription*. A default here would mean anyone who clones this repo and runs the
>   script without reading it silently federates their Azure identity to a repository they
>   do not control. The script therefore refuses to guess and exits with instructions.
> - `verify-g0.ps1` would otherwise audit the upstream repo's federation state and report a
>   confident, meaningless PASS about someone else's configuration.
>
> The Verifier audits resolve it the usual way — explicit parameter, then
> `MLS_GITHUB_REPO` / `MLS_REPOSITORY`, then a clear failure. The `owner` tag was a
> quieter version of the same problem: it is policy-enforced on every resource group, so a
> hardcoded handle stamped the original author's identity across every downstream
> deployment. Both now default to nothing personal.

**Required for the Verifier** — without these the layer workflows skip their audits with a
NOTICE rather than running them as the wrong identity. A skipped audit is not a passed
one, so an estate configured this far is deployed but unverified:

| Variable | Value | Read by |
|---|---|---|
| `AZURE_VERIFIER_CLIENT_ID` | `mls-verifier` app ID (item C3) | every `verify` job's `azure/login` |
| `MLS_TENANT_DOMAIN` | the tenant's **verified domain**, e.g. `contoso.onmicrosoft.com` | L3 `-Domain` (UPNs are `<prefix>@<domain>`; the committed manifest ships the placeholder `mls.example`), L4 `-Organization`, and both again inside V11.2. `ENTRA_DOMAIN` / `PURVIEW_ORGANIZATION` are accepted as the older spellings |
| `MLS_VERIFIER_APP_ID` | `mls-verifier` app ID again, for the Security & Compliance app-only session | L4 V4.1/V4.2. Defaults to `AZURE_VERIFIER_CLIENT_ID` when unset |

**Layer inputs discovered during the build** — set these once the layer that produces them
has run. Each one is an audit input that cannot be derived from ARM:

| Variable | Value | Read by | Produced at |
|---|---|---|---|
| `MLS_SQL_ENDPOINT` | lakehouse SQL analytics endpoint FQDN (the L5 lakehouse metadata's `sqlEndpointProperties.connectionString`) | V5.3's row counts, V8.2's independent re-derivation, and `data-api`'s cloud mode — with it unset the L7 template provisions `data-api` in LOCAL mode and every `/api/tables` route answers 503 | L5 |
| `MLS_LAKEHOUSE_NAME` | lakehouse name; defaults to `mls_operations` | V5.2, V5.3, V8.2 | L5 |
| `MLS_POWER_PLATFORM_ENV_URL` | Power Platform environment URL (item C5) | L8 V8.1's Dataverse solution comparison. `POWERPLATFORM_ENVIRONMENT_URL` is accepted as the older spelling and is what the L8 deploy guard already reads | G0 |
| `MLS_MCP_SERVER_URL` | full MCP Streamable HTTP URL | V8.3's `tools/list` half. **Optional** — the L8 verify job derives it from the container app's ingress FQDN, so set it only when the server is reached some other way | L7 |
| `MLS_L7_CANARY_PR` | canary PR number | V7.4. The L7 lead opens the PR — the Verifier never writes to the repo — and `layer-07-apps.yml` also accepts it as a `canary_pr` dispatch input | L7 |
| `MLS_L10_RESEED_MERGED_AT` | UTC time the `apps/vuln-lab/reseed.ps1` PR **merged**, e.g. `2026-08-24T14:05:00Z` | V10.1/V10.2's 24-hour chain deadline. Without it an incomplete healing trail is recorded FAIL instead of PENDING, because there is no deadline to compare against. `reseed.ps1` cannot set it: the clock starts at merge, after the script has finished | each demo cycle |
| `MLS_L10_DEPENDABOT_ALERTS` | the three seeded Dependabot alert numbers, comma- or space-separated | V10.2. `self-heal.yml` appends the alert its own run picked, so a fresh alert is covered before anyone updates this | L10 |
| `MLS_L9_RUN_ID` | `layer-09-devsecops.yml` run ID | V9.2's Trivy negative test | **no longer hand-set** — see below |
| `MLS_L9_RELEASE_TAG` | release tag carrying the SBOMs | V9.3 | **no longer hand-set** |
| `MLS_L9_ZAP_RUN_ID` | run ID whose artifact holds the ZAP baseline report | V9.4 | **no longer hand-set** |

> **The three `MLS_L9_*` values are now produced by the layer run.**
> `.github/workflows/layer-09-devsecops.yml` exists (2026-08-24) and passes all three to
> the audit as explicit arguments: `-LayerRunId` and `-ZapRunId` are its own
> `github.run_id`, and `-ReleaseTag` is the tag its `release` job created. `zap.yml` and
> `sbom.yml` are **called** with `uses:` rather than dispatched, so a reusable workflow's
> jobs and artifacts belong to the caller's run — which is what makes one run id serve
> both V9.2 and V9.4. Leave all three variables unset on the happy path; they survive only
> as an override for re-verifying an older run by hand.

**Optional tuning** (each has a working default, so leave them unset until you need them):

| Variable | Default | Effect |
|---|---|---|
| `SQL_AAD_ADMIN_LOGIN` / `SQL_AAD_ADMIN_OBJECT_ID` | none | Entra admin for the L6 SQL server. Without them the server deploys with no Entra administrator |
| `KEY_VAULT_CREATE_MODE` | `default` | Set to `recover` when replaying against a soft-deleted vault (kill/rebuild) |
| `LAUNCH_OPS_PORT`, `CONTROL_TOWER_PORT`, `MCP_TOOLS_PORT`, `DATA_API_PORT` | `80` | Container ingress target ports. The real images listen on **8080**; this is open item P-1 and flipping all four closes it |
| `DATA_API_APP_NAME` | `<prefix>-data-api-<env>-ca` | Overrides the derived container app name in `app-data-api-ci.yml` |
| `MCP_ENDPOINT_PATH` | `/mcp` | Path the MCP server serves Streamable HTTP on |

### C9b — the `demo` environment's secrets, and why each one exists

CI still holds **no LLM key and no cloud credential**: everything Azure authenticates by
OIDC / workload identity federation, and the system's one runtime secret — the Direct Line
secret — lives in Key Vault and is read from there at run time, never stored here
(2026-08-24 amendment § 2). The secrets below exist for exactly one reason: **Security &
Compliance PowerShell has no federated path**, so certificate app-only auth is the only
way to touch Purview labels unattended.

| Secret | Needed by | If absent |
|---|---|---|
| `PURVIEW_CERT_BASE64` (+ `PURVIEW_CERT_PASSWORD`) | the L4 **deploy** job's `Connect-IPPSSession` | `labels.ps1` stays a human-run step under your login — the L04 playbook's documented degrade path. Nothing fails |
| `MLS_VERIFIER_CERT_BASE64` (+ `MLS_VERIFIER_CERT_PASSWORD`) | the L4 **audit**'s own read-only S&C session as `mls-verifier`, and the L3/L4 child audits V11.2 re-runs after a teardown | L4 verification skips with a NOTICE, and V11.2 records SKIP via `-SkipChildAudit`. Neither is a pass — the labels are simply unverified |
| `MLS_VERIFIER_GH_TOKEN` | the Verifier's GitHub reads (V1.x, V7.4, V9.1–V9.4, V10.1, V10.2) | the audits fall back to the run-scoped `GITHUB_TOKEN`, which GitHub mints per run and stores nowhere. That covers everything **except Dependabot alerts**, which that token is refused on — so V10.2 reports an unreadable trail rather than a passing one. A fine-grained PAT with `security_events: read` closes it |
| `SELF_HEAL_TOKEN` | `self-heal.yml`'s PR authoring | PRs are authored by `GITHUB_TOKEN`, whose `pull_request` runs start approval-required, so auto-merge cannot fire unattended. Parked sponsor decision |

Both certificates are the same shape: export the app's certificate as a PFX and store it
base64-encoded. Set the password secret only if the PFX has one.

```
gh secret set MLS_VERIFIER_CERT_BASE64 --env demo < <(base64 -w0 mls-verifier.pfx)
```

## D. What "G0 complete" means

The Orchestrator re-runs `scripts/bootstrap/verify-g0.ps1` (read-only) and gets: a
logged-in CLI context; `mls-github-deployer` with federation + Owner + consented Graph
permissions; `mls-verifier` present; Fabric capacity visible with SP API access on;
trial licenses assigned; a production-or-sandbox Power Platform environment linked to a
Copilot Studio pay-as-you-go billing plan on this subscription; budget in place. Only
then does Layer 1 deploy.

Items C6, C7 and C10 are **not** G0-complete blockers for Layer 1 — C7 cannot even be done
until L8 has published an agent, C6 is deferred by design while the Fabric capacity
is on the trial SKU, and C10 cannot run until L3 has created the users it licenses. C6/C7
block L8 only and C10 blocks L3's V3.4 only; `verify-g0.ps1` reports them as
informational rather than failing the gate.

Note that `verify-g0.ps1` check 8 ("licences: M365 E5 and EMS E5 present with at least one
unit consumed") is a **tenant-level** check — it confirms the trials are activated, not
that any demo user holds a seat. Per-user assignment is C10's job and V3.4's assertion.
