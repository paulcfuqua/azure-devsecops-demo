/**
 * Row normalization — the single place a backend's raw record becomes a row on
 * the wire.
 *
 * Both backends run through this, which is the point. The local backend reads
 * JSON (strings, numbers, nulls, no dates) and the cloud backend reads TDS
 * (JS `Date` objects, `bit` for booleans, `decimal` sometimes arriving as a
 * string). Without a shared normalizer the two modes would serve subtly
 * different JSON for the same table and the frontends would render differently
 * against the same data — the exact class of bug this service exists to avoid.
 *
 * Normalization also *projects*: the output has exactly the contract's fields,
 * in the contract's order, and nothing else. A column added upstream cannot
 * reach a browser without someone editing `allowlist.ts` first.
 */
import type { FieldSpec, TableName } from "./allowlist.js";
import { TABLE_FIELDS } from "./allowlist.js";
import type { TableRow } from "./rows.js";

export class RowShapeError extends Error {
  constructor(
    readonly table: TableName,
    readonly field: string,
    readonly reason: string,
  ) {
    super(`${table}.${field}: ${reason}`);
    this.name = "RowShapeError";
  }
}

/** ISO `YYYY-MM-DD`, the contract's date rendering. */
function toIsoDate(value: Date): string {
  return value.toISOString().slice(0, 10);
}

function coerce(
  table: TableName,
  spec: FieldSpec,
  raw: unknown,
): string | number | boolean | null {
  if (raw === null || raw === undefined) {
    if (spec.nullable) return null;
    throw new RowShapeError(table, spec.name, "is not nullable but arrived null");
  }

  switch (spec.type) {
    case "string": {
      if (typeof raw === "string") {
        // A TDS `date` column can also surface as an ISO datetime string.
        return spec.date === true && raw.length > 10 && raw[10] === "T"
          ? raw.slice(0, 10)
          : raw;
      }
      if (raw instanceof Date) {
        if (Number.isNaN(raw.getTime())) {
          throw new RowShapeError(table, spec.name, "is an invalid Date");
        }
        return spec.date === true ? toIsoDate(raw) : raw.toISOString();
      }
      if (typeof raw === "number" || typeof raw === "boolean") return String(raw);
      throw new RowShapeError(table, spec.name, `expected string, got ${typeName(raw)}`);
    }
    case "number": {
      if (typeof raw === "number") {
        if (!Number.isFinite(raw)) {
          throw new RowShapeError(table, spec.name, "is a non-finite number");
        }
        return raw;
      }
      // T-SQL decimal/money frequently arrive as strings from a TDS driver.
      if (typeof raw === "string" && raw.trim() !== "") {
        const parsed = Number(raw);
        if (Number.isFinite(parsed)) return parsed;
      }
      if (typeof raw === "bigint") return Number(raw);
      throw new RowShapeError(table, spec.name, `expected number, got ${typeName(raw)}`);
    }
    case "boolean": {
      if (typeof raw === "boolean") return raw;
      // `bit` columns come back as 0/1 through some drivers and settings.
      if (raw === 0 || raw === 1) return raw === 1;
      if (raw === "0" || raw === "1") return raw === "1";
      if (raw === "true" || raw === "false") return raw === "true";
      throw new RowShapeError(table, spec.name, `expected boolean, got ${typeName(raw)}`);
    }
  }
}

function typeName(value: unknown): string {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  if (value instanceof Date) return "Date";
  return typeof value;
}

/** Coerce and project one raw record to its contract row. */
export function normalizeRow(table: TableName, raw: unknown): TableRow {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new RowShapeError(table, "<row>", `expected an object, got ${typeName(raw)}`);
  }
  const source = raw as Record<string, unknown>;
  const out: Record<string, string | number | boolean | null> = {};
  for (const spec of TABLE_FIELDS[table]) {
    out[spec.name] = coerce(table, spec, source[spec.name]);
  }
  return out as unknown as TableRow;
}

/** Coerce and project a whole result set. */
export function normalizeRows(table: TableName, raw: readonly unknown[]): TableRow[] {
  return raw.map((row) => normalizeRow(table, row));
}
