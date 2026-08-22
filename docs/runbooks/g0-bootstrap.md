# G0 Bootstrap Runbook (human-only)

Status as verified on 2026-08-22 from this machine. Agents never execute these steps;
where a step is scriptable, agents author the script and you run it. Items marked ⚠ are
**missing/unverified** and block the layer noted.

## A. Local toolchain (agents install these at Layer 0 — no action needed from you)

| Item | Status | Notes |
|---|---|---|
| Git 2.48 / Node 24 / Python 3.14 / winget | ✅ present | |
| GitHub CLI auth (`paulcfuqua`, scopes: repo, workflow, read:org, gist) | ✅ logged in | sufficient for repo create + Actions + GHAS on own repos |
| Azure CLI + Bicep | ⚠ not installed | agents install via winget at Layer 0 |
| PowerShell 7, Microsoft.Graph, ExchangeOnlineManagement modules | ⚠ not installed | agents install at Layer 0 |
| Agent Teams env (`.claude/settings.json`) | ✅ set | **restart the Claude Code session after G1 to activate** |

## B. Human-only checklist (do these, in order)

1. ⚠ **Azure tenant + subscription with billing.** Unverifiable from this machine (no CLI
   /login). Confirm you have a tenant where you are Global Administrator and a
   subscription with a payment method. After Layer 0 installs the CLI, run `az login`
   when prompted by the bootstrap script.
2. ⚠ **Run `scripts/bootstrap/01-root-oidc.ps1`** (authored at Layer 0, before any
   deploy). Under your login it will: create app registration `mls-github-deployer` with
   federated credentials for this repo's `main` branch + environments; grant Owner on the
   subscription; print the admin-consent URL for Graph application permissions
   (`User.ReadWrite.All`, `Group.ReadWrite.All`, `Application.ReadWrite.All`,
   `Policy.ReadWrite.ConditionalAccess`, `Directory.Read.All`) — you click consent; and
   create the read-only `mls-verifier` app (Reader + `Directory.Read.All`).
3. ⚠ **Licensing (spec F1):** in the Microsoft 365 admin center, activate an **EMS E5
   trial** (free) and assign it to your admin user + the 5 demo users once they exist.
   Covers Conditional Access (P1), sign-in risk (P2), and Purview Information Protection.
   If you decline, tell the Orchestrator so the degrade path from spec F1 is locked in.
4. ⚠ **Fabric F2 capacity:** run `scripts/bootstrap/02-fabric-capacity.ps1` (creates F2
   pay-as-you-go, paused, in the demo subscription), then in the Fabric admin portal
   enable **"Service principals can use Fabric APIs"** and add `mls-github-deployer` as
   capacity admin (~2 min, portal-only tenant toggle).
5. ⚠ **Anthropic API key** (pending the G1 LLM-provider decision): create a key at
   console.anthropic.com and store it once as the GitHub Actions secret
   `ANTHROPIC_API_KEY`. It is the only stored secret in the system (spec F4).
6. ⚠ **Budget guard:** run `scripts/bootstrap/03-budget.ps1` — creates a $75/month
   budget on the subscription with alerts at 50/80/100% to your email. This is the
   backstop behind gate G4's cost-anomaly trigger.

## C. What "G0 complete" means

The Orchestrator re-runs `scripts/bootstrap/verify-g0.ps1` (read-only) and gets: a
logged-in CLI context; `mls-github-deployer` with federation + Owner + consented Graph
permissions; `mls-verifier` present; Fabric capacity visible and SP API access on;
licenses assigned; budget in place. Only then does Layer 1 deploy.
