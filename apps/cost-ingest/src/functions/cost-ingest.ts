// =============================================================================
// Blob trigger: a new Cost Management export lands -> `cost_daily` is updated.
//
// This is the only host-aware file in the app. It does three things and nothing
// else: read settings, mint a managed-identity token, hand the blob to
// ingestExport(). All of the logic it drives is in ../ingest.ts and is unit
// tested with no cloud contact.
//
// AUTHENTICATION — MANAGED IDENTITY EVERYWHERE, NO STORED CREDENTIAL.
//
//   * The TRIGGER uses an identity-based connection. `connection: "CostExports"`
//     resolves the app settings `CostExports__blobServiceUri` and
//     `CostExports__credential=managedidentity` (plus `__clientId`, which L6
//     sets, because the identity is USER-assigned). There is no
//     `AzureWebJobsStorage` connection string for this container and no SAS
//     anywhere — the host's own storage connection is identity-based too.
//   * The WRITE uses DefaultAzureCredential -> the same managed identity (L6
//     sets AZURE_CLIENT_ID so it binds to that one and not to an ambient one),
//     with a token scoped to https://storage.azure.com/.default, which is the
//     audience OneLake's ADLS Gen2 surface accepts.
//
//   RBAC the identity needs, granted by L6's Bicep (F19 provisioned the app and
//   the identity; before that none of this could exist — infra/bicep/platform/
//   main.bicep, "cost-ingest FinOps leg"):
//     Storage Blob Data Reader on the cost-export CONTAINER, not the account
//     Contributor on the Fabric workspace (OneLake write — the least Fabric
//       role that can write under Files/; see infra/fabric/provision-workspace.ps1)
//
// APP SETTINGS (all placed by L6; none is a secret — see ../config.ts):
//   FABRIC_WORKSPACE            e.g. mls-operations
//   FABRIC_LAKEHOUSE            e.g. mls_operations
//   LAKEHOUSE_COST_PATH         optional; default `cost_daily`
//   ONELAKE_ENDPOINT            optional; sovereign-cloud override
//   COST_CENTER_BUDGETS         optional JSON: {"Propulsion": 8610, ...}
//   RESOURCE_GROUP_COST_CENTERS optional JSON: {"mls-rg-ops": "Cloud & IT", ...}
//   FALLBACK_COST_CENTER        optional; default `Unallocated`
//   COST_EXPORT_CONTAINER       optional; default `cost-exports`
//
// TOLERATING A PAUSED CAPACITY (L06 failure mode 5). OneLake storage operations
// do not need the Fabric capacity resumed, but a throttled or unreachable
// workspace still fails the write. When that happens this handler RETHROWS, so
// the Functions host retries the invocation and, after the retry budget, moves
// the blob's receipt to the poison queue — which is the platform's own
// "queue and retry until the next window" and is preferable to inventing a
// bespoke retry loop inside a consumption-plan Function.
// =============================================================================

import { app, type InvocationContext } from "@azure/functions";
import { DefaultAzureCredential } from "@azure/identity";
import { readConfig } from "../config.ts";
import { ingestExport } from "../ingest.ts";
import { createOneLakeWriter, ONELAKE_TOKEN_SCOPE } from "../lakehouse.ts";

const credential = new DefaultAzureCredential();

async function getManagedIdentityToken(): Promise<string> {
  const token = await credential.getToken(ONELAKE_TOKEN_SCOPE);
  if (!token || !token.token) {
    throw new Error(
      "The function app's managed identity returned no token for OneLake. " +
        "Confirm AZURE_CLIENT_ID names the user-assigned identity L6 created for " +
        "this Function and that it holds Contributor on the Fabric workspace.",
    );
  }
  return token.token;
}

/** Decodes the trigger payload, which arrives as a Buffer for a CSV blob. */
function asText(blob: unknown): string {
  if (typeof blob === "string") return blob;
  if (Buffer.isBuffer(blob)) return blob.toString("utf8");
  if (blob instanceof Uint8Array) return Buffer.from(blob).toString("utf8");
  return String(blob ?? "");
}

export async function costIngest(blob: unknown, context: InvocationContext): Promise<void> {
  const blobName = String(context.triggerMetadata?.name ?? context.triggerMetadata?.blobTrigger ?? "");
  const config = readConfig(process.env);

  const writer = createOneLakeWriter({
    workspace: config.workspace,
    lakehouse: config.lakehouse,
    basePath: config.basePath,
    endpoint: config.endpoint,
    getToken: getManagedIdentityToken,
  });

  const outcome = await ingestExport({
    blobName,
    content: asText(blob),
    writer,
    config: config.ingest,
  });

  if (outcome.skipped) {
    context.log(`cost-ingest skipped ${blobName}: ${outcome.reason}`);
    return;
  }

  if (outcome.rowsRejected > 0 || outcome.raggedLines > 0) {
    // Rejections are ordinary messiness, but a silent rise in them is how a
    // schema change first shows itself. Warn, do not fail.
    context.warn(
      `cost-ingest ${blobName}: ${outcome.rowsRejected} row(s) rejected, ` +
        `${outcome.raggedLines} ragged line(s) dropped. ` +
        `Resolved columns: ${JSON.stringify(outcome.resolvedColumns)}.`,
    );
  }

  for (const partition of outcome.partitions) {
    context.log(
      `cost-ingest wrote ${partition.rows} cost_daily row(s) for ${partition.month} to ${partition.path}.`,
    );
  }
}

app.storageBlob("cost-ingest", {
  // The container L6 points the Cost Management daily export at. `{name}` binds
  // the blob path so the handler can log and filter on it.
  //
  // The fallback is `cost-exports`, HYPHENATED. It used to read `costexports`,
  // which is a container that does not exist anywhere in this estate: L6's Bicep
  // creates `cost-exports` (infra/bicep/platform/main.bicep), the export
  // definition writes to `cost-exports`, and the L6 audit's V6.3 asserts
  // `cost-exports`. The same one-hyphen mismatch was already found and fixed once
  // on the export side (F15, Task 17). L6 sets COST_EXPORT_CONTAINER explicitly
  // so the fallback is never reached in this estate — but a fallback that names a
  // container nobody creates is a trigger that silently never fires, which is the
  // worst failure this app can have.
  path: `${process.env.COST_EXPORT_CONTAINER || "cost-exports"}/{name}`,
  connection: "CostExports",
  // EVENT GRID, NOT POLLING — and not an optimisation. The Function runs on a
  // Flex Consumption plan (see infra/bicep/platform/main.bicep for why that plan
  // and no other), and Flex Consumption supports ONLY the event-based blob
  // trigger: "the Flex Consumption plan supports only the event-based Blob
  // storage trigger"
  // (learn.microsoft.com/azure/azure-functions/functions-bindings-storage-blob-trigger).
  // The event subscription that feeds it is created by
  // .github/workflows/layer-06-platform.yml against the Event Grid system topic
  // L6's Bicep declares on the cost-export storage account.
  //
  // It also removes this app's need for any write access to the export account:
  // the polling trigger keeps blob receipts and a poison queue in its own
  // AzureWebJobsStorage account, and the Event Grid source keeps neither, so the
  // grant on the export container stays a pure READ (F13's seventh grant).
  source: "EventGrid",
  handler: costIngest,
});
