/**
 * The backend seam — one interface pair, two implementations, chosen once at
 * boot from `MLS_DATA_BACKENDS` and never re-checked per request.
 *
 * This mirrors `apps/mcp-tools/src/tools/backends.ts` on purpose: same shape of
 * decision, same env-var-selected adapter set, same rule that the surface above
 * the seam (there: the MCP tool schemas; here: the HTTP routes) is identical in
 * both modes. The two packages implement it independently — nothing is imported
 * across them — but a reader who knows one knows the other.
 */
import type { FeedName, TableName } from "../contract/allowlist.js";
import type { FeedPayload } from "../contract/feeds.js";
import type { TableRow } from "../contract/rows.js";

export type BackendKind = "local" | "cloud";

export interface TableResult {
  readonly rows: TableRow[];
  /** True when the row cap cut the result short. Surfaced as a response header. */
  readonly truncated: boolean;
}

export interface TablesBackend {
  readonly kind: BackendKind;
  /**
   * @param table one of the ten allowlisted literals — never a caller string.
   * @param limit already clamped to the configured cap by the route.
   */
  getTable(table: TableName, limit: number): Promise<TableResult>;
}

export interface FeedsBackend {
  readonly kind: BackendKind;
  /** @param name one of the six allowlisted literals — never a caller string. */
  getFeed(name: FeedName): Promise<FeedPayload>;
}

export interface Backends {
  readonly kind: BackendKind;
  readonly tables: TablesBackend;
  readonly feeds: FeedsBackend;
  /**
   * Non-secret facts about where data is coming from, echoed on /healthz so an
   * operator can tell a misconfigured instance from a broken one without a
   * shell. Values here are hostnames and repo slugs — never credentials.
   */
  readonly describe: () => Record<string, string>;
  close(): Promise<void>;
}
