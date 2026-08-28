import { Link, Text, Title2, Title3, makeStyles, tokens } from "@fluentui/react-components";
import type {
  ComplianceCatalog,
  ComplianceState,
  EvidenceRecord,
  OutOfCatalogControlRow,
  StatusBasisRecord,
} from "./types";
import { StatusBadge } from "./StatusBadge";
import { ProvenanceBadge } from "./ProvenanceBadge";

/**
 * The same http(s)-only allowlist control-tower's AdaptiveCardView.tsx
 * applies to Action.OpenUrl/Image.url (F11). `observed`, artifact paths and
 * `references` entries here are all authored data -- a human wrote the
 * assessment JSON, and nothing upstream validates it -- so only a string
 * that is actually an http(s) URL becomes a clickable link. Everything
 * else, including a `javascript:` URI and the plain repo-relative path
 * every reference in today's real artifact actually takes (e.g.
 * "infra/bicep/platform/main.bicep:317"), renders as inert text instead.
 */
const SAFE_URL = /^https?:\/\//i;

function safeUrl(value: string | null | undefined): string | null {
  if (!value) return null;
  const trimmed = value.trim();
  return SAFE_URL.test(trimmed) ? trimmed : null;
}

const useStyles = makeStyles({
  panel: {
    border: `1px solid ${tokens.colorNeutralStroke2}`,
    borderRadius: tokens.borderRadiusMedium,
    padding: "1rem 1.25rem",
    display: "flex",
    flexDirection: "column",
    gap: "0.5rem",
  },
  header: {
    display: "flex",
    alignItems: "baseline",
    gap: "0.5rem",
    flexWrap: "wrap",
  },
  record: {
    border: `1px solid ${tokens.colorNeutralStroke3}`,
    borderRadius: tokens.borderRadiusSmall,
    padding: "0.5rem 0.75rem",
    display: "flex",
    flexDirection: "column",
    gap: "0.15rem",
  },
  recordMeta: {
    color: tokens.colorNeutralForeground3,
  },
  refList: {
    display: "flex",
    flexDirection: "column",
    gap: "0.15rem",
  },
  path: {
    fontFamily: tokens.fontFamilyMonospace,
    fontSize: tokens.fontSizeBase200,
    color: tokens.colorNeutralForeground2,
    wordBreak: "break-all",
  },
  banner: {
    padding: "0.5rem 0.75rem",
    borderRadius: tokens.borderRadiusMedium,
    backgroundColor: tokens.colorNeutralBackground3,
    borderLeft: `4px solid ${tokens.colorPaletteBlueBorderActive}`,
  },
});

function ArtifactRef({ path }: { path: string }): JSX.Element {
  const styles = useStyles();
  const url = safeUrl(path);
  if (url) {
    return (
      <Link href={url} target="_blank" rel="noreferrer noopener">
        {path}
      </Link>
    );
  }
  // Not an http(s) URL -- a repo-relative path (the normal case today) or
  // anything else unsafe. Rendered as inert text, never as a clickable
  // href built from an unvalidated string.
  return <code className={styles.path}>{path}</code>;
}

function StatusBasisRow({ record }: { record: StatusBasisRecord }): JSX.Element {
  const styles = useStyles();
  return (
    <div className={styles.record} data-testid="status-basis-record">
      <Text weight="semibold">{record.kind}</Text>
      {/* Authored prose -- text via JSX interpolation only, never
       * dangerouslySetInnerHTML, never keyword-matched for colour. */}
      <Text>{record.detail}</Text>
      <Text size={200} className={styles.recordMeta}>
        source: {record.source}
        {record.criterion ? ` · criterion: ${record.criterion}` : ""}
        {record.collectedAt ? ` · collected ${record.collectedAt}` : ""}
      </Text>
      {record.artifact && <ArtifactRef path={record.artifact} />}
    </div>
  );
}

function EvidenceRow({ record }: { record: EvidenceRecord }): JSX.Element {
  const styles = useStyles();
  return (
    <div className={styles.record} data-testid="evidence-record">
      <Text size={200} className={styles.recordMeta}>
        {record.source}
        {record.criterion ? ` · ${record.criterion}` : ""} · {record.status}
        {record.collectedAt ? ` · collected ${record.collectedAt}` : ""}
      </Text>
      <Text>{record.observed}</Text>
      {record.artifact && <ArtifactRef path={record.artifact} />}
    </div>
  );
}

export interface ControlDetailProps {
  control: string;
  state: ComplianceState;
  catalog: ComplianceCatalog;
}

export function ControlDetail({ control, state, catalog }: ControlDetailProps): JSX.Element {
  const styles = useStyles();
  const row = state.controls.find((c) => c.control === control);
  if (row) {
    // `duplicatesStatusBasis` records are the `manual` collector's verbatim
    // transcription of the same authored assertion `statusBasis` already
    // shows -- listing them again as independent evidence would
    // double-count one human claim as two. They are visibly merged into
    // the status basis via the note below, never listed as their own
    // record in EITHER evidence section. Today the emitter only ever sets
    // this flag on `supportingEvidence` (non-participating) records, never
    // on `evidence` (participating ones) -- but types.ts states the rule
    // unconditionally on the shared `EvidenceRecord` type, so both arrays
    // are filtered the same way rather than relying on that emitter
    // invariant holding forever.
    const evidenceRecords = row.evidence.filter((e) => !e.duplicatesStatusBasis);
    const supporting = row.supportingEvidence.filter((e) => !e.duplicatesStatusBasis);
    const mergedCount =
      row.evidence.length - evidenceRecords.length + (row.supportingEvidence.length - supporting.length);

    return (
      <div className={styles.panel} data-testid="control-detail">
        <div className={styles.header}>
          <Title2>{row.control}</Title2>
          <StatusBadge status={row.status} />
          <ProvenanceBadge provenance={row.provenance} />
        </div>
        {row.title && <Text>{row.title}</Text>}
        <Text size={200} className={styles.recordMeta}>
          {row.family}
          {row.familyName ? ` — ${row.familyName}` : ""}
        </Text>
        <Text>{row.observed}</Text>

        <Title3 as="h3">Status basis</Title3>
        {row.statusBasis.length === 0 ? (
          <Text size={200} className={styles.recordMeta}>
            {/*
              Branch on what was actually collected. The flat "nothing was
              collected" wording was false for every control with supporting
              evidence but no status basis - 3.4.5 and 3.11.2 today, where the one
              collected record is a FAIL - and it contradicted this same panel's
              own `observed` line a few rows above, which the emitter deliberately
              words "...evidence record(s) were collected for it and are carried in
              supportingEvidence as context only" precisely to avoid saying
              nothing was collected. One screenshot must not make two claims.
            */}
            {supporting.length === 0
              ? "Nothing was authored or collected for this control."
              : "Nothing was authored that could drive a status. Evidence was collected and is listed under Supporting evidence below, as context only."}
          </Text>
        ) : (
          row.statusBasis.map((record, i) => <StatusBasisRow key={i} record={record} />)
        )}

        <Title3 as="h3">Evidence</Title3>
        {evidenceRecords.length === 0 ? (
          <Text size={200} className={styles.recordMeta}>
            No collected record participated in this control&apos;s status.
          </Text>
        ) : (
          evidenceRecords.map((record, i) => <EvidenceRow key={i} record={record} />)
        )}

        <Title3 as="h3">Supporting evidence</Title3>
        {supporting.length === 0 ? (
          <Text size={200} className={styles.recordMeta}>
            No supporting evidence collected for this control.
          </Text>
        ) : (
          supporting.map((record, i) => <EvidenceRow key={i} record={record} />)
        )}
        {mergedCount > 0 && (
          <Text size={200} className={styles.recordMeta} data-testid="merged-duplicate-note">
            {mergedCount} record{mergedCount === 1 ? "" : "s"} transcribing this same authored
            assertion {mergedCount === 1 ? "is" : "are"} merged into the status basis above, not
            listed separately here.
          </Text>
        )}

        {row.assessment ? (
          <>
            <Title3 as="h3">Assessment</Title3>
            <Text size={200} className={styles.recordMeta}>
              applicability: {row.assessment.applicability} · register status:{" "}
              {row.assessment.registerStatus} · asserted by {row.assessment.assertedBy} on{" "}
              {row.assessment.assertedAt} · gap severity: {row.assessment.gapSeverity}
            </Text>
            <Text data-testid="recommendation">{row.assessment.recommendation}</Text>
            {row.assessment.references.length > 0 && (
              <div className={styles.refList}>
                {row.assessment.references.map((ref) => (
                  <ArtifactRef key={ref} path={ref} />
                ))}
              </div>
            )}
          </>
        ) : (
          <Text data-testid="recommendation" size={200} className={styles.recordMeta}>
            No assessment recorded yet for this control.
          </Text>
        )}

        <Title3 as="h3">Framework mappings</Title3>
        {row.mappings ? (
          <ul>
            {Object.entries(row.mappings).map(([framework, ids]) => (
              <li key={framework}>
                <Text weight="semibold">{framework}</Text>: {ids.length > 0 ? ids.join(", ") : "no mapping"}
              </li>
            ))}
          </ul>
        ) : (
          <Text size={200} className={styles.recordMeta}>
            No framework mappings recorded.
          </Text>
        )}
      </div>
    );
  }

  const outOfCatalog = state.outOfCatalogControls.find((c) => c.control === control);
  if (outOfCatalog) return <OutOfCatalogDetail row={outOfCatalog} />;

  return (
    <Text data-testid="control-detail-not-found">
      No record for control &quot;{control}&quot; in this state artifact.
    </Text>
  );
}

/**
 * A control from `outOfCatalogControls` -- assessed against nist-800-53r5
 * directly, with no requirement of its own in this catalog. Rendered from
 * its own record only: `requirementsMappingToThisControl` is shown as
 * orientation prose, never resolved into (or borrowing status from) any
 * catalog requirement's own detail view. Selecting requirement 3.8.9 and
 * selecting CP-9 are two independent lookups against two independent
 * arrays -- there is no code path here that lets one answer the other.
 */
function OutOfCatalogDetail({ row }: { row: OutOfCatalogControlRow }): JSX.Element {
  const styles = useStyles();
  return (
    <div className={styles.panel} data-testid="control-detail-out-of-catalog">
      <Text as="p" className={styles.banner}>
        {row.control} was assessed under {row.framework}, not the 110-requirement catalog. It is
        not part of any family board and its status is never applied to the requirement(s) it
        orients to.
      </Text>
      <div className={styles.header}>
        <Title2>{row.control}</Title2>
        <StatusBadge status={row.status} />
        <ProvenanceBadge provenance={row.provenance} />
      </div>
      <Text>{row.note}</Text>
      {row.requirementsMappingToThisControl.length > 0 && (
        <Text size={200} className={styles.recordMeta}>
          Orientation only -- not applied to: {row.requirementsMappingToThisControl.join(", ")}
        </Text>
      )}
      {row.assessment && (
        <>
          <Title3 as="h3">Assessment</Title3>
          <Text data-testid="recommendation">{row.assessment.recommendation}</Text>
        </>
      )}
    </div>
  );
}
