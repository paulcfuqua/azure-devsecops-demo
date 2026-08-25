import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  createOneLakeWriter,
  LakehouseWriteError,
  ONELAKE_DFS_ENDPOINT,
  ONELAKE_TOKEN_SCOPE,
  oneLakeFileUrl,
  partitionRelativePath,
} from "../src/lakehouse.ts";
import { readConfig, ConfigurationError, parseJsonRecord } from "../src/config.ts";

const TOKEN = "a-managed-identity-token";

/** Records every request; every response is OK unless a status is scripted. */
function stubFetch(statuses: number[] = []) {
  const calls: { url: string; init: RequestInit }[] = [];
  const impl = (async (url: string | URL | Request, init?: RequestInit) => {
    const index = calls.length;
    calls.push({ url: String(url), init: init ?? {} });
    const status = statuses[index] ?? 201;
    return { ok: status < 400, status } as Response;
  }) as unknown as typeof fetch & { calls: typeof calls };
  (impl as unknown as { calls: typeof calls }).calls = calls;
  return impl as typeof fetch & { calls: typeof calls };
}

function writerWith(fetchImpl: typeof fetch) {
  return createOneLakeWriter({
    workspace: "mls-operations",
    lakehouse: "mls_operations",
    getToken: async () => TOKEN,
    fetchImpl,
  });
}

describe("OneLake path construction", () => {
  it("puts a partition under Files/<base>/month=<key>/", () => {
    assert.equal(
      partitionRelativePath("cost_daily", "2026-08"),
      "cost_daily/month=2026-08/cost_daily.csv",
    );
    assert.equal(partitionRelativePath("/a/b/", "2026-08"), "a/b/month=2026-08/cost_daily.csv");
  });

  it("builds the documented OneLake DFS URL", () => {
    assert.equal(
      oneLakeFileUrl({
        endpoint: ONELAKE_DFS_ENDPOINT,
        workspace: "mls-operations",
        lakehouse: "mls_operations",
        relativePath: "cost_daily/month=2026-08/cost_daily.csv",
      }),
      "https://onelake.dfs.fabric.microsoft.com/mls-operations/mls_operations.Lakehouse/Files/" +
        "cost_daily/month%3D2026-08/cost_daily.csv",
    );
  });

  it("scopes tokens to the audience OneLake's ADLS surface accepts", () => {
    assert.equal(ONELAKE_TOKEN_SCOPE, "https://storage.azure.com/.default");
  });
});

describe("createOneLakeWriter", () => {
  it("performs the ADLS Gen2 create -> append -> flush sequence", async () => {
    const fetchImpl = stubFetch();
    const result = await writerWith(fetchImpl).replacePartition("2026-08", "a,b\n1,2\n");

    assert.equal(fetchImpl.calls.length, 3);
    assert.match(fetchImpl.calls[0].url, /\?resource=file$/);
    assert.equal(fetchImpl.calls[0].init.method, "PUT");
    assert.match(fetchImpl.calls[1].url, /\?action=append&position=0$/);
    assert.equal(fetchImpl.calls[1].init.method, "PATCH");
    assert.match(fetchImpl.calls[2].url, /\?action=flush&position=8$/);
    assert.equal(result.bytes, 8);
    assert.equal(result.path, "cost_daily/month=2026-08/cost_daily.csv");
  });

  it("creates rather than appends — an existing file is truncated, so a replay cannot duplicate", async () => {
    const fetchImpl = stubFetch();
    await writerWith(fetchImpl).replacePartition("2026-08", "x\n");
    // `?resource=file` is the truncating create. If this ever became
    // `?resource=file&mode=append` the idempotency claim would silently break.
    assert.equal(fetchImpl.calls.filter((call) => /resource=file$/.test(call.url)).length, 1);
    assert.equal(fetchImpl.calls.some((call) => /mode=append/.test(call.url)), false);
  });

  it("sends the managed-identity bearer token on every call and no other credential", async () => {
    const fetchImpl = stubFetch();
    await writerWith(fetchImpl).replacePartition("2026-08", "x\n");
    for (const call of fetchImpl.calls) {
      const headers = call.init.headers as Record<string, string>;
      assert.equal(headers.authorization, `Bearer ${TOKEN}`);
      // No SAS in the query string, no account key, no connection string.
      assert.equal(/sig=|sv=|AccountKey/.test(call.url), false);
    }
  });

  it("computes the flush position in BYTES, not characters", async () => {
    const fetchImpl = stubFetch();
    // "Cloud & IT" is ASCII, but a cost centre could carry a non-ASCII name and
    // a character-count flush would truncate the file.
    const result = await writerWith(fetchImpl).replacePartition("2026-08", "é\n");
    assert.equal(result.bytes, 3);
    assert.match(fetchImpl.calls[2].url, /position=3$/);
  });

  it("reports the failing stage and status when OneLake refuses", async () => {
    for (const [index, stage] of [[0, /create/], [1, /append/], [2, /flush/]] as const) {
      const statuses = [201, 202, 200];
      statuses[index] = 403;
      const fetchImpl = stubFetch(statuses);
      await assert.rejects(
        () => writerWith(fetchImpl).replacePartition("2026-08", "x\n"),
        (error: unknown) => {
          assert.ok(error instanceof LakehouseWriteError);
          assert.equal(error.status, 403);
          assert.match(error.message, stage);
          return true;
        },
      );
    }
  });
});

describe("readConfig", () => {
  const BASE = { FABRIC_WORKSPACE: "mls-operations", FABRIC_LAKEHOUSE: "mls_operations" };

  it("names every missing required setting at once", () => {
    assert.throws(
      () => readConfig({}),
      (error: unknown) => {
        assert.ok(error instanceof ConfigurationError);
        assert.match(error.message, /FABRIC_WORKSPACE, FABRIC_LAKEHOUSE/);
        return true;
      },
    );
  });

  it("applies documented defaults for the optional settings", () => {
    const config = readConfig(BASE);
    assert.equal(config.basePath, "cost_daily");
    assert.equal(config.endpoint, ONELAKE_DFS_ENDPOINT);
    assert.equal(config.ingest.fallbackCostCenter, "Unallocated");
    assert.equal(config.ingest.defaultCurrency, "USD");
  });

  it("parses the budget and resource-group maps, lower-casing group keys", () => {
    const config = readConfig({
      ...BASE,
      COST_CENTER_BUDGETS: '{"Propulsion": 8610, "Avionics": "5670"}',
      RESOURCE_GROUP_COST_CENTERS: '{"MLS-RG-Ops": "Cloud & IT"}',
    });
    assert.deepEqual(config.ingest.costCenterBudgets, { Propulsion: 8610, Avionics: 5670 });
    assert.deepEqual(config.ingest.resourceGroupCostCenters, { "mls-rg-ops": "Cloud & IT" });
  });

  it("fails loudly on a malformed JSON setting rather than losing every budget", () => {
    assert.throws(
      () => readConfig({ ...BASE, COST_CENTER_BUDGETS: "{not json}" }),
      (error: unknown) => error instanceof ConfigurationError && /not valid JSON/.test(error.message),
    );
    assert.throws(
      () => readConfig({ ...BASE, COST_CENTER_BUDGETS: '{"Propulsion": "lots"}' }),
      (error: unknown) => error instanceof ConfigurationError && /not a usable value/.test(error.message),
    );
  });

  it("treats an unset or blank JSON setting as an empty map", () => {
    assert.deepEqual(parseJsonRecord(undefined, "X", () => 1), {});
    assert.deepEqual(parseJsonRecord("   ", "X", () => 1), {});
  });

  it("holds no credential-shaped setting — managed identity has nothing to store", () => {
    const config = readConfig(BASE);
    const serialised = JSON.stringify(config).toLowerCase();
    for (const forbidden of ["secret", "password", "accountkey", "sastoken", "connectionstring"]) {
      assert.equal(serialised.includes(forbidden), false, `config leaked "${forbidden}"`);
    }
  });
});
