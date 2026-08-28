import { Badge, Text, Title3, makeStyles, tokens } from "@fluentui/react-components";
import { useMemo } from "react";
import type {
  AssessmentProblem,
  CollectorReport,
  ComplianceCatalog,
  ComplianceState,
  ControlRow,
  FrameworkId,
  OutOfCatalogControlRow,
  Provenance,
  StatusCounts,
} from "./types";
import { PROVENANCE_KEYS, STATUS_KEYS } from "./types";
import { FamilyCard, type FamilyCardEntry } from "./FamilyCard";
import { StatusBadge } from "./StatusBadge";
import { ProvenanceBadge } from "./ProvenanceBadge";
import { FRAMEWORK_LABELS } from "./FrameworkSwitcher";

const useStyles = makeStyles({
  callout: {
    display: "block",
    margin: "0.75rem 0 1rem",
    padding: "0.75rem 1rem",
    borderRadius: tokens.borderRadiusMedium,
    backgroundColor: tokens.colorNeutralBackground3,
    borderLeft: `4px solid ${tokens.colorPaletteBlueBorderActive}`,
  },
  matrix: {
    borderCollapse: "collapse",
    marginBottom: "1.5rem",
    "& th, & td": {
      border: `1px solid ${tokens.colorNeutralStroke2}`,
      padding: "0.35rem 0.6rem",
      textAlign: "right",
      fontVariantNumeric: "tabular-nums",
    },
    "& th": {
      textAlign: "left",
      backgroundColor: tokens.colorNeutralBackground3,
    },
  },
  outOfCatalogSection: {
    marginTop: "1.5rem",
    paddingTop: "1rem",
    borderTop: `2px dashed ${tokens.colorNeutralStroke2}`,
  },
  outOfCatalogRow: {
    display: "flex",
    alignItems: "baseline",
    gap: "0.5rem",
    flexWrap: "wrap",
    padding: "0.35rem 0",
    borderTop: `1px solid ${tokens.colorNeutralStroke3}`,
    cursor: "default",
  },
  outOfCatalogRowClickable: {
    cursor: "pointer",
    ":hover": { backgroundColor: tokens.colorNeutralBackground3 },
  },
  outOfCatalogObserved: {
    display: "block",
    color: tokens.colorNeutralForeground2,
  },
  collectorPanel: {
    display: "flex",
    flexDirection: "column",
    gap: "0.5rem",
    margin: "0 0 1rem",
    padding: "0.75rem 1rem",
    borderRadius: tokens.borderRadiusMedium,
    backgroundColor: tokens.colorNeutralBackground3,
    borderLeft: `4px solid ${tokens.colorPaletteBlueBorderActive}`,
  },
  collectorPanelUnhealthy: {
    display: "flex",
    flexDirection: "column",
    gap: "0.5rem",
    margin: "0 0 1rem",
    padding: "0.75rem 1rem",
    borderRadius: tokens.borderRadiusMedium,
    backgroundColor: tokens.colorNeutralBackground3,
    borderLeft: `4px solid ${tokens.colorPaletteRedBorderActive}`,
  },
  deploymentBanner: {
    display: "block",
    padding: "0.5rem 0.75rem",
    borderRadius: tokens.borderRadiusMedium,
    backgroundColor: tokens.colorPaletteRedBackground1,
    color: tokens.colorPaletteRedForeground1,
  },
  collectorList: {
    display: "flex",
    flexDirection: "column",
    gap: "0.5rem",
    margin: 0,
    padding: 0,
    listStyle: "none",
  },
  collectorItem: {
    display: "flex",
    flexDirection: "column",
    gap: "0.15rem",
    padding: "0.5rem 0.75rem",
    border: `1px solid ${tokens.colorNeutralStroke3}`,
    borderRadius: tokens.borderRadiusSmall,
  },
  collectorHeading: {
    display: "flex",
    alignItems: "baseline",
    gap: "0.5rem",
    flexWrap: "wrap",
  },
  collectorMeta: {
    color: tokens.colorNeutralForeground3,
  },
  collectorError: {
    display: "block",
    color: tokens.colorPaletteRedForeground1,
  },
});

function emptyStatusCounts(): StatusCounts {
  return {
    COMPLIANT: 0,
    PARTIAL: 0,
    GAP: 0,
    INCONCLUSIVE: 0,
    NOT_APPLICABLE: 0,
    NOT_ASSESSED: 0,
  };
}

function emptyProvenanceAndStatus(): Record<Provenance, StatusCounts> {
  const result = {} as Record<Provenance, StatusCounts>;
  for (const provenance of PROVENANCE_KEYS) result[provenance] = emptyStatusCounts();
  return result;
}

interface FamilyGroup {
  id: string;
  name: string;
  counts: StatusCounts;
  controls: FamilyCardEntry[];
}

interface BoardTotals {
  totalRequirements: number;
  byStatus: StatusCounts;
  byProvenanceAndStatus: Record<Provenance, StatusCounts>;
}

interface BoardView {
  families: FamilyGroup[];
  totals: BoardTotals;
}

/**
 * The label a control shows under `framework`: its own id under the
 * catalog's native framework, or its mapped id(s) under any other
 * framework -- joined, since a control can map to more than one id (e.g.
 * 3.1.1 maps to both L1-3.1.1 and L2-3.1.1 under cmmc-2.0).
 *
 * Returns null when the control has no mapping under `framework` at all --
 * such a control is filtered out of that framework's view entirely rather
 * than shown with an empty label (this is why only 17 of 110 controls
 * appear under far-52.204-21, CMMC Level 1's 17 practices).
 *
 * Reads ONLY `control.mappings`, which lives on the catalog-derived
 * `state.controls` rows. Never resolves through `outOfCatalogControls` --
 * that is a structurally separate set of records (CM-6, CP-9, IR-4, SI-4)
 * assessed against nist-800-53r5 directly, whose own
 * `requirementsMappingToThisControl` field exists for orientation only
 * (`mappingIsOrientationOnly: true`, `statusMayBeRenderedOnMappedRequirements:
 * false`). Joining that field in here is exactly the cross-attribution the
 * data contract forbids: CP-9's authored status must never render on
 * requirement 3.8.9's row, under any framework label.
 */
function frameworkLabel(control: ControlRow, framework: FrameworkId): string | null {
  if (framework === control.framework) return control.control;
  const mapped = control.mappings?.[framework];
  if (!mapped || mapped.length === 0) return null;
  return mapped.join(", ");
}

/**
 * Groups by the CATALOG's family list (always the full 14, in catalog
 * order) so a family with zero assessed controls still gets a card -- never
 * derive the family list from `state.controls` alone, or a family nothing
 * was ever said about would silently vanish instead of showing 100%
 * NOT_ASSESSED. Within each family, controls are further filtered to those
 * with a label under the active `framework` -- see `frameworkLabel`.
 *
 * Also returns the board-wide totals (denominator, byStatus,
 * byProvenanceAndStatus) for the SAME filtered set the family cards below
 * render, so the headline and cross-tab can never show a different
 * denominator than what is actually on screen. For the catalog's native
 * framework, every control passes the filter, so this returns the
 * committed artifact's own `state.summary` verbatim -- the authoritative
 * source -- rather than a UI recomputation that could drift from it; only
 * a genuinely filtered (non-native) view recomputes, over exactly the
 * controls that passed the same filter used for the family cards.
 */
function buildBoardView(
  state: ComplianceState,
  catalog: ComplianceCatalog,
  framework: FrameworkId,
): BoardView {
  const order: string[] = [];
  const names = new Map<string, string>();
  for (const req of catalog.requirements) {
    if (!names.has(req.family)) {
      order.push(req.family);
      names.set(req.family, req.familyName);
    }
  }
  const byFamily = new Map<string, ControlRow[]>(order.map((id) => [id, []]));
  for (const control of state.controls) {
    const bucket = byFamily.get(control.family);
    if (bucket) bucket.push(control);
  }

  const computedByStatus = emptyStatusCounts();
  const computedByProvenanceAndStatus = emptyProvenanceAndStatus();
  let computedTotal = 0;

  const families = order.map((id) => {
    const allControls = byFamily.get(id) ?? [];
    const counts = emptyStatusCounts();
    const controls: FamilyCardEntry[] = [];
    for (const control of allControls) {
      const label = frameworkLabel(control, framework);
      if (label === null) continue;
      counts[control.status] += 1;
      computedByStatus[control.status] += 1;
      computedByProvenanceAndStatus[control.provenance][control.status] += 1;
      computedTotal += 1;
      controls.push({ control, label });
    }
    return { id, name: names.get(id) ?? id, counts, controls };
  });

  const isNative = framework === state.framework;
  const totals: BoardTotals = isNative
    ? {
        totalRequirements: state.summary.totalRequirements,
        byStatus: state.summary.byStatus,
        byProvenanceAndStatus: state.summary.byProvenanceAndStatus,
      }
    : {
        totalRequirements: computedTotal,
        byStatus: computedByStatus,
        byProvenanceAndStatus: computedByProvenanceAndStatus,
      };

  return { families, totals };
}

export interface BoardProps {
  state: ComplianceState;
  catalog: ComplianceCatalog;
  framework: FrameworkId;
  onSelectControl?: (control: string) => void;
}

export function Board({ state, catalog, framework, onSelectControl }: BoardProps): JSX.Element {
  const styles = useStyles();
  const { families, totals } = useMemo(
    () => buildBoardView(state, catalog, framework),
    [state, catalog, framework],
  );
  const isNative = framework === state.framework;
  const frameworkName = FRAMEWORK_LABELS[framework] ?? framework;

  return (
    <div>
      <Text as="p" data-testid="collected-at" className={styles.callout}>
        Collected <strong>{state.collectedAt}</strong> from commit {state.commitShort} (
        {state.workingTreeClean ? "clean tree" : "tree had uncommitted changes"}
        ).
      </Text>

      <CollectorPanel collectors={state.collectors} assessmentProblems={state.assessmentProblems} />

      <Text as="p" className={styles.callout}>
        <strong>
          {totals.byStatus.NOT_ASSESSED} of {totals.totalRequirements}
        </strong>{" "}
        {isNative ? "requirements" : `requirements visible under ${frameworkName}`} are{" "}
        <strong>NOT_ASSESSED</strong> — nothing has been asserted or collected about them yet.
      </Text>

      <Title3 as="h3">By provenance and status</Title3>
      <Text as="p" size={200}>
        Never read a bare provenance total: a criterion a machine explicitly declined to run is
        still counted under machine-verified. Only the COMPLIANT column means verified and
        passing.
        {!isNative &&
          ` Showing the ${totals.totalRequirements} requirements visible under ${frameworkName} -- not the full ${state.summary.totalRequirements} in the catalog.`}
      </Text>
      <table
        className={styles.matrix}
        aria-label={
          isNative
            ? "Controls by provenance and status"
            : `Controls by provenance and status (${totals.totalRequirements} visible under ${frameworkName})`
        }
      >
        <thead>
          <tr>
            <th scope="col">Provenance</th>
            {STATUS_KEYS.map((status) => (
              <th scope="col" key={status}>
                {status}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {PROVENANCE_KEYS.map((provenance) => (
            <tr key={provenance}>
              <th scope="row">{provenance}</th>
              {STATUS_KEYS.map((status) => (
                <td key={status}>{totals.byProvenanceAndStatus[provenance][status]}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>

      <Title3 as="h3">By family</Title3>
      {families.map((family) => (
        <FamilyCard
          key={family.id}
          id={family.id}
          name={family.name}
          counts={family.counts}
          controls={family.controls}
          onSelectControl={onSelectControl}
        />
      ))}

      {state.outOfCatalogControls.length > 0 && (
        <OutOfCatalogSection
          controls={state.outOfCatalogControls}
          totalRequirements={state.summary.totalRequirements}
          onSelectControl={onSelectControl}
        />
      )}
    </div>
  );
}

/**
 * Collector health, rendered where a viewer actually sees it -- previously
 * `collectors[].status/limitation/error` and `assessmentProblems` were
 * declared in the data contract and read nowhere in `src/`, so a run where
 * several collectors died rendered identically to a healthy one, and the
 * single most important fact about this estate (nothing in it has ever
 * been deployed -- see `verification-suite`'s own limitation below) reached
 * a reader only by clicking into one of a handful of specific controls.
 *
 * `verification-suite` is looked up BY NAME (a stable data-contract key),
 * never by matching English text in its `limitation` string -- if that
 * collector is present, its own limitation is surfaced verbatim as the
 * deployment-status banner, so this never invents prose that could drift
 * from what the emitter actually says.
 */
function CollectorPanel({
  collectors,
  assessmentProblems,
}: {
  collectors: CollectorReport[];
  assessmentProblems: AssessmentProblem[];
}): JSX.Element {
  const styles = useStyles();
  const failed = collectors.filter((c) => c.status !== "ok");
  const healthy = failed.length === 0;
  const deploymentCollector = collectors.find((c) => c.name === "verification-suite");

  return (
    <section
      className={healthy ? styles.collectorPanel : styles.collectorPanelUnhealthy}
      data-testid="collector-panel"
    >
      <Text as="p" weight="semibold" data-testid="collector-summary">
        {healthy
          ? `All ${collectors.length} collectors ran without error.`
          : `${failed.length} of ${collectors.length} collectors failed to run: ${failed
              .map((c) => c.name)
              .join(", ")}.`}
      </Text>

      {deploymentCollector && (
        <Text
          as="p"
          weight="semibold"
          className={styles.deploymentBanner}
          data-testid="deployment-banner"
        >
          {deploymentCollector.limitation}
        </Text>
      )}

      <Text as="p" size={200}>
        This board reflects only what each collector below could read -- declarations and
        committed audit history, not a live scan of a running estate.
      </Text>

      <ul className={styles.collectorList}>
        {collectors.map((collector) => (
          <li
            key={collector.name}
            className={styles.collectorItem}
            data-testid={`collector-${collector.name}`}
          >
            <div className={styles.collectorHeading}>
              <Text weight="semibold">{collector.name}</Text>
              <Badge
                appearance="outline"
                color={collector.status === "ok" ? "subtle" : "danger"}
                data-testid="collector-status"
                aria-label={`collector status: ${collector.status}`}
              >
                {collector.status}
              </Badge>
              <Text size={200} className={styles.collectorMeta}>
                {collector.recordCount} record{collector.recordCount === 1 ? "" : "s"}
              </Text>
            </div>
            <Text size={200} className={styles.collectorMeta}>
              {collector.limitation}
            </Text>
            {collector.error && (
              <Text size={200} className={styles.collectorError} data-testid="collector-error">
                Error: {collector.error}
              </Text>
            )}
          </li>
        ))}
      </ul>

      {assessmentProblems.length > 0 && (
        <div data-testid="assessment-problems">
          <Text weight="semibold">Assessment problems</Text>
          <ul>
            {assessmentProblems.map((problem, i) => (
              <li key={i}>
                <Text size={200}>
                  {problem.file}: {problem.problem}
                </Text>
              </li>
            ))}
          </ul>
        </div>
      )}
    </section>
  );
}

/**
 * Always rendered on its own, regardless of `framework` -- these four rows
 * (CM-6, CP-9, IR-4, SI-4) were assessed against nist-800-53r5 directly and
 * have no requirement of their own in the 110-item catalog. They are never
 * folded into a family card above, and their `requirementsMappingToThisControl`
 * is shown here as orientation prose only, never as a live cross-reference
 * that would resolve their status onto the requirement rows above.
 *
 * Clickable (when `onSelectControl` is supplied) exactly like a family
 * card's control rows, routing to ControlDetail's own `OutOfCatalogDetail`
 * branch -- a separate lookup against `outOfCatalogControls`, never a
 * resolution onto any catalog requirement's detail view.
 */
function OutOfCatalogSection({
  controls,
  totalRequirements,
  onSelectControl,
}: {
  controls: OutOfCatalogControlRow[];
  totalRequirements: number;
  onSelectControl?: (control: string) => void;
}): JSX.Element {
  const styles = useStyles();
  return (
    <section className={styles.outOfCatalogSection}>
      <Title3 as="h3">Assessed under other frameworks</Title3>
      <Text as="p" size={200}>
        Not part of the {totalRequirements}-requirement catalog above. Each row
        below carries an orientation-only mapping to a catalog requirement;
        that mapping is never applied to the requirement&apos;s own status.
      </Text>
      {controls.map((row) => {
        const clickable = Boolean(onSelectControl);

        function select(): void {
          onSelectControl?.(row.control);
        }

        return (
          <div
            className={
              clickable
                ? `${styles.outOfCatalogRow} ${styles.outOfCatalogRowClickable}`
                : styles.outOfCatalogRow
            }
            key={row.control}
            data-testid={`out-of-catalog-${row.control}`}
            role={clickable ? "button" : undefined}
            tabIndex={clickable ? 0 : undefined}
            onClick={clickable ? select : undefined}
            onKeyDown={
              clickable
                ? (event) => {
                    if (event.key === "Enter" || event.key === " ") {
                      event.preventDefault();
                      select();
                    }
                  }
                : undefined
            }
          >
            <Text weight="semibold">
              {row.control} ({row.framework})
            </Text>
            <StatusBadge status={row.status} />
            <ProvenanceBadge provenance={row.provenance} />
            <Text className={styles.outOfCatalogObserved} size={200}>
              {row.note}
            </Text>
          </div>
        );
      })}
    </section>
  );
}
