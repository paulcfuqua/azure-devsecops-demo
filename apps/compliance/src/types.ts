// The data contract this app renders: compliance/state/state-latest.json
// (Task 8's emitted, committed artifact) and compliance/catalog/*.json
// (authored reference data, asserts nothing). Written from the real
// committed artifact's shape, not from the plan's illustrative sketches --
// see apps/compliance/tests/fixtures.ts, which imports the real files
// rather than hand-rolling equivalents that could drift from them.
//
// Not in Task 9's own Files list, but every later task (10-12) needs these
// same shapes and none of them owns a types module either; centralising
// them here once avoids four divergent hand-rolled copies.

/** The six derived statuses. Always render every key, including the zeros --
 * never synthesize a subset. */
export type ControlStatus =
  | "COMPLIANT"
  | "PARTIAL"
  | "GAP"
  | "INCONCLUSIVE"
  | "NOT_APPLICABLE"
  | "NOT_ASSESSED";

/** The four provenance values. `machine-verified` includes a criterion a
 * machine explicitly declined to run (SKIP -> INCONCLUSIVE) -- it does not
 * mean passing. COMPLIANT is the only status that means verified-and-passing. */
export type Provenance = "machine-verified" | "asserted" | "declared" | "none";

export const STATUS_KEYS: readonly ControlStatus[] = [
  "COMPLIANT",
  "PARTIAL",
  "GAP",
  "INCONCLUSIVE",
  "NOT_APPLICABLE",
  "NOT_ASSESSED",
];

export const PROVENANCE_KEYS: readonly Provenance[] = [
  "machine-verified",
  "asserted",
  "declared",
  "none",
];

export type StatusCounts = Record<ControlStatus, number>;
export type ProvenanceCounts = Record<Provenance, number>;

export interface EvidenceRecord {
  source: string;
  criterion: string | null;
  status: string;
  /** Authored/observed prose. Render as text (JSX interpolation), never via
   * dangerouslySetInnerHTML, and never keyword-match it to pick a colour --
   * status/provenance enums drive colour, this field is free text. */
  observed: string;
  artifact: string | null;
  collectedAt: string | null;
  participatedInStatus: boolean;
  /** True when this record is the `manual` collector's verbatim transcription
   * of the same assertion already captured in the control's own
   * `statusBasis`. Rendering it as independent evidence double-counts a
   * single human claim as two -- suppress it or merge it visibly, never
   * list it as a second, separate piece of evidence. */
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

export type ControlMappings = Record<string, string[]>;

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
  /** Authored/observed prose describing why the status landed where it did.
   * Same escaping and no-keyword-matching rules as EvidenceRecord.observed. */
  observed: string;
  statusBasis: StatusBasisRecord[];
  evidence: EvidenceRecord[];
  supportingEvidence: EvidenceRecord[];
  assessment: ControlAssessment | null;
}

/** A row in `outOfCatalogControls`: assessed against a different framework
 * (today, always nist-800-53r5) that the 110-requirement catalog has no
 * entry for. `requirementsMappingToThisControl` is orientation only --
 * `statusMayBeRenderedOnMappedRequirements` is always false, and this
 * status must NEVER be displayed against any of those requirement rows
 * (CP-9's authored CLOSED must never appear on 3.8.9). Render these on
 * their own, separate from every family/requirement view. */
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
  /** Never render this bare -- it is the trust badge described in the Task 9
   * brief: "machine-verified: N" invites a reader to credit verification
   * that a wholly-skipped criterion also earns. Always read
   * byProvenanceAndStatus instead. */
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

/** Framework ids the catalog's `mappings` object keys on, plus the primary
 * framework the state artifact was collected against. Task 11's
 * FrameworkSwitcher relabels the same 110 rows under one of these. */
export type FrameworkId =
  | "nist-800-171r2"
  | "nist-800-53r5"
  | "cmmc-2.0"
  | "far-52.204-21";

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
  assessmentProblems: unknown[];
  controls: ControlRow[];
  outOfCatalogControls: OutOfCatalogControlRow[];
}

export interface CatalogRequirement {
  id: string;
  family: string;
  familyName: string;
  title: string;
  mappings: ControlMappings;
}

export interface ComplianceCatalog {
  framework: string;
  frameworkName: string;
  sourceDocument: string;
  note: string;
  requirements: CatalogRequirement[];
}
