/**
 * LOCAL backends — the test harness.
 *
 * Per the 2026-08-24 sponsor directive the demo runs on the tenant, so this
 * mode is not a deliverable: it exists so the route contract, the allowlists,
 * the caps and the error shapes can be proven on a laptop and in CI with no
 * tenant and no credentials. It reads exactly what the frontends read in
 * LOCAL_DATA mode — Track A's `data/generated/*.json` for tables, and
 * committed fixtures shaped like the real upstreams for feeds — so a spec
 * built from this API and a spec built from the app's own local provider are
 * built from identical bytes.
 */
import fs from "node:fs";
import path from "node:path";
import type { FeedName, TableName } from "../contract/allowlist.js";
import { FEED_FIXTURE } from "../contract/allowlist.js";
import type { FeedPayload } from "../contract/feeds.js";
import { normalizeRows } from "../contract/normalize.js";
import { ApiError } from "../errors.js";
import type { BackendKind, FeedsBackend, TableResult, TablesBackend } from "./types.js";

export class LocalTablesBackend implements TablesBackend {
  readonly kind: BackendKind = "local";

  /** Parsed generator output, kept per table: it is immutable build output. */
  private readonly cache = new Map<TableName, unknown[]>();

  constructor(private readonly generatedDataDir: string) {}

  async getTable(table: TableName, limit: number): Promise<TableResult> {
    const all = this.load(table);
    const truncated = all.length > limit;
    return {
      rows: normalizeRows(table, truncated ? all.slice(0, limit) : all),
      truncated,
    };
  }

  private load(table: TableName): unknown[] {
    const cached = this.cache.get(table);
    if (cached) return cached;

    // `table` is an allowlist literal, so this join cannot escape the data
    // directory no matter what the caller sent.
    const file = path.join(this.generatedDataDir, `${table}.json`);
    let text: string;
    try {
      text = fs.readFileSync(file, "utf-8");
    } catch (err) {
      throw ApiError.notConfigured(
        `The generated table "${table}" is missing from the local data directory. ` +
          "Run `python -m generators build` from data/ (LOCAL mode reads generator output, which is gitignored)",
        err,
      );
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      throw ApiError.internal(err);
    }
    if (!Array.isArray(parsed)) {
      throw ApiError.internal(`${table}.json does not contain a JSON array`);
    }

    this.cache.set(table, parsed);
    return parsed;
  }
}

export class LocalFeedsBackend implements FeedsBackend {
  readonly kind: BackendKind = "local";

  private readonly cache = new Map<FeedName, FeedPayload>();

  constructor(private readonly fixturesDir: string) {}

  async getFeed(name: FeedName): Promise<FeedPayload> {
    const cached = this.cache.get(name);
    if (cached) return cached;

    // Fixture filename comes from a constant keyed by the allowlist literal.
    const file = path.join(this.fixturesDir, FEED_FIXTURE[name]);
    let parsed: FeedPayload;
    try {
      parsed = JSON.parse(fs.readFileSync(file, "utf-8")) as FeedPayload;
    } catch (err) {
      throw ApiError.internal(err);
    }

    this.cache.set(name, parsed);
    return parsed;
  }
}
