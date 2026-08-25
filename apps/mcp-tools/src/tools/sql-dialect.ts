/**
 * SQL dialect: what `query_lakehouse_sql` ACCEPTS and what it ADVERTISES.
 *
 * ── The problem this module exists to solve ──────────────────────────────────
 * The local backend is SQLite (sql.js over Track A's CSVs). The cloud backend is
 * the **Microsoft Fabric lakehouse SQL analytics endpoint**, which speaks
 * **T-SQL**. Those dialects disagree on exactly the idioms the golden questions
 * need:
 *
 *   | need                | SQLite                       | T-SQL                          |
 *   |---------------------|------------------------------|--------------------------------|
 *   | day of week         | strftime('%w', d)  0=Sun..6  | DATEPART(weekday, d)  1..7     |
 *   | month bucket        | strftime('%Y-%m', d)         | FORMAT(d,'yyyy-MM')            |
 *   | row limit           | LIMIT n                      | SELECT TOP (n)                 |
 *   | integer division    | 1/2 = 0 (same)               | 1/2 = 0 (same)                 |
 *
 * `strftime` DOES NOT EXIST IN T-SQL. Until now the tool description told the
 * agent to use it unconditionally, which was correct against the local backend
 * and would have produced `Invalid object name 'strftime'` against every single
 * date question on the cloud backend — a latent break that only fires on the
 * day the tenant is switched on.
 *
 * ── The resolution ───────────────────────────────────────────────────────────
 * The dialect is a property of the ACTIVE BACKEND, and the tool description is
 * generated from it. `tools/list` therefore always advertises the idioms of the
 * engine the query will actually hit: SQLite idioms in `local` mode, T-SQL
 * idioms in `cloud` mode. The agent reads nothing but name + description +
 * schema, so this is the only channel that can carry the difference, and a
 * translation layer was rejected deliberately — silently rewriting an agent's
 * SQL would make its errors unattributable and its results unauditable, and the
 * L8 audit (V8.2) re-derives answers from SQL the repo can read.
 *
 * ── DATEFIRST, pinned ────────────────────────────────────────────────────────
 * T-SQL's `DATEPART(weekday, d)` is relative to the session's `DATEFIRST`, which
 * defaults from the login's language (us_english => 7 => Sunday is day 1) and is
 * therefore a *server configuration* the answer would otherwise depend on. A
 * demo whose canonical golden answer is "Saturday" cannot have its weekday
 * numbering decided by a login default. So the adapter pins `SET DATEFIRST 7`
 * in the session prologue of every batch, and the tool description states the
 * resulting mapping (1=Sunday .. 7=Saturday) as a guarantee. `SET` is refused
 * inside a user statement (see the keyword list below), so the agent cannot
 * unpin it.
 */

export type SqlDialect = "sqlite" | "tsql";

/** Row cap on tool results — unbounded SELECTs are an L8 latency failure mode. */
export const MAX_RESULT_ROWS = 500;

/**
 * `SET DATEFIRST 7` makes DATEPART(weekday, …) return 1=Sunday .. 7=Saturday
 * deterministically. `SET NOCOUNT ON` suppresses the row-count messages that
 * would otherwise arrive as extra TDS tokens ahead of the result set.
 *
 * This prologue is prepended by the adapter to the batch it sends; it is never
 * something the agent writes, and `SET` inside an agent statement is refused.
 */
export const TSQL_SESSION_PROLOGUE = "SET NOCOUNT ON;\nSET DATEFIRST 7;\n";

/** The weekday number `DATEPART(weekday, …)` yields for Saturday under DATEFIRST 7. */
export const TSQL_SATURDAY_WEEKDAY = 7;

/** The value `strftime('%w', …)` yields for Saturday in SQLite. */
export const SQLITE_SATURDAY_WEEKDAY = "6";

export interface DialectProfile {
  id: SqlDialect;
  /** Name used in the agent-facing description's opening clause. */
  displayName: string;
  /** The date/limit idiom paragraph spliced into the tool description. */
  idioms: string;
  /** A concrete example statement for the `sql` argument's own description. */
  example: string;
}

export const DIALECTS: Record<SqlDialect, DialectProfile> = {
  sqlite: {
    id: "sqlite",
    displayName: "SQLite dialect",
    idioms:
      "Dates are ISO 'YYYY-MM-DD' text: use strftime('%w', actual_date) for day of week " +
      "(0=Sunday .. 6=Saturday) and strftime('%Y-%m', date) to bucket by month. Use " +
      "LIMIT n to take the top n rows.",
    example: "SELECT COUNT(*) AS n FROM launches WHERE outcome = 'success'",
  },
  tsql: {
    id: "tsql",
    displayName: "T-SQL dialect, Microsoft Fabric lakehouse SQL analytics endpoint",
    idioms:
      "This is T-SQL, not SQLite: strftime, LIMIT and || do not exist here. Dates are DATE " +
      "columns. For day of week use DATEPART(weekday, actual_date) — the session pins " +
      "SET DATEFIRST 7, so the numbering is always 1=Sunday, 2=Monday .. 7=Saturday " +
      "regardless of server language; DATENAME(weekday, actual_date) gives the name " +
      "directly. To bucket by month use FORMAT(date, 'yyyy-MM') (or the cheaper " +
      "CONVERT(char(7), date, 126)). Use SELECT TOP (n) ... ORDER BY ... to take the top n " +
      "rows, and CONCAT(a, b) or + to join strings.",
    example: "SELECT COUNT(*) AS n FROM launches WHERE outcome = 'success'",
  },
};

/* ------------------------------------------------------------------ */
/* The read-only gate                                                  */
/* ------------------------------------------------------------------ */

/**
 * Keywords refused in every dialect. Word-boundary matched against a scrubbed
 * copy of the statement (comments and literals removed), so a value like
 * 'drop test' or a column named `data_dropout_s` cannot trip them.
 *
 * INTO is here because `SELECT … INTO t` is table creation, not a projection —
 * the one write path that hides inside an otherwise innocent SELECT.
 */
const FORBIDDEN_COMMON = [
  "insert", "update", "delete", "merge", "upsert",
  "drop", "create", "alter", "truncate", "rename",
  "grant", "revoke", "deny",
  "into",
  "exec", "execute",
  "backup", "restore",
];

/** Dialect-specific extras. */
const FORBIDDEN_BY_DIALECT: Record<SqlDialect, string[]> = {
  // SQLite: schema/file-level escapes and the extension loader.
  sqlite: ["pragma", "attach", "detach", "vacuum", "reindex", "analyze", "load_extension"],
  // T-SQL: batch/session control (SET would unpin DATEFIRST), the extended and
  // system procedure families, external data readers, and the blocking verbs.
  tsql: [
    "set", "use", "go", "dbcc", "kill", "shutdown", "reconfigure", "waitfor",
    "openrowset", "openquery", "opendatasource", "openjson", "bulk",
    "sp_", "xp_",
  ],
};

/**
 * Remove comments, string literals and quoted identifiers, replacing each with a
 * space so token boundaries survive. The result is structurally faithful but
 * contains no user text, which is what makes keyword and `;` scanning sound.
 */
export function scrubSql(sql: string): string {
  let out = "";
  let i = 0;
  const n = sql.length;
  while (i < n) {
    const ch = sql[i] as string;
    const next = sql[i + 1];

    // -- line comment
    if (ch === "-" && next === "-") {
      while (i < n && sql[i] !== "\n") i += 1;
      out += " ";
      continue;
    }
    // /* block comment */ (T-SQL nests these; SQLite does not — handle nesting,
    // which is the stricter reading and cannot under-scrub either dialect)
    if (ch === "/" && next === "*") {
      let depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (sql[i] === "/" && sql[i + 1] === "*") { depth += 1; i += 2; continue; }
        if (sql[i] === "*" && sql[i + 1] === "/") { depth -= 1; i += 2; continue; }
        i += 1;
      }
      out += " ";
      continue;
    }
    // 'string literal', '' escapes the quote
    if (ch === "'") {
      i += 1;
      while (i < n) {
        if (sql[i] === "'" && sql[i + 1] === "'") { i += 2; continue; }
        if (sql[i] === "'") { i += 1; break; }
        i += 1;
      }
      out += " '' ";
      continue;
    }
    // "quoted identifier" / [bracketed identifier] / `backticked identifier`
    if (ch === '"' || ch === "`") {
      const quote = ch;
      i += 1;
      while (i < n) {
        if (sql[i] === quote && sql[i + 1] === quote) { i += 2; continue; }
        if (sql[i] === quote) { i += 1; break; }
        i += 1;
      }
      out += " id ";
      continue;
    }
    if (ch === "[") {
      i += 1;
      while (i < n && sql[i] !== "]") i += 1;
      i += 1;
      out += " id ";
      continue;
    }
    out += ch;
    i += 1;
  }
  return out;
}

export class SqlRejected extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SqlRejected";
  }
}

/**
 * The single gate both backends run before any engine sees the text. Enforces,
 * identically in SQLite and T-SQL:
 *
 *   1. exactly ONE statement (a trailing `;` is allowed, a second statement is
 *      not — sql.js quietly runs only the first, but a TDS batch would run them
 *      all, so this check is what makes the two backends behave the same);
 *   2. it starts with SELECT or WITH;
 *   3. no DDL/DML/administrative keyword anywhere outside a string literal.
 *
 * Returns the statement with any trailing semicolon and whitespace removed.
 * Throws `SqlRejected`, whose message reaches the agent verbatim as an
 * `isError` result so it can rewrite the query itself.
 */
export function assertReadOnlySingleStatement(sql: unknown, dialect: SqlDialect): string {
  if (typeof sql !== "string" || sql.trim().length === 0) {
    throw new SqlRejected("query_lakehouse_sql requires a non-empty 'sql' string");
  }

  const scrubbed = scrubSql(sql);

  // (1) single statement. Scan the scrubbed text: any ';' with non-whitespace
  // after it means a second statement.
  const firstSemi = scrubbed.indexOf(";");
  if (firstSemi !== -1 && scrubbed.slice(firstSemi + 1).trim().length > 0) {
    throw new SqlRejected(
      "Only a single SQL statement is accepted — send one SELECT (or WITH … SELECT) per call. " +
        "Combine the parts with a CTE, a JOIN or a UNION ALL instead of separating them with ';'.",
    );
  }

  // (2) no write/administrative verb anywhere. Checked BEFORE the SELECT/WITH
  // test so the agent gets the specific, actionable message ("contains DELETE")
  // rather than the generic one — it is the message it has to act on.
  const forbidden = [...FORBIDDEN_COMMON, ...(FORBIDDEN_BY_DIALECT[dialect] ?? [])];
  for (const word of forbidden) {
    // sp_ / xp_ are prefixes, not words; everything else is word-bounded.
    const pattern = word.endsWith("_")
      ? new RegExp(`\\b${word}`, "i")
      : new RegExp(`\\b${word}\\b`, "i");
    if (pattern.test(scrubbed)) {
      throw new SqlRejected(
        `Only read-only SELECT/WITH statements are allowed — the statement contains ` +
          `"${word.toUpperCase()}", which this tool refuses. Rewrite it as a plain SELECT.`,
      );
    }
  }

  // (3) SELECT/WITH only. Checked on the scrubbed text so a leading comment
  // block cannot smuggle a different verb into first position.
  if (!/^\s*(select|with)\b/i.test(scrubbed)) {
    throw new SqlRejected(
      "Only read-only SELECT/WITH statements are allowed. This tool has read-only access to " +
        "the lakehouse; INSERT, UPDATE, DELETE, MERGE and every DDL statement are refused.",
    );
  }

  return sql.trim().replace(/;\s*$/, "").trimEnd();
}
