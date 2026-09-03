# G0 Bootstrap Runbook

Status as verified on 2026-08-22 from this machine; **section A re-verified and completed
2026-08-26** — the local toolchain is now fully installed and every offline gate replays
green. Items marked ⚠ are **missing/unverified** and block the layer noted. Items marked ○
are **optional** — nothing in the deploy path needs them, and they are kept because someone
may still want the capability they describe.

> **2026-08-29 sponsor amendment — this runbook is no longer human-only.** It used to say
> "Agents never execute these steps; where a step is scriptable, agents author the script
> and you run it," and the title said *(human-only)*. **Agent-created and agent-managed
> infrastructure is now the demo itself**, so agents may run the scripts here under an
> interactive `az login` session. Two gates are deliberately unchanged, because an agent
> that can spend your money or delete what it cannot recreate is not a thing anyone wants
> to buy: **G2** on every spend increase (including `02-fabric-capacity.ps1 -Mode F2` and
> each resume of a paid capacity) and **G3** on tenant-level deletion. See CLAUDE.md
> rule 1.
>
> **The portal steps are still yours.** C1, C2, C4, C5, C7 and the licence assignments
> happen in Microsoft's web UIs, which no script here drives. What changed is who runs
> `01-root-oidc.ps1`, `02-fabric-capacity.ps1` and `03-budget.ps1` — not the existence of
> the portal work.

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

> **Prerequisite that overrides everything below: use a DEDICATED, EMPTY Azure
> subscription.** L2 assigns **subscription-wide DENY policy** — six `require-<tag>` deny
> rules on resource groups and an `allowed-locations` deny on every resource — and those
> apply to everything already in the subscription, not only to what this demo creates.
> The next deployment anyone makes into it without the six required tags, or into a
> location outside the allowlist, is **refused**. L2 also assigns a NIST SP 800-53 R5
> initiative and a budget at subscription scope; L7 grants `data-api`'s identity
> **Security Reader across the whole subscription**; L9 touches a subscription-scoped
> Defender pricing plan (it refuses to run if you already have Defender for Containers
> on — F31); and `infra-down.yml` deletes four resource groups by name. A fresh
> pay-as-you-go subscription with nothing else in it is the supported configuration and
> the one the $200/30-day budget below assumes.

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
| SqlServer | ⚠ 22.4.5.1 | installed 2026-08-26; `Invoke-Sqlcmd` with `-AccessToken` needs v22+ (`data/seed/sql/sql-seed.psm1`). **Needs a manual fix on this ARM64 box — see the note below** |
| Power Platform CLI (`pac`) | ✅ 2.11.2 | installed 2026-08-31 via `dotnet tool install --global Microsoft.PowerApps.CLI.Tool`; lands in `~\.dotnet\tools`. Required by `infra/copilot-studio/{export,import}-agent.ps1` and by `pac copilot clone/push` |
| pytest | ✅ 9.1.1 | installed 2026-08-26 for `data/generators` (`requirements.txt` asks for `pytest>=8`) |
| Az PowerShell (`Az.*`) | — not needed | everything Azure-facing shells out to the `az` CLI; no `Az.*` cmdlet appears in the repo |
| Agent Teams env (`.claude/settings.json`) | ✅ set, session restarted 2026-08-26 | |

> **Pester 6 note (2026-08-26).** Both `lint-ci.yml` and this runbook say
> `-MinimumVersion 5.5.0`, which today resolves to **Pester 6.1.0**, a major version the
> suites were never written against. That is no longer an assumption: the full CI
> invocation was replayed locally on 6.1.0 and returned **1,352 passed / 0 failed**, with
> PSScriptAnalyzer clean at Error/Warning/**Information**. If a future Pester release does
> break the suites, pin `-MaximumVersion` in `lint-ci.yml` rather than editing tests.

> **⚠ ARM64 note (2026-08-31): every lakehouse query fails locally until you fix the
> SqlServer module by hand.** This machine is **Windows on ARM** — `pwsh` is
> `…Microsoft.PowerShell_7.6.5.0_arm64…`, `ProcessArchitecture: Arm64`. SqlServer 22.4.5.1
> ships its native SNI library only for x64 and x86, and under a mangled name:
> `coreclr/runtimes/win/lib/net6.0/win-x64/Microsoft.Data.SqlClient.SNI.dll` **.dll** —
> a double extension, and no `win-arm64` runtime folder at all. There *is* a correctly
> built `Microsoft.Data.SqlClient.SNI.arm64.dll` at the module root; nothing looks for it.
>
> The result is that `Invoke-Sqlcmd -AccessToken` throws
> `DllNotFoundException: Unable to load DLL 'Microsoft.Data.SqlClient.SNI.dll'`, which
> means **`Invoke-MlsSqlQuery` cannot run — so V5.3 and V8.2 cannot be run locally at
> all.** Naively copying the x64 file next to it gets you `0x8007000B` (*"an attempt was
> made to load a program with an incorrect format"*), which is the same failure wearing a
> different hat.
>
> Fix — copy the arm64 binary into the places the loader actually searches:
>
> ```powershell
> $b = "$HOME\OneDrive\Documents\PowerShell\Modules\SqlServer\22.4.5.1"
> foreach ($d in @("$b\coreclr\runtimes\win\lib\net6.0",
>                  "$b\coreclr\runtimes\win\lib\net6.0\win-arm64",
>                  "$b\coreclr\runtimes\win-arm64\native")) {
>   New-Item -ItemType Directory -Force -Path $d | Out-Null
>   Copy-Item "$b\Microsoft.Data.SqlClient.SNI.arm64.dll" "$d\Microsoft.Data.SqlClient.SNI.dll" -Force
> }
> ```
>
> **CI is unaffected** — `ubuntu-latest` uses the managed SNI path — which is precisely why
> this is worth writing down: it is a local-only trap, it presents as "the audit is broken",
> and a green CI run offers no clue. Re-apply after any `Update-Module SqlServer`.
>
> Local gate replay on this machine, 2026-08-29: Pester 1,352/1,352 · PSScriptAnalyzer 0 ·
> `npm test` exit 0 (8 workspaces, 960 tests) · pytest 30/30. Still zero cloud writes.

## B. Trial-rate strategy (answers "can I do this at a demo/trial rate?")

Yes — the whole demo window can run on free trials:

| Need | Free path | Duration | Covers |
|---|---|---|---|
| Azure subscription | **Azure free account** ($200 credit). Partner/VS-subscriber credits are **not** available on a personal account (2026-08-26) | **30 days, then the credit is forfeited** — unspent balance does not roll over | All ARM resources. At <$5/mo idle and ~$1/hr active, $200 is comfortable *for 30 days* — it is not a standing budget. This is the master clock |
| Identity licensing **and** Purview/compliance | **Microsoft 365 E5 trial** — one trial, not two | 30 days, 25 seats | Everything the estate uses: `AAD_PREMIUM_P2` (Entra P2 — CA, sign-in risk), `RMS_S_PREMIUM`/`RMS_S_PREMIUM2` (AIP P1/P2, label management), `MFA_PREMIUM`, plus the Exchange-backed tenant that makes Security & Compliance PowerShell work |

> **There is no EMS E5 trial any more (verified 2026-08-29, finding F46).** These were two
> rows until a real tenant proved otherwise: the Microsoft 365 admin center now offers
> Enterprise Mobility + Security **E3 and E5 for purchase only**, at $12 and $18 per user
> per month. Do not buy either. **Microsoft 365 E5 is a strict superset** for this
> estate — it carries the EMS capabilities as service plans inside `SPE_E5`, so a tenant
> on it has no separate `EMSPREMIUM` SKU and needs none. `verify-g0.ps1` used to demand
> that SKU and would have failed a perfectly good tenant while pointing at a $18/user
> purchase; it now asserts the service plans instead.
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
> drift sweep covers prefixed *groups and app registrations* only and never sweeps
> users, so extra real accounts do not trip it.
>
> **A prefixed group or app registration created out of band is a different matter — it
> trips the sweep, and is meant to.** The three identities this runbook creates by hand
> (`mls-github-deployer`, `mls-verifier` at item C3, `mls-purview` at 11c) are exempt only
> because `infra/entra/manifest.json` declares them under `bootstrapAppRegistrations`, a
> key L3 never applies. Create a fourth and you must declare it there too, or L3 stops
> (F167). The prefix itself is resolved from `MLS_COMPANY_PREFIX`, not written into the
> audit — a hardcoded `mls` in that exemption list was F168.

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
| Power Apps Developer Plan | perpetual | n/a — but the environment is **disabled after 30 days of inactivity**, taking the Copilot Studio agent with it |

**Dates, cancellation, and what teardown does not touch** are in
[lifecycle-and-shutdown.md](lifecycle-and-shutdown.md). `down.ps1` deletes four resource
groups and nothing else: every licence, trial, Entra object, Purview label, Fabric
workspace and Power Platform environment survives it, and none of them is billed to the
Azure subscription — so the spending limit does not protect you from any of them.

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

   **Rename the subscription and the directory — two defaults the naming convention does
   not reach [verified 2026-08-31].** A personal-account signup produces a subscription
   called `Azure subscription 1` and a directory called `Default Directory`, and neither is
   covered by `mls-<app|role>-<env>-<type>`, so F90's "rebranding leaves names behind" has
   two more places to hide. Neither is load-bearing — the L2 audit matches subscriptions on
   `id` and only prints `displayName` in its evidence line — but both are demo-visible: the
   subscription name appears in every cost view, and the directory name on the sign-in page
   the demo personas hit.

   **The subscription is automatable; the directory is not.** That asymmetry is the part
   worth knowing:

   ```bash
   az rest --method post \
     --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.Subscription/rename?api-version=2021-10-01" \
     --body '{"subscriptionName":"mls-demo-subscription"}'
   az account list --refresh    # the local cache keeps the old name until you do this
   ```

   The directory name is **read-only through Microsoft Graph on both `v1.0` and `beta`** —
   `Property 'displayName' is read-only and cannot be set.` / `Update to the 'displayName'
   property is not allowed.` It is a portal-only edit: **entra.microsoft.com → Overview →
   Properties → Name → Save**. Do not spend time looking for the API; there isn't one.

   Renaming the directory does **not** change `<tenant>.onmicrosoft.com`, which is fixed at
   creation, so UPNs still read `dana.reyes@<original>.onmicrosoft.com`. If the sign-in page
   itself matters for the demo, **Entra Company Branding** (logo, banner, background) does
   far more than the directory name, and a custom domain is the only real fix.

   **⚠ If you sign up with a personal Microsoft account — the default path from that
   page — you have three more steps before anything else works (finding F46).** Signing
   up with an `@outlook.com`/`@hotmail.com`/`@gmail.com` account gives you a "Default
   Directory" tenant in which *you are an external identity*: your UPN is
   `you_hotmail.com#EXT#@<tenant>.onmicrosoft.com`. That account **cannot sign in to
   `admin.microsoft.com` at all** — it is refused with "You can't sign in here with a
   personal account" — so you cannot buy the licences item 2 needs.

   1. **Create a cloud-only admin** in the Entra portal:
      `admin@<tenant>.onmicrosoft.com`. Use the portal, not `az ad user create`, so the
      password does not land in your shell history. Assign it **Global Administrator**.
   2. **Grant it Owner on the subscription — from the original account.** Global
      Administrator is a *directory* role and carries **no Azure RBAC**; the new admin
      cannot grant itself anything. Sign in as the personal account (which owns the
      subscription) and run:

      ```
      az role assignment create --assignee-object-id <new-admin-object-id> \
        --assignee-principal-type User --role Owner \
        --scope /subscriptions/<sub-id>
      ```
   3. **Set its `usageLocation` before assigning any licence**, or the assignment fails
      with *"License assignment cannot be done for user with invalid usage location"*:

      ```
      az rest --method PATCH --url "https://graph.microsoft.com/v1.0/users/<upn>" \
        --headers "Content-Type=application/json" --body '{"usageLocation":"US"}'
      ```

   Then `az logout && az login` as the new admin and use it for everything: the CLI, the
   M365 admin center, Fabric and Power Platform. Splitting identities across those breaks
   `verify-g0.ps1` check 7, which calls the Fabric API as whoever `az` is logged in as.

   **⚠ Register the resource providers.** A fresh subscription has them unregistered and
   nothing in this repo does it for you; ARM deployments then fail with
   `MissingSubscriptionRegistration` partway through a layer:

   ```
   for p in Microsoft.App Microsoft.Web Microsoft.Sql Microsoft.KeyVault \
            Microsoft.Storage Microsoft.OperationalInsights Microsoft.Insights \
            Microsoft.Fabric; do az provider register -n $p; done
   ```

   It returns immediately and registers in the background; do the portal steps while it
   runs.

   **⚠ Do not run scoped `az` commands from Git Bash on Windows.** MSYS rewrites a
   leading-slash argument into a Windows path, so `--scope /subscriptions/...` arrives as
   `C:/Program Files/Git/subscriptions/...` and the CLI answers `MissingSubscription` — an
   error that points at your subscription rather than your shell. Use `pwsh`, or prefix
   with `MSYS_NO_PATHCONV=1`, or double the leading slash. The repo's own scripts are
   PowerShell and immune; this bites the copy-paste commands in this runbook.

   **Clicking Start begins the 30-day clock.** Do not click it until you are ready to
   work — the credit expires on the calendar, not on usage, so a week of hesitation is a
   week of budget gone. Record the signup date; every date in § B's schedule counts from it.
2. ⚠ **Activate both trials on day 0.** Same day as item 1 — under the 30-day master
   clock every trial either matches the window or outlives it, so staggering buys nothing.

   1. **Microsoft 365 E5** (30 days, 25 seats) from the M365 admin center →
      **Marketplace/Billing → Purchase services**. Search `Microsoft 365 E5` and take the
      **trial**, not the Buy listing. Beware two look-alikes: **Office 365 E5** is a
      different, purchase-only product, and **"Office 365 E5 without Audio Conferencing"**
      is a trial whose SKU (`ENTERPRISEPREMIUM_NOPSTNCONF`) is *not* what you want.
      **Assign it to your admin user** — check 9 asserts ≥1 consumed unit, so an
      unassigned trial reads as no trial. **Do not buy EMS E5**; see § B.
   2. **Fabric** (60 days) from `fabric.microsoft.com` → account manager → **Start
      trial** → **"Fabric and Power BI"**, *not* "Power BI only".

   **⚠ The Power BI trial is not the Fabric trial, and picking wrong is close to
   irreversible (finding F46).** "Power BI only" gives an individual PPU trial and **no
   Fabric capacity**; what appears is `Premium Per User - Reserved`, SKU `PP3`, which is
   Active, looks like a capacity, and cannot host a lakehouse. Worse, **cancelling that
   trial burns the account's trial eligibility** — the Account manager then offers only
   "Buy now" and Microsoft's documented workaround (start a trial by trying to create a
   Fabric item) offers "Buy now" too. The recovery is a **second user**: eligibility is
   per-user, so create `fabric@<tenant>.onmicrosoft.com`, set `usageLocation`, assign it
   one of your 24 spare E5 seats, and start the trial as that account. It becomes the
   trial's Capacity administrator, which is fine — capacity administrators are added
   afterwards.

   **The trial capacity's SKU string is `FTL4`**, not `F4` and not `FT1`, whatever the
   Microsoft documentation's prose says about "an F4 capacity". Its **region is often not
   your home region** — Microsoft's doc warns it may land in East US when your tenant is
   Central US, and moving Fabric items between regions later means deleting them first.
   Decide the estate's `AZURE_LOCATION` to match the capacity **before L1**.
3. ⚠ **Run `scripts/bootstrap/01-root-oidc.ps1`** (agent-authored in Phase P). Under
   your login it: creates app registration `mls-github-deployer` with a federated
   credential for this repo's `demo` environment only (deliberately no branch-ref
   credential — 2026-08-26 finding F7); grants Owner on the subscription; prints the
   admin-consent URL for Graph application permissions (`User.ReadWrite.All`,
   `Group.ReadWrite.All`, `Application.ReadWrite.OwnedBy` — narrowed from `.All`,
   2026-08-26 finding F8 —, `Policy.ReadWrite.ConditionalAccess`, `Directory.Read.All`,
   **`Policy.Read.All`**)
   — you click consent; and creates the read-only `mls-verifier` app (Reader + `Directory.Read.All` +
   **`Policy.Read.All`**) with its **own** federated credential on a distinct `verify`
   environment, never `demo` (2026-08-26 findings F6/F7 — see item C9 below).
   `Policy.Read.All` is what lets the Verifier read Conditional Access policy state
   read-only; V3.3's enforced-MFA audit cannot see the policy without it. This line used
   to name only `Directory.Read.All` — the script has always granted both (finding F43).

   > **Each app gets TWO federated credentials, not one (finding F48).** GitHub now
   > presents a subject carrying **immutable actor identifiers** -
   > `repo:<owner>@<ownerId>/<repo>@<repoId>:environment:demo` - and a credential
   > registered on the classic `repo:<owner>/<repo>:...` form alone is refused with
   > `AADSTS700213`. The script asks GitHub which form it will send
   > (`sub_claim_prefix`) and registers both. Do not trust the API's
   > `use_immutable_subject` flag: this repo returned `false` while GitHub was
   > sending the immutable subject.

   > **`Policy.ReadWrite.ConditionalAccess` does not let the deployer READ Conditional
   > Access policies (finding F50).** Whatever the ReadWrite name suggests, an application
   > permission needs **`Policy.Read.All`** as well. With the other five consented, L3's
   > plan still took `403 AccessDenied - required scopes are missing in the token` on
   > `GET /v1.0/identity/conditionalAccess/policies`, the idempotency read it makes before
   > writing anything. Six permissions, not five.

4. ⚠ **Fabric service-principal settings.** This step used to read *"enable «Service
   principals can use Fabric APIs»"*. **No setting has that name.** It is five settings
   under **Admin portal → Tenant settings → Developer settings**, and getting the wrong
   one leaves G0 green and L5 broken (finding F46). Sign in as the account holding
   **Fabric administrator** or Global Administrator — a Capacity administrator sees a
   truncated Admin portal with no Tenant settings at all.

   | Setting | Set to | Why |
   |---|---|---|
   | **Service principals can create workspaces, connections, and deployment pipelines** | **ON** | `infra/fabric/provision-workspace.ps1` calls `New-FabricWorkspace`. **This is the one L5 needs, and it is off by default.** |
   | **Service principals can call Fabric public APIs** | **ON** | every other Fabric REST call in L5/L8 and the V5.x audits |
   | Service principals can access read-only admin APIs | leave OFF | nothing here calls a Fabric admin API — verified: no `v1/admin` or `myorg/admin` under `infra/fabric` or `verification` |
   | Service principals can access admin APIs used for updates | leave OFF | as above |
   | Allow service principals to create and use profiles | leave OFF | unused |

   The confusing pair is the first two: "call Fabric public APIs" is the one whose name
   most resembles the old label, and it is **not** the one that permits workspace
   creation. On the tenant this was written against the second was already on and the
   first was off.

   `verify-g0.ps1` check 8 (`FabricSpAccess`) now asserts all five, so you do not have to
   trust your own clicking — but the clicking is still yours, and § D no longer claims
   this step is unverifiable.

   **Adding `mls-github-deployer` as capacity administrator happens after C3**, not here:
   the app registration does not exist until `01-root-oidc.ps1` has run.
5. ⚠ **Power Platform environment + Copilot Studio authoring** (blocks L8).
   Four sub-steps, all portal, ~15 minutes. **Total cost: $0.**

   > **This item was rewritten on 2026-08-31 after being executed for the first time.**
   > It previously told you to create a **Production or Sandbox** environment and attach a
   > **pay-as-you-go meter**. Both are unreachable on a trial tenant, and neither is
   > necessary. Following the old text cost an hour and produced three separate
   > conclusions that a purchase was required. None of them was. § B's licensing research
   > was right about the *authors role*; it was wrong about everything downstream of it.

   1. **Sign up for the [Power Apps Developer Plan](https://www.microsoft.com/power-platform/products/power-apps/free)**
      as your admin account. Free, perpetual, and it auto-provisions a developer
      environment with a 2 GB Dataverse database. Sign in with the **work or school**
      account — personal accounts are refused.

      *Not* a Power Apps Premium trial. A trial licence grants **0 GB** of Dataverse
      capacity and can only create *Trial* environments; the 10 GB tenant default arrives
      with a **purchased** subscription, which is what "first subscription" means in
      Microsoft's storage documentation. Verified against a live tenant: the API refuses
      with `NotEnoughCapacity_HasTrialLicense_ProvisionEnvironment`.

   2. **Create the Entra security group and assign it** to the **Copilot Studio authors**
      setting (Power Platform admin center → tenant settings). `infra/entra/manifest.json`
      declares `${prefix}-copilot-authors` so L3 creates the group for you — you add the
      human who will author the agent, and make the assignment.

      **This is the only free authoring path.** Without it Copilot Studio offers a
      licence-gated "Select a team" dialog and nothing else. The Copilot Studio *user*
      licence is "free of charge" but gated behind a **prepaid Copilot Credit pack**
      ($200/pack/month), and the Copilot Studio *trial* licence
      [cannot publish an agent](https://learn.microsoft.com/en-us/microsoft-copilot-studio/billing-licensing).

      Group membership is a token claim: **sign out and back in** afterwards, or you will
      keep hitting the dialog with a token minted before you joined.

   3. **Turn OFF the "New experience" toggle** on the Copilot Studio home page.

      This one is easy to miss and silently fatal. The new *GitHub Copilot harness* has a
      deliberately reduced channel list with **no Direct Line** — its "Native app" tile is
      marked unavailable — and this demo consumes the agent over Direct Line. The
      *standard harness* has the full channel set. Both coexist in the same environment;
      the toggle chooses which you author on.

   4. **Turn on Require secured access** — Settings → Security → **Web channel security** —
      and copy **Secret 1**. That is the Direct Line secret CLAUDE.md's credential
      inventory refers to, exchanged server-side for a short-lived token.

      Without it, *"anyone who knows the agent ID can immediately access the agent through
      the Demo website and Custom website channels"*. Allow **up to two hours** to
      propagate; no republish needed.

   **No pay-as-you-go meter is required**, and attaching one is a **G2** rather than a
   configuration step — Power Platform is licensed separately from Azure, so its charges
   fall **outside** the $200 spending limit. See
   [lifecycle-and-shutdown.md](lifecycle-and-shutdown.md) § 4.

   Verify: [copilotstudio.microsoft.com](https://copilotstudio.microsoft.com) opens on
   your developer environment, **Channels** lists *Native app* and *Web app*, and a test
   agent answers a real question in the test pane. Copilot Studio does not remember the
   environment — bookmark the environment-scoped URL
   (`.../environments/<environment-id>/home`) or it drops you into the tenant Default,
   which has no Dataverse and reports "Dataverse isn't set up in this environment".
6. ○ **Directory Readers for the Azure SQL server identity** — *optional fallback since
   2026-09-03; the deploy path no longer needs it (F172).* This step used to be marked ⚠
   **(blocks EVERY dashboard)** and to open with "One assignment, once per tenant, and
   **nothing in the demo shows data without it**." The first half of that sentence was
   false, and the second half was true only because of the first.

   `CREATE USER [<app identity>] FROM EXTERNAL PROVIDER` makes the SQL engine resolve the
   principal in Microsoft Graph. When a **user** runs it, Azure SQL impersonates that user
   with delegated permissions - which is why running it by hand always works and proves
   nothing. **An application cannot impersonate another application**, so when CI runs it
   as a service principal the engine falls back to *the SQL server's own managed identity*.
   Microsoft is explicit: *"The server identity must exist and have the Microsoft Graph
   query permissions or the operations fail."*
   ([docs](https://learn.microsoft.com/en-us/azure/azure-sql/database/authentication-aad-service-principal))

   **It is not once per tenant.** L6 creates the server in `mls-rg-data`; teardown deletes
   that resource group; the server's **system-assigned** identity dies with it and comes
   back under the same NAME with a NEW principal id, and Entra removes the dangling role
   assignment along with the deleted service principal. So the grant silently stops
   existing the first time the estate is rebuilt - which is the one thing this demo exists
   to do. Read on 2026-09-03, after the re-baseline rebuild:

   - The directory audit log records `2026-09-01T12:23:23Z success` — `mls-ops-demo-sql`
     added to Directory Readers, for a service principal with appId
     `4d541df8-e920-4603-8aa9-2e1ac6da0ead`.
   - The **current** server identity's principalId is
     `031dbb19-9d2c-4832-bf78-be5480aa3a59` and it holds **zero** directory role
     assignments.
   - The Directory Readers role object `fa8f3064-7bdd-4b7b-865c-b1dd09155c1c` has **zero**
     members.

   Four layers later, L7 run `33712156088` logged `data/seed/sql/900-contained-users.sql
   ran without throwing, but 'mls-data-api-demo-id' does not exist in
   mls-ops-demo-sql.database.windows.net/mls-launch-ops-demo-sqldb`, the deploy job still
   reported success, and every SQL-backed `/api/tables` route answered 502 `Login failed
   for user '<token-identified principal>'`. L7's V7.6 is what caught it.

   **What the deploy path does instead, and why you can skip this step.**
   `Set-SeedWorkloadUser` (`data/seed/sql/sql-seed.psm1`) issues `CREATE USER [name] WITH
   SID = <the identity's clientId>, TYPE = E` and then reads the user and its SID back out
   of `sys.database_principals`. Azure SQL stores an application's SID as its application
   (client) id, so supplying it explicitly asks Graph nothing: no server identity is
   consulted, no Directory Readers assignment is needed, and no tenant-level privilege is
   required anywhere. The estate rebuilds itself with no human in the loop, which is the
   property this step could never have.

   **The recipe below is kept for the EXTERNAL PROVIDER route**, which is still the only
   way to create a contained user for a principal whose clientId you do not have. If you
   take it, redo it after **every** teardown, not once. Granting directory read needs
   **Privileged Role Administrator**, which is why it is here and not in a pipeline - and
   deliberately so: an agent that can grant itself directory roles is demonstrating
   something nobody wants to buy. L6's template still creates the server identity
   (`managedIdentities.systemAssigned`), so the principal this recipe names exists.

   **Portal:** Entra ID -> Roles and administrators -> **Directory Readers** -> Add
   assignments -> search for the SQL server's name (the identity carries it).

   **CLI**, noting the single quotes - in PowerShell a double-quoted `$ref` is eaten by the
   parser:

   ```powershell
   $sid = az sql server show -g <data rg> -n <server> --query identity.principalId -o tsv
   $role = az rest --method GET --url "https://graph.microsoft.com/v1.0/directoryRoles?`$filter=displayName eq 'Directory Readers'" --query 'value[0].id' -o tsv
   # Activate the role first if $role is empty - it is not present in a tenant until used:
   #   az rest --method POST --url https://graph.microsoft.com/v1.0/directoryRoles --body '{\"roleTemplateId\":\"88d8e3e3-8f55-4a1e-953a-9b9898b8876b\"}'
   '{"@odata.id":"https://graph.microsoft.com/v1.0/directoryObjects/' + $sid + '"}' | Set-Content body.json
   az rest --method POST --url "https://graph.microsoft.com/v1.0/directoryRoles/$role/members/`$ref" --body '@body.json'
   ```

   **Verify with the unified API, not the legacy one.** `GET /directoryRoles/<id>/members`
   can return `[]` for an assignment that exists and works; this is the reliable check:

   ```bash
   az rest --method GET --url "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$filter=principalId eq '<server identity>'"
   ```

   > **Two traps worth naming.** `az sql server update --identity-type SystemAssigned`
   > **exits 0 and does nothing** - assign the identity with an ARM REST `PATCH` and re-read
   > it to confirm. And Azure SQL caches directory permissions, so allow a few minutes
   > after the assignment before the first `CREATE USER` succeeds.

   L7's F20 step *verifies* rather than reporting that a script ran (F112) - and since
   F172 it verifies that the contained user's **SID matches the identity's clientId**, not
   that a user of that name exists. The name-only check it replaced would have passed on a
   user left behind by a *previous* identity of the same name, whose SID belongs to a
   principal that no longer exists and which therefore cannot log in: the artefact that
   usually accompanies the capability, asserted in place of the capability. A grant that
   does not take now fails the layer loudly with the reason attached, instead of leaving
   every `/api/tables` route answering 502 while the pipeline reports success.

7. ⚠ **Fabric data agent enablement** (blocks L8's knowledge source only — L8 has a
   documented fallback, see § B and `docs/runbooks/layers/L08.md`). In the Fabric admin
   portal, enable the **cross-geo processing for AI** and **cross-geo storing for AI**
   tenant settings, which the data agent requires. Then confirm your capacity is a
   **paid F2 or higher**: the trial capacity cannot run data agents, so on the trial this
   item is *knowingly deferred* and L8 runs tools-only until the G2 to paid F2. Note the
   compliance point Microsoft states plainly: with this integration, "responses returned
   by Fabric data agents may be sent outside of Fabric's compliance boundary or geographic
   region" — fine for synthetic launch data, worth saying out loud on stage.
8. ⚠ **Direct Line channel for the embedded surface** (blocks L8's Ask tab). After the
   L8 pipeline first publishes the agent, in Copilot Studio open **Settings → Security →
   Web channel security**, turn **Require secured access** on, and copy one of the two
   Direct Line secrets. Store it in the L6 Key Vault under the name the `demo`
   environment variable **`MLS_DIRECTLINE_SECRET_NAME`** carries - `mls-directline-secret`
   in this estate. That variable is the one source: L6 passes it to the Bicep, the
   Function's Key Vault reference resolves it, and L8's eval reads it. This runbook used
   to say `directline-secret`, which nothing creates and nothing reads, and L8 spent days
   reporting "holds no 'directline-secret'" over a secret that was sitting in the vault
   (F147):

   ```
   az keyvault secret set --vault-name <kv> --name "$MLS_DIRECTLINE_SECRET_NAME" --value <secret>
   ```

   `apps/directline-token` reads it through a Key Vault reference and exchanges it for
   short-lived, origin-pinned chat tokens; the browser never receives the secret. Two
   practical notes: Copilot Studio keeps **two live secrets** so you can rotate without
   downtime, and toggling secured access **can take up to two hours to propagate** — do
   not schedule this against a demo start time. This is the system's only stored runtime
   secret and it never goes near CI or the repo: GitHub Actions still authenticates by
   federation with no stored secret at all.
9. ⚠ **Budget guard:** run `scripts/bootstrap/03-budget.ps1` — $75/month budget with
   **actual** alerts at 50/80/100% and **forecast** alerts at 50/80%, to your email. The
   forecast pair is the half that warns you before the money is gone rather than after;
   this line used to name only the actual alerts (finding F43). Backstop behind gate G4's cost-anomaly trigger.
   Copilot Studio's meter bills to this same subscription, so it sits inside this budget.
10. ⚠ **Populate the `demo` GitHub environment** with the variables (and the two
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

11. ⚠ **Create the MCP inbound auth secret** — *added 2026-08-26 for finding F2 from the
    pre-publication security review* (`compliance/findings/2026-08-26-prepublication-
    review.md#f2`); *this step itself is unchanged by Task 5's infra fix — only how the
    running container gets the value changed, see below.* Runs **after** L6 creates the
    Key Vault and **before** L7 deploys the apps.

    `apps/mcp-tools` runs with **external ingress by design** — Copilot Studio calls it
    from the public internet, so internal-only is not an option. Without a token its five
    tools (lakehouse SQL, Log Analytics, Defender secure score, Cost Management, GitHub
    security) are callable by anyone who finds the FQDN. The SQL tool is already gated
    read-only, so this is not a write path — but it is unauthenticated read access to your
    tenant's cost and security posture, **and a denial-of-wallet vector**: every call
    resumes serverless SQL and consumes Fabric CU against a 30-day $200 credit.

    Generate a token and store it in the L6 vault:

    ```
    # Two things bite here. Both cost an hour on 2026-08-31 (F87).
    #
    # 1. SUBSTITUTE THE VAULT NAME. `<kv>` is not a prompt, it is shell syntax: bash reads
    #    `<kv>` as a redirect from a file called kv and answers
    #    "bash: kv: No such file or directory". The command never runs, and nothing you
    #    check afterwards says so.
    # 2. OWNER IS NOT ENOUGH. The vault has enableRbacAuthorization, so Owner and Reader
    #    grant no data-plane access at all: `secret set` returns Forbidden. Grant yourself
    #    Key Vault Secrets Officer first and wait ~60s for it to propagate.
    #
    # Note `az role assignment create` may itself fail with (MissingSubscription) even with
    # --subscription supplied; `az rest` against the same ARM endpoint works.

    kv=mls-sec-demo-kv     # or <prefix>-sec-<env>-kv from infra/bicep/naming.bicep
    me=$(az ad signed-in-user show --query id -o tsv)
    sub=$(az account show --query id -o tsv)

    az role assignment create --assignee "$me" --role "Key Vault Secrets Officer" \
      --scope "/subscriptions/$sub/resourceGroups/mls-rg-platform/providers/Microsoft.KeyVault/vaults/$kv"

    az keyvault secret set --vault-name "$kv" --name mcp-auth-token \
      --value "$(openssl rand -base64 32)"
    ```

    **Read the output.** Success prints JSON containing
    `"id": "https://<kv>.vault.azure.net/secrets/mcp-auth-token/..."`. `Forbidden` means the
    role has not propagated yet - wait and repeat. A silent shell prompt means the command
    did not run at all.

    The **layer-07 workflow never reads, exports, or touches this token at all.** The
    container app resolves it directly from Key Vault at runtime through its own
    user-assigned identity: `infra/bicep/apps/main.bicep` grants that identity **Key Vault
    Secrets User** on the vault (module `mcpKvGrant`) and declares the container-app secret
    as a `keyVaultUrl` reference, not a `value`. The token therefore never becomes a deploy
    parameter, a plain env value, a GitHub secret, or anything CI stores or logs (hard rule
    5) — it never appears in `demo.bicepparam`, ARM deployment history, or an
    `az deployment group what-if` log either. Give the same value to the Copilot Studio
    custom connector as its API key; the server accepts either `Authorization: Bearer
    <token>` or `x-api-key: <token>`.

    Verify: `GET /healthz` on the app reports `auth.enforced: true`, and `POST /mcp`
    without a credential returns **401**. If `auth.enforced` is `false`, the endpoint is
    open — the server also says so loudly in its boot log.

    **If you deliberately want an open endpoint** (throwaway environment only), set
    `MCP_ALLOW_UNAUTHENTICATED=true`. **Every** mode otherwise refuses to boot without a
    token, by design: an open endpoint has to be chosen, never defaulted into.
    (Not just cloud mode. An earlier revision of this line said "cloud mode", which is
    precisely the inversion finding F2 was about: the shipped configuration is `local`,
    so a gate that only armed itself in cloud was inert in production. `loadInboundAuth`
    in `apps/mcp-tools/src/auth-gate.ts` now throws regardless of mode.)

11b. **`mls-data-api-github-token` — the GitHub read-only token for Control Tower's Dev
    and Sec tabs** *(added 2026-09-01, finding F116; renamed from `mls-github-token` the
    same day, because three GitHub tokens now exist in this estate and a name that says
    only "github" cannot tell you which one it is — this is **data-api's** read token)*. Optional, and the estate deploys and runs
    without it: the three GitHub feeds then answer a typed **503** naming exactly what is
    missing, Control Tower's **Ops** tab (lakehouse-backed) is unaffected, and Launch Ops
    is unaffected. Skipping this is a supported configuration, not a broken one.

    Provisioning it turns on `feeds/workflow-runs`, `feeds/code-scanning-alerts` and
    `feeds/dependabot-alerts`. Note the repository is **public**, so `actions/runs` is
    readable anonymously — it is `code-scanning` and `dependabot` that genuinely require
    a credential.

    Create a **fine-grained PAT** at
    <https://github.com/settings/personal-access-tokens/new>, scoped to **this repository
    only**, with **read-only** on **Actions**, **Code scanning alerts**, **Dependabot
    alerts** and **Metadata**. Nothing needs write. Then:

    ```bash
    kv=mls-sec-demo-kv     # or <prefix>-sec-<env>-kv from infra/bicep/naming.bicep

    # SAME RBAC PRECONDITION AS ITEM 11, and it catches people who skipped that item:
    # this vault is RBAC-mode, so Owner and Global Admin grant NO data-plane access and
    # the set below fails `ForbiddenByRbac / Assignment: (not found)` for an account that
    # can otherwise do anything in the subscription. If you did item 11 you already hold
    # the role; if you jumped here, grant it first.
    az keyvault secret set --vault-name "$kv" --name mls-data-api-github-token --value '<PAT>'
    ```

    Then set the repository **variable** `MLS_GITHUB_TOKEN_SECRET` to
    `mls-data-api-github-token`
    (a variable, not a secret — a secret's NAME is not sensitive), and redeploy L7. The
    token itself never becomes a deploy parameter, a GitHub secret, or an env value:
    `infra/bicep/apps/main.bicep` grants data-api's identity **Key Vault Secrets User**
    (module `dataApiKvGrant`) and declares the container-app secret as a `keyVaultUrl`
    reference, exactly as `mcp-auth-token` does — which matters more than usual here,
    because this repository is public and `what-if` output is printed into workflow logs
    GitHub cannot mask a value it never held.

    **This is the seventh long-lived credential**, and hard rule 5 requires a written
    reason. It is this: GitHub's code-scanning and Dependabot alert APIs have no
    federated or anonymous path — both return **401** unauthenticated even on a public
    repository — and the DevSecOps posture panels are a core part of what the estate
    exists to show. Rotate it with the other six; `.github/workflows/gitleaks.yml`'s
    incident text is the rotation list.

    Verify: `GET /api/feeds/workflow-runs` on Control Tower returns **200** with runs,
    and the Dev and Sec tabs render instead of reporting `backend_not_configured`.

11c. **`mls-purview` — the Security & Compliance app-only identity** *(added
    2026-09-01)*. Without it L4 cannot apply the label taxonomy unattended and the
    tenant has **no sensitivity labels at all**, which is where this estate sat for
    its whole life until now.

    A certificate, not OIDC, because **Security & Compliance PowerShell has no
    federated auth path** — that is why hard rule 5 permits these two as long-lived
    credentials rather than treating them as a lapse.

    ```bash
    # 1. the app, and its certificate
    openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes       -keyout purview.key -out purview.crt -subj "/CN=mls-purview"
    openssl pkcs12 -export -out mls-purview.pfx -inkey purview.key -in purview.crt       -passout pass:"$PW"

    APP_ID=$(az ad app create --display-name mls-purview       --sign-in-audience AzureADMyOrg --query appId -o tsv)
    az ad app credential reset --id "$APP_ID" --cert @purview.crt --append --years 1
    az ad sp create --id "$APP_ID"
    SP_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
    ```

    **`--append` IS NOT OPTIONAL.** `az ad app credential reset` REPLACES every existing
    credential by default. On an app that already has one, omitting it is a silent
    outage.

    ```bash
    # 2. Exchange.ManageAsApp on Office 365 Exchange Online
    az ad app permission add --id "$APP_ID"       --api 00000002-0000-0ff1-ce00-000000000000       --api-permissions dc50a0fb-09a3-484d-be87-e023b12c6440=Role
    az ad app permission admin-consent --id "$APP_ID"
    ```

    **VERIFY THAT CONSENT, DO NOT TRUST ITS EXIT CODE.** Observed on the first run:
    `admin-consent` exited 0 and created no assignment at all. Read it back —

    ```bash
    az rest --method get       --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignments"
    ```

    — and if it is empty, grant it directly, which works:

    ```bash
    # resourceId is the Office 365 Exchange Online SERVICE PRINCIPAL in your tenant:
    #   az ad sp show --id 00000002-0000-0ff1-ce00-000000000000 --query id -o tsv
    az rest --method post       --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/appRoleAssignments"       --headers "Content-Type=application/json"       --body '{"principalId":"<SP_ID>","resourceId":"<exchange sp objectId>","appRoleId":"dc50a0fb-09a3-484d-be87-e023b12c6440"}'
    ```

    ```bash
    # 3. the directory role - the API permission authenticates it but grants it
    #    nothing to DO; Connect-IPPSSession needs a compliance role as well.
    #    17315797-102d-40b4-93e0-432062caca18 is the Compliance Administrator template.
    ```

    **CHECKING THAT ROLE WILL LIE TO YOU IF YOU ASK THE WRONG WAY.**
    `GET /v1.0/directoryRoles/{id}/members` **does not enumerate service principal
    members** — it returns `[]` for a role the SP is genuinely in. Ask the principal
    instead:

    ```bash
    az rest --method get       --url "https://graph.microsoft.com/v1.0/servicePrincipals/$SP_ID/memberOf"
    ```

    That cost a wrong conclusion the first time, and it is the same absence-vs-denial
    shape as F103 and F105: an empty list read as absence when it meant "this endpoint
    will not tell you".

    Finally the three values L4 gates on — **all three, or the apply job skips GREEN
    with a notice, which is finding F43**:

    ```bash
    gh variable set PURVIEW_APP_ID       --env demo --body "$APP_ID"
    gh variable set PURVIEW_ORGANIZATION --env demo --body '<tenant>.onmicrosoft.com'
    gh secret   set PURVIEW_CERT_BASE64   --env demo < <(base64 -w0 mls-purview.pfx)
    gh secret   set PURVIEW_CERT_PASSWORD --env demo
    ```

    **AND DECLARE IT IN `infra/entra/manifest.json` UNDER `bootstrapAppRegistrations`,
    or L3 fails.** V3.1 sweeps the tenant for prefixed groups and app registrations the
    manifest does not declare, and this one is prefixed. It was created here on
    2026-09-01 and declared nowhere a check could read, so the next run of that sweep —
    the 2026-09-03 rebuild — reported it as drift and stopped L3 (**F167**). The
    declaration *is* the exemption: the sweep exempts per name, not per pattern, so
    adding a bootstrap identity stays a deliberate act with a diff.

    **Do NOT add it to `appRegistrations`.** `apply-entra.ps1` iterates that array and
    create-if-absents every entry, which would mean two things and both are worse than
    the drift. On a tenant where `mls-purview` exists, `mls-github-deployer` holds
    `Application.ReadWrite.OwnedBy` — covering only registrations **it** created — and
    gets a 403 updating one it does not own. On a tenant where it does not (a fresh
    clone, or after a G3 teardown), L3 mints an **impostor**: an `mls-purview` with no
    certificate, no `Exchange.ManageAsApp` and no Compliance Administrator role, while
    `PURVIEW_APP_ID` still names the old GUID — and **V3.1 would go green on it**,
    because a registration resolving to exactly one object is all the count asserts.
    `bootstrapAppRegistrations` is a key L3 never applies, and
    `Assert-ManifestSchema` refuses a name that appears in both arrays.

12. ⚠ **Entra ID `SignInLogs`/`AuditLogs` diagnostic setting** — *added 2026-08-26 for
    finding F9* (`compliance/findings/2026-08-26-prepublication-review.md#f9`);
    *deliberately a human step, not a pipeline step — see below.* **Out of sequence
    with the numbering above in both directions:** it cannot be done until **after**
    the first successful L6 run (the Log Analytics workspace it points at does not
    exist before then), and nothing later in this checklist, or in any pipeline layer,
    waits on it — working through items 1–11 in order and then stopping is a complete
    bootstrap; come back and do this one once, after L6, whenever convenient.

    This is the one piece of F9 (zero `diagnosticSettings`/audit routing anywhere in
    the estate) that `layer-06-platform.yml` does not wire automatically, even though
    the subscription Activity Log right next to it in that workflow does. The
    difference is the privilege the caller needs: creating a tenant-scoped Entra
    diagnostic setting requires the **Security Administrator** (or Global
    Administrator) Entra directory role, and `mls-github-deployer` must not hold it.
    Item 3 above narrowed this exact SP from `Application.ReadWrite.All` to
    `.ReadWrite.OwnedBy` specifically to shrink its tenant blast radius (finding F8);
    granting it Security Administrator now would re-inflate precisely what that
    narrowing closed, to automate a setting that is configured once and never replayed
    by the kill/rebuild loop — the same class of one-time, tenant-level, portal/CLI
    item as C4 (the Fabric SP API toggle) above.

    Run once, signed in as yourself or anyone else holding Security Administrator or
    Global Administrator:

    ```
    az monitor diagnostic-settings create \
      --name <prefix>-entra-law \
      --resource "/providers/microsoft.aadiam" \
      --workspace <LAW resource id> \
      --logs '[{"category":"SignInLogs","enabled":true},{"category":"AuditLogs","enabled":true}]'
    ```

    `<prefix>` is the `naming.bicep` company prefix (`mls` by default). `<LAW resource
    id>` is `logAnalyticsWorkspaceResourceId` from the L6 deployment manifest, or
    resolve it directly: `az monitor log-analytics workspace show --resource-group
    <rg-platform> --workspace-name <law> --query id -o tsv`.

    Idempotent — safe to re-run; re-run it after any kill/rebuild cycle that recreates
    `mls-rg-platform`, since that mints a new workspace resource ID and the old
    setting is left pointing at a deleted one.

    Verify: `az monitor diagnostic-settings list --resource "/providers/microsoft.aadiam"`
    lists the setting with both `SignInLogs` and `AuditLogs` enabled, and the `SigninLogs`
    / `AuditLogs` tables in the Log Analytics workspace populate within about 15 minutes
    of the next sign-in or directory change — distinct from `AzureActivity`, which is the
    subscription Activity Log layer-06-platform.yml already wires on its own.

    You no longer have to remember to run that `az monitor diagnostic-settings list`
    yourself: `scripts/bootstrap/verify-g0.ps1` runs the same query as a tenth,
    **informational** check (added Task 23) and reports whether it finds the setting —
    see § D. It never blocks G0; it just means a missing setting shows up in the table
    instead of staying invisible until someone goes looking for it.

13. ⚠ **Create the break-glass (emergency access) account** — *added 2026-08-28 with
    the enforced dashboard MFA policy.* **Out of sequence, like item 12:** it cannot be
    done until **after** the first L3 run, because the group it belongs to
    (`mls-break-glass`) does not exist until `apply-entra.ps1` creates it — and the
    enforced policy is not created until this account exists. That is deliberate: L3 is a
    two-pass layer the first time, and the second pass is the same dispatch as the first.

    **Why.** `infra/entra/manifest.json` declares `mls-ca-require-mfa-dashboards` with
    `state: enabled` — a real, enforced Conditional Access policy requiring MFA for every
    user signing in to `launch-ops`, `control-tower` and the compliance board. Microsoft's
    guidance for any enforced CA policy is to exclude at least one emergency-access
    account, and the reason is blunt: a wrong policy, a grant nobody can satisfy, or an
    MFA service outage otherwise locks **you** out of **your own tenant**, with the
    portal, the CLI and Graph all behind the same policy and no way back in.

    **What to create** (Microsoft's emergency-access guidance, applied to this estate):

    - **Global Administrator, ACTIVE and permanent — not PIM-eligible.** This bullet was
      missing until 2026-08-30, and its absence was not cosmetic: the account created for
      this estate satisfied every other condition here while holding **no directory role at
      all**, and both `apply-entra.ps1` and V3.3 accepted it. An emergency-access account
      that cannot administer the tenant cannot recover it, and the enforced MFA policy would
      have deployed on the strength of that (F77).

      *Eligible is not active, and here eligible is worse.* Just-in-time elevation through
      PIM is better practice nearly everywhere; for break-glass it reintroduces exactly the
      dependencies the account exists to remove — a successful sign-in, a healthy PIM
      service, and usually MFA, which is frequently the control you are breaking glass to
      escape. Microsoft's emergency-access guidance says permanently assigned, and means it.
      `Test-BreakGlassReady` now checks `transitiveMemberOf` for an active assignment, so an
      eligible-only account is refused with the reason.
    - **Cloud-only.** A `<something>@<tenant>.onmicrosoft.com` account, never federated
      and never synced from on-premises — a break-glass account that depends on the sync
      source dies with it. `apply-entra.ps1` and V3.3 both refuse an account with
      `onPremisesSyncEnabled = true`.
    - **Not one of the demo personas.** Dana, Miles, Priya, Sofia and Marcus are
      fictional and this repository is public (CLAUDE.md rule 4); no human holds their
      credentials, so none of them is an emergency account. Both the apply script and
      V3.3 refuse a break-glass group whose only members are manifest personas.
    - **Check whether Security Defaults are on before expecting the enforced policy.**
      Graph refuses an *enabled* Conditional Access policy while Security Defaults are
      enabled, and accepts report-only ones — so on a default tenant this estate deploys two
      of its three policies and declines the third, on purpose. **Do not simply turn Security
      Defaults off to get past it.** This manifest enforces only the dashboard policy, so
      that trade takes baseline MFA away from every user and gives back one policy: you would
      finish a security demo weaker than you started (F75). V3.3 passes on such a tenant,
      because MFA *is* enforced — by a different mechanism, which is what control 3.5.3
      actually asks about. To move to Conditional Access properly: raise the two broad
      policies to `enabled` in the manifest first, register MFA for the accounts they scope,
      *then* disable Security Defaults.
    - **Excluded from every Conditional Access policy**, not just this one. In this repo
      the other two policies are report-only, so today only this one has an exclusion to
      make; the moment you enforce another, exclude the same group.
    - **Credential stored out of band** — a password manager or a sealed envelope, not
      this repo, not Key Vault behind the same tenant sign-in, not CI (hard rule 5). Long,
      random, no expiry surprise.
    - **Monitored.** Its sign-ins should be rare and every one of them worth a question.
      With item 12's `SignInLogs` routing in place, alert on any sign-in by it:
      `SigninLogs | where UserPrincipalName == "<break-glass upn>"`.
    - Two such accounts, on different authentication paths, is Microsoft's actual
      recommendation for a production tenant. One is enough for this demo; the group
      accepts as many as you add.

    Then add it to the group L3 created:

    ```
    az ad group member add --group mls-break-glass \
      --member-id "$(az ad user show --id <break-glass upn> --query id -o tsv)"
    ```

    Re-dispatch `layer-03-entra.yml`. The apply log should now report `CaCreated`
    including `mls-ca-require-mfa-dashboards` rather than `CaBlocked=1`, and V3.3 should
    pass. **Until you do this, MFA is not enforced** — the layer applies cleanly and says
    so in red, and V3.3 fails. That is the intended failure direction: no policy is safer
    than an enforced policy with no way out of it.

### C9 — the `demo` and `verify` GitHub environments, variable by variable

These are GitHub **environment variables**, not secrets, and they are never committed
(spec F5 / CLAUDE.md hard rule 5). Create **both** environments — `demo` for deploy jobs,
and `verify` for the Verifier (2026-08-26 findings F6/F7: `mls-verifier`'s federated
credential is on a `verify` subject, deliberately distinct from the deployer's `demo`
subject, so every `verify` job now declares `environment: verify` rather than `demo`) —
and set each value:

```
gh api -X PUT repos/paulcfuqua/azure-devsecops-demo/environments/demo
gh api -X PUT repos/paulcfuqua/azure-devsecops-demo/environments/verify
gh variable set <NAME> --env demo --body <value>
gh variable set <NAME> --env verify --body <value>
```

> **Why two environments, and why the same variable in both (2026-08-26).** GitHub
> environment variables do not cascade between sibling environments. Every `verify` job's
> `preflight` gate still runs under `environment: demo` (it only ever reads `vars.*`, never
> logs in, so reusing the deployer's subject there costs nothing) and decides whether a
> verify job should attempt to run at all — so `AZURE_VERIFIER_CLIENT_ID`,
> `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` must exist on `demo` for that gate to read
> `true`. The `verify` job itself now runs under `environment: verify`, where the SAME three
> variables (plus `MLS_TENANT_DOMAIN` / `MLS_VERIFIER_APP_ID` for L4) must also exist for its
> own `azure/login` to resolve them. Set each verifier-related variable in **both** places
> with the **same value**. A deployment-branch policy restricting both environments to
> `main` is a further, recommended hardening step (not required for G0, not yet scripted
> here) — see finding F7's compounding point in
> `compliance/findings/2026-08-26-prepublication-review.md#f7`.

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
one, so an estate configured this far is deployed but unverified. Set each of these on
**both** `demo` (the `preflight` gate reads it there) and `verify` (the `verify` job's
`azure/login` reads it there) — see the box above:

| Variable | Value | Read by |
|---|---|---|
| `AZURE_VERIFIER_CLIENT_ID` | `mls-verifier` app ID (item C3) | `preflight`'s verifier-configured gate (on `demo`) and every `verify` job's `azure/login` (on `verify`) |
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
| `MLS_COMPLIANCE_CLIENT_ID` | Entra **application (client) ID** the compliance board's Container Apps Easy Auth validates sign-ins against (`infra/bicep/apps/demo.bicepparam` → `complianceEntraClientId`) | The compliance board (L12). **Not a secret:** an OAuth client ID is a public identifier, visible in the browser's own redirect URL during login, and the provider is configured with **no client secret at all**. Set it as a *variable*, not a secret | **Optional override.** L7 resolves it from Entra; set it only to bring your own registration |
| `MLS_LAUNCH_OPS_CLIENT_ID` | Same, for `launch-ops` (`→ launchOpsEntraClientId`). Registration: `mls-launch-ops-demo-app` | The launch-ops dashboard. Since F25 this app is login-gated: it proxies `/api/` to `data-api`, whose identity holds Security Reader at subscription scope | **Optional override** — same as above |
| `MLS_CONTROL_TOWER_CLIENT_ID` | Same, for `control-tower` (`→ controlTowerEntraClientId`). Registration: `mls-control-tower-demo-app` | The control tower. This is the app F25 was demonstrated against: `GET /api/feeds/secure-score` returned live Defender posture to anonymous callers | **Optional override** — same as above |

> **The three `MLS_L9_*` values are now produced by the layer run.**
> `.github/workflows/layer-09-devsecops.yml` exists (2026-08-24) and passes all three to
> the audit as explicit arguments: `-LayerRunId` and `-ZapRunId` are its own
> `github.run_id`, and `-ReleaseTag` is the tag its `release` job created. `zap.yml` and
> `sbom.yml` are **called** with `uses:` rather than dispatched, so a reusable workflow's
> jobs and artifacts belong to the caller's run — which is what makes one run id serve
> both V9.2 and V9.4. Leave all three variables unset on the happy path; they survive only
> as an override for re-verifying an older run by hand.

> **All three dashboards are login-gated, and you do not have to configure that
> (F25/F26/F36, 2026-08-28).**
> `infra/entra/manifest.json` declares four app registrations **under
> `appRegistrations`** — `mls-launch-ops-demo-app`, `mls-control-tower-demo-app`,
> `mls-mcp-tools-demo-app` and `mls-compliance-demo-app`.
> Creating them is the **Identity & Governance workstream's** job (L3); the L7 template
> deliberately owns no Entra writes.
>
> The file also declares three registrations under **`bootstrapAppRegistrations`** —
> `mls-github-deployer`, `mls-verifier` and `mls-purview`. Those are **not** L3's to
> create: they are the identities this runbook makes by hand, each carrying a credential
> no pipeline can mint, and `apply-entra.ps1` never iterates that key. They are declared
> so V3.1's drift sweep can exempt them by name rather than by a literal in the audit
> (F167, F168). Seven names in the file, four registrations created by L3.
>
> **The three variables above are overrides, not prerequisites.** On a normal
> `infra-up` the flow is entirely automatic:
> 1. **L3** creates the four registrations from the manifest, as `mls-github-deployer`.
> 2. **L7** looks each dashboard's application (client) ID up by that registration's
>    manifest display name (`az ad app list`), honouring one of the three variables first
>    if you set it. `mls-github-deployer` holds `Application.ReadWrite.OwnedBy`, which
>    covers exactly the registrations it created at L3.
> 3. **L7, after the apps deploy**, adds each app's Easy Auth reply URL —
>    `https://<that app's ingress FQDN>/.auth/login/aad/callback` — to its registration,
>    *merged* into whatever is already there. That FQDN does not exist until the app is
>    deployed, which is why this used to be a manual step and is now not one.
>
> **A client ID that cannot be resolved is not an error.** That app still deploys, but
> `infra/bicep/apps/main.bicep` ties each app's `ingressExternal` to the *same* expression
> as its `authConfig`, so it comes up **internal to the Container Apps environment** and
> unreachable from the internet. The run says exactly which apps those are, and prints the
> one command that fixes it (`gh workflow run layer-03-entra.yml`). There is no parameter
> combination that publishes one of these three apps anonymously. An `az` failure, or two
> registrations with the same name, *is* an error and stops the deploy — a throttled CLI
> call and "L3 has not run yet" must not look the same.
>
> **What this runbook used to say here was wrong twice.** It first claimed that leaving
> `MLS_COMPLIANCE_CLIENT_ID` unset made the parameter fall back to the literal `'unset'`,
> so "ARM rejects the deployment outright". It does not, and never did.
> `layer-07-apps.yml` passes `${{ vars.MLS_COMPLIANCE_CLIENT_ID }}`, and **an undefined
> GitHub variable expands to the empty string** — so the environment variable is
> *set-but-empty*, `readEnvironmentVariable` returns `''`, and the `'unset'` default is
> never reached. (Confirmed against Bicep CLI 0.46.1: variable unset → `"unset"`;
> variable set to the empty string → `""`.) It then claimed L7 refused to deploy without
> all three variables — true when written, and the reason the estate could not be
> deployed out of the box at all. That refusal is gone (F36).
>
> Never work around a sign-in prompt by removing `authConfig`: `control-tower` and
> `launch-ops` proxy `/api/` straight through to `data-api`, whose identity holds
> **Security Reader at subscription scope** (finding F25).
> `docs/runbooks/layers/L12.md` § Preconditions carries the same statement for whoever is
> deploying that layer.

**Optional tuning** (each has a working default, so leave them unset until you need them):

| Variable | Default | Effect |
|---|---|---|
| `SQL_AAD_ADMIN_LOGIN` / `SQL_AAD_ADMIN_OBJECT_ID` | none | Entra admin for the L6 SQL server. Without them the server deploys with no Entra administrator |
| `KEY_VAULT_CREATE_MODE` | `default` | Set to `recover` when replaying against a soft-deleted vault (kill/rebuild) |
| `LAUNCH_OPS_PORT`, `CONTROL_TOWER_PORT`, `MCP_TOOLS_PORT`, `DATA_API_PORT`, `COMPLIANCE_PORT` | `80` | Container ingress target ports. The real images listen on **8080**; this is open item P-1 and flipping all five closes it |
| `DATA_API_APP_NAME` | `<prefix>-data-api-<env>-ca` | Overrides the derived container app name in `app-data-api-ci.yml` |
| `MCP_ENDPOINT_PATH` | `/mcp` | Path the MCP server serves Streamable HTTP on |
| `MLS_ALERT_EMAIL` | none | Email receiver for the L6 security action group (F17: Key Vault access-denied and SQL failed-login alerts). Without it the action group deploys with **zero receivers** — the two scheduledQueryRules still evaluate and fire, but nobody is notified; layer-06-platform.yml's deploy step prints a loud warning when this is unset |

### C9b — the `demo` and `verify` environments' secrets, and why each one exists

CI holds **no LLM key and no cloud credential**: everything Azure authenticates by OIDC /
workload identity federation (2026-08-24 amendment § 2). It does **not** hold "no secret
at all" — that claim, which several documents in this repo used to make above this very
table, was finding **F28**. Six long-lived credentials exist in this system: the four
below, plus two in Key Vault (the **Direct Line secret**, read at run time and never
stored here, and `mcp-auth-token`). Each of the four exists because no federated path
does the job — **Security & Compliance PowerShell has no federated auth**, so certificate
app-only is the only way to touch Purview labels unattended, and a `GITHUB_TOKEN` push
does not trigger workflows, which is why the self-heal chain needs a PAT.
`.github/workflows/gitleaks.yml` prints all six as the rotation list when it finds
something; if you add a seventh, add it there too. The two verifier-only secrets (`MLS_VERIFIER_CERT_*`,
`MLS_VERIFIER_GH_TOKEN`) are read inside `verify` jobs, which now run under the `verify`
environment (2026-08-26 findings F6/F7) — set them with `--env verify`, not `--env demo`;
`PURVIEW_CERT_BASE64` stays on `demo` since the L4 **deploy** job is unaffected by this fix.

| Secret | Needed by | If absent |
|---|---|---|
| `PURVIEW_CERT_BASE64` (+ `PURVIEW_CERT_PASSWORD`) | the L4 **deploy** job's `Connect-IPPSSession` (env `demo`). **Needs the `PURVIEW_APP_ID` and `PURVIEW_ORGANIZATION` *variables* set too — see the note below this table; all three are required or the job skips** | `labels.ps1` stays a human-run step under your login — the L04 playbook's documented degrade path. Nothing fails |
| `MLS_VERIFIER_CERT_BASE64` (+ `MLS_VERIFIER_CERT_PASSWORD`) | the L4 **audit**'s own read-only S&C session as `mls-verifier` (env `verify`), and the L3/L4 child audits V11.2 re-runs after a teardown | L4 verification skips with a NOTICE, and V11.2 records SKIP via `-SkipChildAudit`. Neither is a pass — the labels are simply unverified |
| `MLS_VERIFIER_GH_TOKEN` | the Verifier's GitHub reads (V1.x, V7.4, V9.1–V9.4, V10.1, V10.2), all in `verify`-environment jobs | the audits fall back to the run-scoped `GITHUB_TOKEN`, which GitHub mints per run and stores nowhere. That covers everything **except Dependabot alerts**, which that token is refused on — so V10.2 reports an unreadable trail rather than a passing one. A fine-grained PAT with `security_events: read` closes it |
| `SELF_HEAL_TOKEN` | `self-heal.yml`'s PR authoring (env `demo`) | PRs are authored by `GITHUB_TOKEN`, whose `pull_request` runs start approval-required, so auto-merge cannot fire unattended. Parked sponsor decision |

**THE PURVIEW PATH NEEDS THREE VALUES, NOT TWO, AND ONE OF THEM WAS DOCUMENTED NOWHERE.**
`layer-04-purview.yml` gates its apply job on all three of `PURVIEW_APP_ID`,
`PURVIEW_ORGANIZATION` and `PURVIEW_CERT_BASE64` being non-empty; any one missing sets
`scc=false`, skips the apply job, and prints a notice. `PURVIEW_APP_ID` — the **variable**
holding the Entra app registration's application (client) ID for the Security & Compliance
app-only identity — appeared in no runbook in this repository until finding F43. So an
operator could set exactly what this table asked for, see a green L4 run, and still have
no labels applied: F18's effect, reached by a different route.

```
gh variable set PURVIEW_APP_ID     --env demo --body '<app registration client id>'
gh variable set PURVIEW_ORGANIZATION --env demo --body '<tenant>.onmicrosoft.com'
```

It fails safe, which is why nothing broke loudly — but "fails safe" and "does what you
asked" are different things, and the whole point of L4 is that the label taxonomy is
applied rather than aspirational.

Both certificates are the same shape: export the app's certificate as a PFX and store it
base64-encoded. Set the password secret only if the PFX has one.

```
gh secret set MLS_VERIFIER_CERT_BASE64 --env verify < <(base64 -w0 mls-verifier.pfx)
```

## D. What "G0 complete" means

The Orchestrator re-runs `scripts/bootstrap/verify-g0.ps1` (read-only). It runs
**exactly eleven checks**, and this list is now enumerated rather than described, because the
prose that stood here claimed two verifications the script does not perform (finding F43):

| # | Check | Asserts |
|---|---|---|
| 1 | `CliLogin` | `az` logged in, active subscription is the expected one |
| 2 | `DeployerApp` | `mls-github-deployer` registration exists |
| 3 | `Federation` | a federated credential exists for **every subject form GitHub says it will send** - the prefix is read from `sub_claim_prefix`, never constructed (F48) |
| 4 | `OwnerRole` | its service principal holds Owner at subscription scope |
| 5 | `GraphConsent` | all **six** application permissions are consented. The count is read from the script's own map, not written in prose, so it cannot drift again (F50) |
| 6 | `VerifierApp` | `mls-verifier` exists with a federated subject **distinct** from the deployer's (F6/F7) |
| 7 | `FabricCapacity` | an **F-series** capacity is visible through the Fabric API. The SKU is checked, not just the state (F46) |
| 8 | `FabricSpAccess` | **C4** — service principals may create workspaces and call Fabric public APIs; the three admin-API settings are off (F46). Where a setting is scoped to a security group, membership of `mls-github-deployer` is confirmed rather than assumed (F50) |
| 9 | `Licenses` | the **service plans** the layers consume — `AAD_PREMIUM_P2`, `RMS_S_PREMIUM`, `MFA_PREMIUM` — from whatever SKU provides them, with ≥1 unit consumed (F46) |
| 10 | `Budget` | the budget exists at the expected amount with the expected thresholds |
| 11 | `EntraDiagnostics` | *informational only* — tenant diagnostics route SignInLogs + AuditLogs to Log Analytics (F9). Never affects the exit code |

**C4 IS NOW CHECKED. C5 STILL IS NOT.** Yesterday this section said both were
unverifiable — *"portal work with no read path this script can use under your login"* —
and a real tenant disproved half of that within a day (finding F46).

* **C4 is check 8.** The Fabric admin API returns every tenant setting to a Fabric or
  Global administrator at `GET https://api.fabric.microsoft.com/v1/admin/tenantsettings`.
  Writing that check found a live defect the prose had hidden: **C4 is not one toggle.**
  The runbook called it *"Service principals can use Fabric APIs"*, a setting that no
  longer exists by that name. It is five, and the two that matter are easy to confuse —
  on the tenant this was written against, `ServicePrincipalAccessPermissionAPIs` ("call
  Fabric public APIs") was **on** while `ServicePrincipalAccessGlobalAPIs` ("create
  workspaces, connections, and deployment pipelines") was **off**. L5 calls
  `New-FabricWorkspace`, which the *off* one governs. G0 would have gone green and L5
  would have failed.
* **C5, the Power Platform environment and Copilot Studio pay-as-you-go billing plan, is
  still unchecked.** `grep -i powerplatform scripts/bootstrap/verify-g0.ps1` returns
  nothing. Skip C5 and G0 reports green; **L8 is where you find out.**

A twelfth check against the Power Platform admin API
(`api.bap.microsoft.com/.../scopes/admin/environments`) would close that last gap. It is
not shipped yet for one reason only: nobody has exercised it against a tenant. That was
also the stated reason C4 could not be checked, and C4 turned out to be checkable the
moment someone tried — so treat this as a to-do, not a law.

Only when the eleven checks are green **and** C5 is confirmed by eye does Layer 1 deploy.

Items C6, C7, C10 and 13 are **not** G0-complete blockers for Layer 1 — C7 cannot even be
done
until L8 has published an agent, C6 is deferred by design while the Fabric capacity
is on the trial SKU, C10 is now performed BY L3 itself (F79) and needs no operator action, and item
13 cannot run until L3 has created the group. C6/C7
block L8 only, C10 blocks L3's V3.4 only, and item 13 blocks L3's V3.3 only;
`verify-g0.ps1` reports them as
informational rather than failing the gate. Note what item 13 blocking V3.3 means in
practice: **the enforced MFA policy is not created until you do it**, so an estate that
skips item 13 has dashboards behind an Entra sign-in with no second factor.

**Item 12 (2026-08-26 finding F9, added Task 23) gets the same treatment, for a different
reason.** `verify-g0.ps1` now runs a tenth, read-only `EntraDiagnostics` check (`az monitor
diagnostic-settings list --resource "/providers/microsoft.aadiam"`) asserting the tenant
diagnostic setting routes both `SignInLogs` and `AuditLogs` to the Log Analytics workspace.
It renders `INFO`, not `PASS`/`FAIL`, and never contributes to the script's exit code —
unlike C6/C7/C10, item 12 has no layer gate downstream waiting on it either way, so there
is nothing for it to block. The point of the check is narrower: before it existed, F9's
closure rested entirely on a human remembering to run an unaudited command after L6; now a
missing setting shows up in the G0 table instead of staying invisible until someone
happens to go looking.

Note that `verify-g0.ps1` check 8 ("licences: M365 E5 and EMS E5 present with at least one
unit consumed") is a **tenant-level** check — it confirms the trials are activated, not
that any demo user holds a seat. Per-user assignment is C10's job and V3.4's assertion.
