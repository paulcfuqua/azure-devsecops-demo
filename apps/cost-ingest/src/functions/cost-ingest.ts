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
//     `CostExports__credential=managedidentity` (plus `__clientId` for a
//     user-assigned identity). There is no `AzureWebJobsStorage` connection
//     string for this container and no SAS anywhere.
//   * The WRITE uses DefaultAzureCredential -> the same managed identity, with
//     a token scoped to https://storage.azure.com/.default, which is the
//     audience OneLake's ADLS Gen2 surface accepts.
//
//   RBAC the identity needs, granted by L6's Bicep:
//     Storage Blob Data Reader on the cost-export storage account
//     Contributor on the Fabric workspace `mls-operations` (OneLake write)
//
// APP SETTINGS (all placed by L6; none is a secret — see ../config.ts):
//   FABRIC_WORKSPACE            e.g. mls-operations
//   FABRIC_LAKEHOUSE            e.g. mls_operations
//   LAKEHOUSE_COST_PATH         optional; default `cost_daily`
//   ONELAKE_ENDPOINT            optional; sovereign-cloud override
//   COST_CENTER_BUDGETS         optional JSON: {"Propulsion": 8610, ...}
//   RESOURCE_GROUP_COST_CENTERS optional JSON: {"mls-rg-ops": "Cloud & IT", ...}
//   FALLBACK_COST_CENTER        optional; default `Unallocated`
//   COST_EXPORT_CONTAINER       optional; default `costexports`
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
        "Confirm a system-assigned identity is enabled and holds Contributor on the Fabric workspace.",
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
  path: `${process.env.COST_EXPORT_CONTAINER || "costexports"}/{name}`,
  connection: "CostExports",
  handler: costIngest,
});
