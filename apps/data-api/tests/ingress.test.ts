/**
 * F1: data-api ran with `ingressExternal: true` and, by its own comment
 * (src/app.ts:56), "deliberately no Authorization here". Behind it a managed
 * identity reads Azure SQL, the Fabric lakehouse, Log Analytics, Defender
 * secure score and GitHub security alerts. Both frontends already proxy
 * `/api/*` server-side through nginx, so the only legitimate callers live
 * inside the Container Apps environment — internal ingress closes the
 * exposure without a token to distribute, rotate or leak from a bundle.
 *
 * This test reads the deployed shape directly out of the Bicep template
 * rather than asserting behaviour of the (network-agnostic) Express app,
 * because ingress is an Azure Container Apps platform concern, not
 * something this process can observe about itself.
 */
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("data-api is not exposed to the public internet", () => {
  it("dataApiApp sets ingressExternal: false", () => {
    const bicep = readFileSync("../../infra/bicep/apps/main.bicep", "utf8");
    const block = bicep.slice(
      bicep.indexOf("module dataApiApp"),
      bicep.indexOf("module launchOpsApp"),
    );
    expect(block).toMatch(/ingressExternal:\s*false/);
  });
});
