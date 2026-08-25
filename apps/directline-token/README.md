# `apps/directline-token` — the Direct Line token endpoint

One HTTP endpoint, one job: exchange the Copilot Studio **Direct Line secret**
for a **short-lived, conversation-scoped token**, server-side, so the control
tower's Ask tab never holds a credential.

```
browser (control tower, Ask tab)
   │  POST {tokenUrl}                          ← no credential of any kind
   ▼
apps/directline-token  (Azure Functions, anonymous HTTP trigger)
   │  DIRECTLINE_SECRET  ← Key Vault reference, never in this repo
   │  POST https://directline.botframework.com/v3/directline/tokens/generate
   │  Authorization: Bearer <secret>
   │  { "user": { "id": "dl_…" }, "trustedOrigins": ["https://…"] }
   ▼
Direct Line → { conversationId, token, expires_in: 1800 }
   │
   └─▶ browser receives { token, expires_in, conversationId, userId }
```

## Why this is a separate Function and not part of `apps/mcp-tools`

The amendment gives the agent two server-side companions and they sit on
opposite sides of a trust boundary:

| | `apps/mcp-tools` | `apps/directline-token` |
|---|---|---|
| Caller | the **Copilot Studio agent** (server-to-server, Streamable HTTP) | the **browser** |
| Ingress | internal to the Container Apps environment (`COPILOT_EXTERNAL_INGRESS=false`) | public, anonymous, CORS-scoped |
| Holds | lakehouse read credentials | the Direct Line secret |
| Changes when | a tool changes | the Direct Line channel changes |

Four reasons the split wins:

1. **Ingress.** Folding the token endpoint into the MCP service forces that
   service public. The tools server has no reason to be reachable from the
   internet, and giving it a public route to serve one unrelated endpoint is a
   strictly worse security posture.
2. **Blast radius.** After the amendment the Direct Line secret is the system's
   only stored secret. It should live in exactly one small component whose whole
   source is auditable in a single sitting — which this is.
3. **Cost and lifecycle.** A Consumption-plan Function is zero idle cost, which
   matches the amendment's "zero idle cost" posture, and it redeploys when the
   Direct Line channel rotates without touching the tool layer.
4. **Ownership.** `apps/mcp-tools` is another workstream's deliverable and is
   mid-rename from `apps/copilot-svc`. Adding an unrelated browser-facing route
   into it during that move would be a merge conflict looking for somewhere to
   happen.

## Why it is anonymous, and what actually protects it

The endpoint cannot authenticate its caller — it *is* the thing that holds the
credential, so there is nothing for an anonymous browser to present. Three
controls do the work instead:

- **`trustedOrigins`.** Direct Line embeds the allowed client domains *in the
  token*, so a token minted here is only usable from the control tower's own
  origin. Set `DIRECTLINE_ALLOWED_ORIGINS` and this is enforced by Direct Line
  itself, not just by us.
- **CORS allow-list.** The handler answers only allow-listed origins and
  refuses others with 403.
- **Blast radius of a leak.** A leaked *token* buys one conversation for
  ~30 minutes. A leaked *secret* buys the agent. That asymmetry is the whole
  point of the exchange.

## Configuration

Application settings, all written by L6 (never committed):

| Setting | Value |
|---|---|
| `DIRECTLINE_SECRET` | `@Microsoft.KeyVault(SecretUri=…)` → the Copilot Studio Direct Line secret |
| `DIRECTLINE_ALLOWED_ORIGINS` | comma-separated origins, e.g. the control tower's ACA FQDN |
| `DIRECTLINE_DOMAIN` | optional; `https://europe.directline.botframework.com` for a regional agent |

Obtain the secret in Copilot Studio: **Settings → Security → Web channel
security**, with *Require secured access* on. Copilot Studio keeps two live
secrets so you can rotate without downtime; note that toggling secured access
**can take up to two hours to propagate**.

If the agent is instead published with *No authentication*, Copilot Studio's
**Mobile app** channel exposes a token endpoint that needs no secret at all, and
this Function becomes unnecessary — point `VITE_DIRECTLINE_TOKEN_URL` straight
at it. The Function is the right answer for a secured agent, which is what the
demo's Entra-ID-throughout story calls for.

## Front-end wiring

The control tower reads one build variable:

```
VITE_DIRECTLINE_TOKEN_URL=https://<function-app>.azurewebsites.net/api/directline/token
```

With it unset the Ask tab renders its offline state (see
`apps/control-tower/src/AskPanel.tsx`). There is no `VITE_DIRECTLINE_SECRET`,
and there must never be: Vite inlines every `VITE_`-prefixed variable into the
shipped bundle as a string literal, so `resolveAgentConfig` treats any
secret-shaped build variable as a **hard stop** and forces the tab offline
rather than shipping a credential.

## Known limitation — Direct Line and the Fabric connected agent

When a Copilot Studio agent is combined with a **Fabric connected agent**, Teams
is the only *validated* channel; Direct Line is not on that list. The amendment's
L5 design attaches a Fabric data agent as the agent's knowledge source, so this
combination is exactly what the demo will run.

This is a platform limitation, not a defect in the embed. If answers degrade once
the Fabric knowledge source is attached, the channel is the first suspect, and
the amendment already carries the fallback: keep the Copilot Studio agent, drop
the Fabric knowledge source, and query the lakehouse SQL analytics endpoint
through the MCP server instead. The Direct Line surface and this token endpoint
are unaffected by that fallback.

## Local development and tests

```
cd apps/directline-token
npm install          # only needed for `func start`; the tests need nothing
npm test             # node --test — the pure exchange logic, 8 cases
func start           # requires Azure Functions Core Tools v4 + local.settings.json
```

`src/tokenExchange.mjs` is dependency-free with an injectable `fetch`, so the
security-relevant behaviour (bearer header, `dl_` user id, `trustedOrigins`,
allow-listed response fields, no upstream detail in errors) is tested without a
host. `src/functions/directline-token.mjs` is the thin Azure Functions binding
around it — the only file that needs `@azure/functions`.

This package is deliberately **outside** the repo-root `workspaces` list, for
the same reason `apps/vuln-lab` is: it deploys as its own app with its own
dependency closure, and hoisting a server SDK into the root tree would put it in
the browser apps' dependency graph.

## Sources

- [Configure web and Direct Line channel security — Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/configure-web-security)
- [Direct Line authentication — Azure AI Bot Service](https://learn.microsoft.com/en-us/azure/bot-service/rest-api/bot-framework-rest-direct-line-3-0-authentication)
- [Direct Line API 3.0 reference](https://learn.microsoft.com/en-us/azure/bot-service/rest-api/bot-framework-rest-direct-line-3-0-api-reference)
- [Publish an agent to mobile or custom apps](https://learn.microsoft.com/en-us/microsoft-copilot-studio/publication-connect-bot-to-custom-application)
