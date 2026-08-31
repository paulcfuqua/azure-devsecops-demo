# Lifecycle and shutdown — what expires, what bills, and what teardown does not touch

`scripts/down.ps1` deletes four resource groups. That is the whole of the automated
teardown, and it is deliberately narrow: the kill/rebuild cycle must never touch anything
it cannot recreate (see [kill-rebuild.md](kill-rebuild.md) § 1).

Everything else on this page is **outside that boundary** — trials that lapse on a
calendar, licences that renew, and tenant objects that survive every `down.ps1` you will
ever run. None of it is billed to the Azure subscription, so **the $200 spending limit
does not protect you from any of it.**

> **Read this before the credit expires, not after.** An expired Azure credit disables
> resources; it does not cancel a Microsoft 365 subscription, release a Power Platform
> environment, or stop a paid licence renewing.

## 1. The clocks

Dates are derived from the start date plus the documented term. **Confirm the paid ones in
the Microsoft 365 admin center before relying on them** — Microsoft is the source of truth
for a renewal date, this table is not.

| Thing | Started | Term | Lapses | What happens |
|---|---|---|---|---|
| **Azure $200 credit** | 2026-08-26 | 30 days | **~2026-09-25** | Resources disabled, not charged — the spending limit is ON. This is the estate's binding clock |
| Microsoft 365 E5 (`SPE_E5`) | 2026-08-26 | 30 days | ~2026-09-25 | Sign-ins fail. Purview labels already created **persist** |
| Fabric trial capacity | 2026-08-29 | 60 days | ~2026-10-28 | Workspace becomes unusable until reassigned to a paid capacity |
| Power Apps Premium trial | 2026-08-31 | 30 days | ~2026-09-30 | **Grants nothing this estate uses** — see § 4. Let it lapse |
| Power Apps Developer Plan | 2026-08-31 | perpetual | — | Environment auto-**disabled** after 30 days of *inactivity*. Touch it monthly or lose it |
| Copilot Studio agent | 2026-08-31 | none | — | Lives in the developer environment; dies with it |

**The Developer Plan is the one that surprises people.** It never expires, but the
environment is disabled after 30 days of no use — and the Copilot Studio agent, its
Dataverse solution and the Direct Line secrets go with it. If the demo sits idle for a
month, L8 needs rebuilding even though nothing "expired".

## 2. What `down.ps1` covers, and what it does not

| | Covered by `down.ps1` | Survives every teardown |
|---|---|---|
| Azure | the four demo RGs | subscription policy, budget, Defender plan, role assignments |
| Identity | — | **every Entra user, group, app registration and CA policy** |
| Purview | — | sensitivity labels and the label policy |
| Fabric | — | workspace, lakehouse, trial capacity |
| Power Platform | — | environment, Dataverse, Copilot Studio agent |
| Licences | — | every subscription and trial |

Tenant-level deletion is **G3** and lives in `infra/{entra,policy,purview}/teardown.ps1`,
which refuse to run unattended in CI without `-AllowAutomation`. That is by design: an
agent that can delete tenant objects it cannot recreate is demonstrating something nobody
wants to buy (CLAUDE.md hard rule 1).

## 3. Shutting down for good

In this order. Steps 1–2 stop spend; the rest release the tenant.

1. **`pwsh scripts/down.ps1`** — deletes the four demo RGs. Idle cost drops to near zero.
2. **Cancel every paid subscription** in the Microsoft 365 admin center
   (**Billing → Your products**). A trial that reaches term without being cancelled can
   convert to paid on the card that verified the account. *This is the step that costs
   money if skipped, and nothing in this repo can do it for you.*
3. **Delete the Power Platform environment** — Power Platform admin center →
   Environments. Takes the Dataverse database, the Copilot Studio agent and the Direct
   Line secrets with it.
4. **Release the Fabric capacity** — admin portal → Capacity settings. A trial capacity
   simply lapses, but delete the workspace first if the data is synthetic-but-noisy.
5. **Run the three G3 teardowns** with `-AllowAutomation` if you want the tenant clean:
   `infra/entra/teardown.ps1`, `infra/policy/teardown.ps1`, `infra/purview/teardown.ps1`.
6. **Remove the subscription-scoped leftovers** the RG teardown never sees: the NIST
   initiative assignment, the budget, and the Defender for Containers plan if L9 enabled
   it.

**If you deployed into a shared subscription against the README's advice**, step 6 is not
optional — the deny policies stay assigned and refuse everyone else's deployments.

## 4. Things that look like they cost money and do not

Every one of these was proposed, priced, and proved unnecessary on 2026-08-31. They are
listed because Copilot Studio's own UI steers toward all three.

| Offered | Priced at | Verdict |
|---|---|---|
| Copilot Studio prepaid Copilot Credit pack | $200/pack/month | Not needed. The **Copilot Studio authors** role grants authoring for $0 |
| Power Apps Premium (paid) | $20/user/month | Not needed. The **Developer Plan** gives a Dataverse environment for $0 |
| Power Platform pay-as-you-go meter | metered | Not needed for the demo, and **it is billed outside the Azure credit** — see below |

**If you ever do attach the PAYG meter, understand what it is not.** Power Platform is
licensed separately from Azure, and Azure's own documentation says such services *"can
incur separate charges even when your spending limit is set"*, naming Microsoft Entra ID
P1/P2 — structurally the same shape. So the $200 ceiling that makes this estate's budget
arithmetic work **would not cover it**. Treat attaching that meter as a **G2** with the
number stated, not as a configuration step.

## 5. Verifying the live state

Do not trust this page over the tenant. These read-only calls answer the questions above
against reality:

```bash
# Subscription offer, state and whether the spending limit is still on
az rest --method get --url "https://management.azure.com/subscriptions/<sub-id>?api-version=2022-12-01"

# Every licence in the tenant, with seats consumed
az rest --method get --url "https://graph.microsoft.com/v1.0/subscribedSkus"

# Fabric capacities, their SKU and state
az rest --method get --url "https://api.fabric.microsoft.com/v1/capacities" --resource "https://api.fabric.microsoft.com"

# Power Platform environments, their SKU, region and whether Dataverse is attached
#   token resource: https://service.powerapps.com/
#   GET https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-10-01

# Tenant Dataverse capacity — 0 MB means no purchased subscription, only trials
#   token resource: https://api.powerplatform.com/
#   GET https://api.powerplatform.com/licensing/tenantCapacity?api-version=2022-03-01-preview
```

The last one is worth knowing: `totalCapacity: 0.0` with `licenses: []` is what a
trial-only tenant looks like, and it is why a Production or Sandbox environment cannot be
created however many trials are active.
