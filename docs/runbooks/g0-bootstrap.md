# G0 Bootstrap Runbook (human-only)

Status as verified on 2026-08-22 from this machine. Agents never execute these steps;
where a step is scriptable, agents author the script and you run it. Items marked ⚠ are
**missing/unverified** and block the layer noted.

> **2026-08-22 amendment (sponsor decision):** tenant activation is deliberately
> deferred. Phase P (pre-tenant scaffold, see
> `docs/superpowers/plans/2026-08-22-phase-p-pre-tenant-scaffold.md`) proceeds now;
> this runbook executes when you are ready to switch the tenant on. The trial-rate
> strategy below is designed so the entire demo window can run at ~$0 licensing cost.

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
| Fabric capacity | **Fabric 60-day free trial capacity** (enable "Users can try Microsoft Fabric" tenant setting, start trial as your admin user) | 60 days | Replaces paying for F2 during bring-up. Capacity ID is a config variable — moving to paid F2 later is one variable + G2 |
| Everything GitHub | Public repo | indefinite | Actions minutes, CodeQL, Dependabot, secret scanning all free |

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
5. ⚠ **Anthropic API key** (decision locked 2026-08-22): create a key at
   console.anthropic.com, store once as GitHub Actions secret `ANTHROPIC_API_KEY`. The
   only stored secret in the system (spec F4). Providing it *before* tenant activation
   also unlocks live local copilot testing in Phase P.
6. ⚠ **Budget guard:** run `scripts/bootstrap/03-budget.ps1` — $75/month budget with
   alerts at 50/80/100% to your email. Backstop behind gate G4's cost-anomaly trigger.

## D. What "G0 complete" means

The Orchestrator re-runs `scripts/bootstrap/verify-g0.ps1` (read-only) and gets: a
logged-in CLI context; `mls-github-deployer` with federation + Owner + consented Graph
permissions; `mls-verifier` present; Fabric capacity visible with SP API access on;
trial licenses assigned; budget in place. Only then does Layer 1 deploy.
