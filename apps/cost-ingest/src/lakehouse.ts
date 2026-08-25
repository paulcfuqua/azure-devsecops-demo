// =============================================================================
// The lakehouse write path — OneLake, over the ADLS Gen2 (DFS) REST API,
// authenticated by managed identity only.
//
// WHY THIS API AND NOT A SQL WRITE. The Fabric lakehouse SQL analytics endpoint
// is read-only; you cannot INSERT into `cost_daily` through it. OneLake speaks
// the ADLS Gen2 DFS API at https://onelake.dfs.fabric.microsoft.com, so a
// Function with a managed identity that holds Contributor on the workspace can
// write files into the lakehouse directly. That is the supported write path for
// a small, dependency-light producer like this one.
//
// WHAT IT WRITES, AND WHERE THE DELTA TABLE COMES FROM.
//   <workspace>/<lakehouse>.Lakehouse/Files/cost_daily/month=YYYY-MM/cost_daily.csv
// one file per billing month, in the lakehouse's managed Files area. The
// `cost_daily` Delta table is defined over that folder by the L5 loader (the
// same loader that lands the generator's seed rows), so the Function owns the
// data and the lakehouse owns the table definition. Splitting it that way keeps
// a Delta writer — and Spark — out of a consumption-plan Function.
//
// WHY A WHOLE-MONTH FILE IS THE IDEMPOTENCY UNIT. A Cost Management daily
// export with timeframe MonthToDate re-emits the ENTIRE month every single day,
// with earlier days RESTATED as amortisation and credits settle. So:
//   * appending would duplicate every earlier day, once per day of the month;
//   * upserting by (date, cost_center) would keep rows that a restatement
//     removed entirely.
// Replacing the month wholesale is the only operation that matches the source's
// own semantics. `PUT ?resource=file` on an existing path truncates it, so the
// replace is one atomic-enough create — there is no delete-then-write window in
// which the month is missing.
//
// AUTH. `getToken` is injected. In the Function host it is
// DefaultAzureCredential (system-assigned managed identity) scoped to
// https://storage.azure.com/.default, which is the audience OneLake's DFS
// endpoint accepts. No key, no SAS, no connection string — CLAUDE.md hard
// rule 5, and there is nowhere in this module for a credential to be stored.
//
// Docs: Azure Data Lake Storage Gen2 REST — Path::Create / Path::Update.
// =============================================================================

/** The default OneLake DFS endpoint. Sovereign clouds differ. */
export const ONELAKE_DFS_ENDPOINT = "https://onelake.dfs.fabric.microsoft.com";

/** Audience OneLake accepts for its ADLS Gen2 surface. */
export const ONELAKE_TOKEN_SCOPE = "https://storage.azure.com/.default";

export class LakehouseWriteError extends Error {
  readonly status: number | undefined;

  constructor(message: string, status?: number) {
    super(message);
    this.name = "LakehouseWriteError";
    this.status = status;
  }
}

export type OneLakeWriterOptions = {
  /** Fabric workspace name or id, e.g. `mls-operations`. */
  readonly workspace: string;
  /** Lakehouse name WITHOUT the `.Lakehouse` suffix, e.g. `mls_operations`. */
  readonly lakehouse: string;
  /** Folder under Files/ that the `cost_daily` table is defined over. */
  readonly basePath?: string;
  /** Injectable bearer-token source. Managed identity in the Function host. */
  readonly getToken: () => Promise<string>;
  /** Injectable fetch, so every test in this app runs with zero cloud calls. */
  readonly fetchImpl?: typeof fetch;
  /** Override for sovereign clouds / test doubles. */
  readonly endpoint?: string;
};

/** What a writer must do. Kept as a type so ingest.ts can be tested with a stub. */
export type PartitionWriter = {
  /** Replaces one partition's contents wholesale. Never appends. */
  replacePartition(partitionKey: string, content: string): Promise<{ path: string; bytes: number }>;
};

/** `2026-08` -> `cost_daily/month=2026-08/cost_daily.csv`. */
export function partitionRelativePath(basePath: string, partitionKey: string): string {
  const clean = basePath.replace(/^\/+|\/+$/g, "");
  return `${clean}/month=${partitionKey}/cost_daily.csv`;
}

/**
 * Builds the full DFS path for a partition file.
 * `<endpoint>/<workspace>/<lakehouse>.Lakehouse/Files/<relative>`
 */
export function oneLakeFileUrl(options: {
  endpoint: string;
  workspace: string;
  lakehouse: string;
  relativePath: string;
}): string {
  const endpoint = options.endpoint.replace(/\/+$/, "");
  const segments = [
    encodeURIComponent(options.workspace),
    encodeURIComponent(`${options.lakehouse}.Lakehouse`),
    "Files",
    ...options.relativePath.split("/").map(encodeURIComponent),
  ];
  return `${endpoint}/${segments.join("/")}`;
}

/**
 * Creates a OneLake partition writer.
 *
 * The DFS three-step write (create -> append -> flush) is what the ADLS Gen2
 * API requires for a file upload; `?resource=file` on an existing path
 * truncates it, which is precisely the replace semantics this pipeline needs.
 */
export function createOneLakeWriter(options: OneLakeWriterOptions): PartitionWriter {
  const doFetch = options.fetchImpl ?? globalThis.fetch;
  const endpoint = options.endpoint ?? ONELAKE_DFS_ENDPOINT;
  const basePath = options.basePath ?? "cost_daily";

  async function call(
    url: string,
    init: { method: string; token: string; body?: string; contentType?: string },
  ): Promise<Response> {
    const headers: Record<string, string> = {
      authorization: `Bearer ${init.token}`,
      "x-ms-version": "2023-11-03",
    };
    if (init.contentType) headers["content-type"] = init.contentType;
    const response = await doFetch(url, {
      method: init.method,
      headers,
      body: init.body,
    });
    return response;
  }

  return {
    async replacePartition(partitionKey, content) {
      const relativePath = partitionRelativePath(basePath, partitionKey);
      const url = oneLakeFileUrl({
        endpoint,
        workspace: options.workspace,
        lakehouse: options.lakehouse,
        relativePath,
      });
      const token = await options.getToken();
      const bytes = Buffer.byteLength(content, "utf8");

      // 1. Create (truncating any existing file) — this IS the replace.
      const created = await call(`${url}?resource=file`, { method: "PUT", token });
      if (!created.ok) {
        throw new LakehouseWriteError(
          `OneLake refused to create ${relativePath} (${created.status}).`,
          created.status,
        );
      }

      // A month with no rows is never written (ingest.ts refuses first), so an
      // empty body here would be a bug rather than a legitimate state.
      const appended = await call(`${url}?action=append&position=0`, {
        method: "PATCH",
        token,
        body: content,
        contentType: "application/octet-stream",
      });
      if (!appended.ok) {
        throw new LakehouseWriteError(
          `OneLake refused the append to ${relativePath} (${appended.status}).`,
          appended.status,
        );
      }

      // 3. Flush commits the appended bytes; without it the file stays empty.
      const flushed = await call(`${url}?action=flush&position=${bytes}`, {
        method: "PATCH",
        token,
      });
      if (!flushed.ok) {
        throw new LakehouseWriteError(
          `OneLake refused the flush of ${relativePath} (${flushed.status}).`,
          flushed.status,
        );
      }

      return { path: relativePath, bytes };
    },
  };
}
