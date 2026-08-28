/**
 * query_compliance backend — answers from Task 8's committed state artifact
 * (compliance/state/state-latest.json), the exact same file the compliance
 * board (apps/compliance) renders. One source of truth: this module does not
 * recompute a single status, count or recommendation, it only reads, filters
 * and reshapes what the emitter already derived. Read-only, offline, no
 * tenant — no network call is reachable from anywhere in this file.
 *
 * ── Why the types are duplicated here instead of imported from apps/compliance ──
 * apps/compliance/src/types.ts is the identical data contract, but importing it
 * would reach outside this package's Docker build context (the Dockerfile only
 * COPYs apps/mcp-tools/src) and would couple two independently-deployed images
 * by a source import rather than by the shape they both agree to render — the
 * same reasoning backends.ts already applies to the cloud-vs-local adapter
 * shapes. tests/compliance-tool.test.ts imports the REAL committed artifact
 * directly, so a shape drift between the two copies fails a test rather than
 * surfacing at runtime.
 *
 * ── The honesty rules this module exists to enforce ──────────────────────────
 * A board makes a reader do the work of misreading it; a conversational tool
 * will happily state a falsehood in a sentence. So every rule below is
 * mechanical, not a matter of prompt discipline:
 *
 *   1. NO BLENDED PERCENTAGE. Nothing in this module computes a ratio, a
 *      score or a "%". `summary` is passed through from the artifact
 *      unmodified — counts only, exactly as compliance/README.md requires.
 *   2. `evidence`/`supportingEvidence` are exposed as counts BY STATUS AND
 *      PROVENANCE (`byProvenanceAndStatus`), never a bare `byProvenance`
 *      total: `machine-verified` includes a criterion a machine explicitly
 *      declined to run. Only `status === "COMPLIANT"` means verified-and-
 *      passing.
 *   3. The register's `CLOSED` is rendered as derived status `PARTIAL` by the
 *      emitter (compliance/lib/MlsCompliance.psm1) — this module reads that
 *      already-derived `status` field and never re-derives or "upgrades" it.
 *      `registerStatus` (the raw authored word) is exposed alongside `status`
 *      so a caller can see both, but `registerStatus` is never substituted
 *      for `status`.
 *   4. `outOfCatalogControls` (CM-6, CP-9, IR-4, SI-4) are matched ONLY by
 *      their own id/family/framework/status — never by
 *      `requirementsMappingToThisControl`. Querying control "3.8.9" walks
 *      `state.controls` only; it can never come back with CP-9's status,
 *      because the two arrays are filtered independently and never merged.
 *   5. `duplicatesStatusBasis: true` records (the `manual` collector's
 *      verbatim transcription of the assertion `statusBasis` already shows)
 *      are filtered out of both `evidence` and `supportingEvidence` before
 *      they reach the answer — the same filter, and the same reasoning,
 *      apps/compliance/src/ControlDetail.tsx already applies on the board.
 *   6. A missing or malformed artifact throws (AdapterError), which the MCP
 *      layer turns into an `isError` tool result — never an empty `controls:
 *      []` that a reader could mistake for "assessed, and there's nothing to
 *      report."
 */
import fs from "node:fs";
import { complianceStatePath } from "../config.js";
import { AdapterError } from "./errors.js";

/* ------------------------------------------------------------------ */
/* The state artifact's shape (compliance/README.md, spec §3.3)        */
/* ------------------------------------------------------------------ */

export type ControlStatus =
  | "COMPLIANT"
  | "PARTIAL"
  | "GAP"
  | "INCONCLUSIVE"
  | "NOT_APPLICABLE"
  | "NOT_ASSESSED";

/** `machine-verified` includes a criterion a machine explicitly declined to
 * run — it does not mean passing. `COMPLIANT` is the only status that does. */
export type Provenance = "machine-verified" | "asserted" | "declared" | "none";

export type StatusCounts = Record<ControlStatus, number>;
export type ProvenanceCounts = Record<Provenance, number>;
export type ControlMappings = Record<string, string[]>;

export interface EvidenceRecord {
  source: string;
  criterion: string | null;
  status: string;
  observed: string;
  artifact: string | null;
  collectedAt: string | null;
  participatedInStatus: boolean;
  duplicatesStatusBasis?: boolean;
}

export interface StatusBasisRecord {
  kind: string;
  criterion: string | null;
  outcome: string | null;
  detail: string;
  source: string;
  artifact: string | null;
  collectedAt: string | null;
}

export interface ControlAssessment {
  path: string;
  applicability: string;
  registerStatus: string;
  assertedBy: string;
  assertedAt: string;
  gapSeverity: string;
  recommendation: string;
  references: string[];
}

export interface ControlRow {
  control: string;
  framework: string;
  inCatalog: boolean;
  family: string;
  familyName: string | null;
  title: string | null;
  mappings: ControlMappings | null;
  status: ControlStatus;
  provenance: Provenance;
  observed: string;
  statusBasis: StatusBasisRecord[];
  evidence: EvidenceRecord[];
  supportingEvidence: EvidenceRecord[];
  assessment: ControlAssessment | null;
}

export interface OutOfCatalogControlRow extends ControlRow {
  requirementsMappingToThisControl: string[];
  mappingIsOrientationOnly: true;
  statusMayBeRenderedOnMappedRequirements: false;
  note: string;
}

export interface OutOfCatalogSummary {
  count: number;
  byStatus: StatusCounts;
  byProvenance: ProvenanceCounts;
}

export interface ComplianceSummary {
  totalRequirements: number;
  byStatus: StatusCounts;
  byProvenance: ProvenanceCounts;
  byProvenanceAndStatus: Record<Provenance, StatusCounts>;
  outOfCatalog: OutOfCatalogSummary;
  notes: string[];
}

export interface CollectorReport {
  name: string;
  status: string;
  recordCount: number;
  limitation: string;
  error: string | null;
}

export interface AssessmentProblem {
  file: string;
  problem: string;
}

export interface ComplianceState {
  schemaVersion: number;
  framework: string;
  frameworkName: string;
  collectedAt: string;
  commit: string;
  commitShort: string;
  workingTreeClean: boolean;
  notes: Record<string, string>;
  summary: ComplianceSummary;
  collectors: CollectorReport[];
  assessmentProblems: AssessmentProblem[];
  controls: ControlRow[];
  outOfCatalogControls: OutOfCatalogControlRow[];
}

/* ------------------------------------------------------------------ */
/* query_compliance — params and answer shape                          */
/* ------------------------------------------------------------------ */

export interface ComplianceQueryParams {
  /** Exact control id, e.g. "3.5.3", or an out-of-catalog id: CM-6, CP-9, IR-4, SI-4. */
  control?: string;
  /** Exact family id, e.g. "3.1" (800-171) or a 800-53 family abbreviation, e.g. "CP". */
  family?: string;
  /** Exact framework id: "nist-800-171r2" (the 110-requirement catalog) or "nist-800-53r5". */
  framework?: string;
  /** One of the six derived statuses. Never the register's own GAP/CLOSED vocabulary. */
  status?: string;
}

export interface ComplianceControlAnswer {
  control: string;
  framework: string;
  inCatalog: boolean;
  family: string;
  familyName: string | null;
  title: string | null;
  mappings: ControlMappings | null;
  status: ControlStatus;
  provenance: Provenance;
  observed: string;
  statusBasis: StatusBasisRecord[];
  /** Collected records that actually drove the status (empty today — every
   * register record declares `criteria: []`, so nothing collected drives
   * anything yet). Already filtered of `duplicatesStatusBasis` records. */
  evidence: EvidenceRecord[];
  /** Everything else collected for this control, context only —
   * `participatedInStatus` is false on every record here. Already filtered
   * of `duplicatesStatusBasis` records. */
  supportingEvidence: EvidenceRecord[];
  /** How many evidence/supportingEvidence records were left out because they
   * only re-transcribe the same authored assertion `statusBasis` already
   * carries — present so the omission is visible, not silent. */
  duplicateAssertionsOmitted: number;
  /** The raw word a human wrote in the register (e.g. "CLOSED"), kept
   * distinct from the derived `status` above. "CLOSED" means only "no known
   * open finding" — it is never the same claim as "COMPLIANT", and this
   * field is never substituted for `status`. Null when there is no
   * assessment record. */
  registerStatus: string | null;
  applicability: string | null;
  /** Authored text from the assessment register, verbatim, or null when
   * there is none. Never invented, never extrapolated from the status. */
  recommendation: string | null;
  gapSeverity: string | null;
  assertedBy: string | null;
  assertedAt: string | null;
  references: string[];
}

/** A match from `outOfCatalogControls` — assessed against nist-800-53r5, not
 * part of the 110-requirement catalog. `requirementsMappingToThisControl` is
 * for orientation only: this record's status is never the answer to a
 * question about one of those requirement ids. */
export interface OutOfCatalogAnswer extends ComplianceControlAnswer {
  requirementsMappingToThisControl: string[];
  mappingIsOrientationOnly: true;
  statusMayBeRenderedOnMappedRequirements: false;
  note: string;
}

export interface ComplianceQueryResult {
  framework: string;
  frameworkName: string;
  collectedAt: string;
  commit: string;
  commitShort: string;
  /** Rows in `controls` + `outOfCatalogControls` combined. */
  /** Catalog requirements matching the query. Never includes out-of-catalog rows. */
  matchCount: number;
  /** Out-of-catalog (800-53-keyed) records matching. Deliberately a separate count. */
  outOfCatalogMatchCount: number;
  /** Matches from the 110-requirement catalog. */
  controls: ComplianceControlAnswer[];
  /** Matches assessed against nist-800-53r5, never merged with `controls`
   * and never reachable by querying a requirement id they orient to. */
  outOfCatalogControls: OutOfCatalogAnswer[];
  /** The WHOLE estate's counts, unaffected by any filter above — present on
   * every answer so a narrow question never hides the wider picture. Counts
   * only: no percentage, ratio or score field exists anywhere in this
   * object. Cross-tabulated `byProvenanceAndStatus` is the one to read —
   * never a bare `byProvenance` total. */
  summary: ComplianceSummary;
  /** The artifact's own honesty caveats, verbatim — never paraphrased or
   * summarised by this tool. */
  notes: string[];
}

export interface ComplianceBackend {
  query(params: ComplianceQueryParams): Promise<ComplianceQueryResult>;
}

/* ------------------------------------------------------------------ */
/* Loading and validating the artifact                                 */
/* ------------------------------------------------------------------ */

function isComplianceState(value: unknown): value is ComplianceState {
  if (!value || typeof value !== "object") return false;
  const v = value as Record<string, unknown>;
  return (
    typeof v.framework === "string" &&
    typeof v.frameworkName === "string" &&
    Array.isArray(v.controls) &&
    Array.isArray(v.outOfCatalogControls) &&
    typeof v.summary === "object" &&
    v.summary !== null
  );
}

/**
 * Read and parse the committed state artifact. Throws an `AdapterError` —
 * never returns an empty-but-confident stand-in — when the file is absent,
 * unparsable, or does not look like a Task 8 state artifact. Absence of data
 * is not a clean bill of health.
 */
export function loadComplianceState(statePath: string): ComplianceState {
  let raw: string;
  try {
    raw = fs.readFileSync(statePath, "utf-8");
  } catch (err) {
    throw new AdapterError(
      "not_found",
      `compliance state artifact not found at ${statePath}. Task 8's emitter ` +
        "(compliance/Invoke-MlsCompliance.ps1) writes compliance/state/state-latest.json and it " +
        "must be committed and baked into this image before query_compliance can answer anything " +
        "— its absence is not a clean bill of health, it means this tool cannot answer at all.",
      { service: "compliance-state", cause: err },
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new AdapterError(
      "upstream",
      `compliance state artifact at ${statePath} is not valid JSON and cannot be read.`,
      { service: "compliance-state", cause: err },
    );
  }

  if (!isComplianceState(parsed)) {
    throw new AdapterError(
      "upstream",
      `compliance state artifact at ${statePath} is missing required fields (framework, ` +
        "frameworkName, controls, outOfCatalogControls, summary) — it does not look like a " +
        "Task 8 state artifact and cannot be trusted to answer from.",
      { service: "compliance-state" },
    );
  }

  return parsed;
}

/* ------------------------------------------------------------------ */
/* Filtering and reshaping                                             */
/* ------------------------------------------------------------------ */

/** Same filter, same reasoning, as apps/compliance/src/ControlDetail.tsx:
 * a `duplicatesStatusBasis` record is the `manual` collector's verbatim
 * transcription of the assertion `statusBasis` already carries — counting it
 * again as evidence would double a single human claim into two. */
function independentEvidence(records: EvidenceRecord[]): EvidenceRecord[] {
  return records.filter((r) => r.duplicatesStatusBasis !== true);
}

function buildAnswer(row: ControlRow): ComplianceControlAnswer {
  const evidence = independentEvidence(row.evidence);
  const supportingEvidence = independentEvidence(row.supportingEvidence);
  const duplicateAssertionsOmitted =
    row.evidence.length - evidence.length + (row.supportingEvidence.length - supportingEvidence.length);

  return {
    control: row.control,
    framework: row.framework,
    inCatalog: row.inCatalog,
    family: row.family,
    familyName: row.familyName,
    title: row.title,
    mappings: row.mappings,
    status: row.status,
    provenance: row.provenance,
    observed: row.observed,
    statusBasis: row.statusBasis,
    evidence,
    supportingEvidence,
    duplicateAssertionsOmitted,
    registerStatus: row.assessment?.registerStatus ?? null,
    applicability: row.assessment?.applicability ?? null,
    recommendation: row.assessment?.recommendation ?? null,
    gapSeverity: row.assessment?.gapSeverity ?? null,
    assertedBy: row.assessment?.assertedBy ?? null,
    assertedAt: row.assessment?.assertedAt ?? null,
    references: row.assessment?.references ?? [],
  };
}

function buildOutOfCatalogAnswer(row: OutOfCatalogControlRow): OutOfCatalogAnswer {
  return {
    ...buildAnswer(row),
    requirementsMappingToThisControl: row.requirementsMappingToThisControl,
    mappingIsOrientationOnly: true,
    statusMayBeRenderedOnMappedRequirements: false,
    note: row.note,
  };
}

function normalize(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed && trimmed.length > 0 ? trimmed : undefined;
}

/**
 * Pure filtering/reshaping over an already-loaded state artifact — split out
 * from `ComplianceStateBackend.query` so tests can exercise every filter
 * combination against the real committed artifact without touching the
 * filesystem.
 *
 * `controls` and `outOfCatalogControls` are filtered INDEPENDENTLY and never
 * merged: a `control` filter matches a row only by that row's own `control`
 * id, so "3.8.9" (in `controls`) and "CP-9" (in `outOfCatalogControls`,
 * mapped to 3.8.9 for orientation only) can never answer for each other.
 */
export function queryComplianceState(
  state: ComplianceState,
  params: ComplianceQueryParams,
): ComplianceQueryResult {
  const wantControl = normalize(params.control)?.toUpperCase();
  const wantFamily = normalize(params.family)?.toLowerCase();
  const wantFramework = normalize(params.framework)?.toLowerCase();
  const wantStatus = normalize(params.status)?.toUpperCase();

  const matches = (row: { control: string; family: string; framework: string; status: string }): boolean => {
    if (wantControl && row.control.toUpperCase() !== wantControl) return false;
    if (wantFamily && row.family.toLowerCase() !== wantFamily) return false;
    if (wantFramework && row.framework.toLowerCase() !== wantFramework) return false;
    if (wantStatus && row.status.toUpperCase() !== wantStatus) return false;
    return true;
  };

  const controls = state.controls.filter(matches).map(buildAnswer);
  const outOfCatalogControls = state.outOfCatalogControls.filter(matches).map(buildOutOfCatalogAnswer);

  return {
    framework: state.framework,
    frameworkName: state.frameworkName,
    collectedAt: state.collectedAt,
    commit: state.commit,
    commitShort: state.commitShort,
    // Split, never summed. A single matchCount conflated the 110-requirement
    // catalog with the four 800-53 records that have no 800-171 requirement at
    // all - so a caller asking for PARTIAL controls was handed 16 when the
    // 800-171 answer is 12, and would report "16 of the 110". That is
    // CM-6/CP-9/IR-4/SI-4 reaching an 800-171 answer, which is the one crossing
    // this platform forbids. The two counts stay apart so no caller can add them
    // by accident.
    matchCount: controls.length,
    outOfCatalogMatchCount: outOfCatalogControls.length,
    controls,
    outOfCatalogControls,
    // Unfiltered, always the whole estate — a narrow question must never
    // hide the wider picture (the 95 NOT_ASSESSED figure belongs here).
    summary: state.summary,
    // Deduplicated union of the artifact's own caveats, verbatim.
    notes: Array.from(new Set([...Object.values(state.notes), ...state.summary.notes])),
  };
}

/* ------------------------------------------------------------------ */
/* Backend                                                              */
/* ------------------------------------------------------------------ */

/**
 * Reads the same bundled artifact regardless of `MLS_TOOL_BACKENDS` — unlike
 * the other five tools, `query_compliance` has no cloud counterpart: the
 * committed state artifact IS the answer in both local and cloud mode, so
 * `createLocalBackends` and `createCloudBackends` both construct this same
 * class (see backends.ts and tools/cloud/index.ts).
 */
export class ComplianceStateBackend implements ComplianceBackend {
  constructor(private readonly statePath: string = complianceStatePath) {}

  async query(params: ComplianceQueryParams): Promise<ComplianceQueryResult> {
    const state = loadComplianceState(this.statePath);
    return queryComplianceState(state, params);
  }
}
