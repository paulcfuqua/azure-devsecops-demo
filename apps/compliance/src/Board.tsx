import { Text, Title3, makeStyles, tokens } from "@fluentui/react-components";
import { useMemo } from "react";
import type {
  ComplianceCatalog,
  ComplianceState,
  ControlRow,
  FrameworkId,
  OutOfCatalogControlRow,
  StatusCounts,
} from "./types";
import { PROVENANCE_KEYS, STATUS_KEYS } from "./types";
import { FamilyCard, type FamilyCardEntry } from "./FamilyCard";
import { StatusBadge } from "./StatusBadge";
import { ProvenanceBadge } from "./ProvenanceBadge";

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
  },
  outOfCatalogObserved: {
    display: "block",
    color: tokens.colorNeutralForeground2,
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

interface FamilyGroup {
  id: string;
  name: string;
  counts: StatusCounts;
  controls: FamilyCardEntry[];
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
 */
function groupByFamily(
  state: ComplianceState,
  catalog: ComplianceCatalog,
  framework: FrameworkId,
): FamilyGroup[] {
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
  return order.map((id) => {
    const allControls = byFamily.get(id) ?? [];
    const counts = emptyStatusCounts();
    const controls: FamilyCardEntry[] = [];
    for (const control of allControls) {
      const label = frameworkLabel(control, framework);
      if (label === null) continue;
      counts[control.status] += 1;
      controls.push({ control, label });
    }
    return { id, name: names.get(id) ?? id, counts, controls };
  });
}

export interface BoardProps {
  state: ComplianceState;
  catalog: ComplianceCatalog;
  framework: FrameworkId;
  onSelectControl?: (control: string) => void;
}

export function Board({ state, catalog, framework, onSelectControl }: BoardProps): JSX.Element {
  const styles = useStyles();
  const families = useMemo(
    () => groupByFamily(state, catalog, framework),
    [state, catalog, framework],
  );
  const { summary } = state;

  return (
    <div>
      <Text as="p" data-testid="collected-at" className={styles.callout}>
        Collected <strong>{state.collectedAt}</strong> from commit {state.commitShort} (
        {state.workingTreeClean ? "clean tree" : "tree had uncommitted changes"}
        ).
      </Text>

      <Text as="p" className={styles.callout}>
        <strong>
          {summary.byStatus.NOT_ASSESSED} of {summary.totalRequirements}
        </strong>{" "}
        requirements are <strong>NOT_ASSESSED</strong> — nothing has been
        asserted or collected about them yet.
      </Text>

      <Title3 as="h3">By provenance and status</Title3>
      <Text as="p" size={200}>
        Never read a bare provenance total: a criterion a machine explicitly
        declined to run is still counted under machine-verified. Only the
        COMPLIANT column means verified and passing.
      </Text>
      <table className={styles.matrix} aria-label="Controls by provenance and status">
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
                <td key={status}>{summary.byProvenanceAndStatus[provenance][status]}</td>
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
        <OutOfCatalogSection controls={state.outOfCatalogControls} totalRequirements={summary.totalRequirements} />
      )}
    </div>
  );
}

/**
 * Always rendered on its own, regardless of `framework` -- these four rows
 * (CM-6, CP-9, IR-4, SI-4) were assessed against nist-800-53r5 directly and
 * have no requirement of their own in the 110-item catalog. They are never
 * folded into a family card above, and their `requirementsMappingToThisControl`
 * is shown here as orientation prose only, never as a live cross-reference
 * that would resolve their status onto the requirement rows above.
 */
function OutOfCatalogSection({
  controls,
  totalRequirements,
}: {
  controls: OutOfCatalogControlRow[];
  totalRequirements: number;
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
      {controls.map((row) => (
        <div className={styles.outOfCatalogRow} key={row.control} data-testid={`out-of-catalog-${row.control}`}>
          <Text weight="semibold">
            {row.control} ({row.framework})
          </Text>
          <StatusBadge status={row.status} />
          <ProvenanceBadge provenance={row.provenance} />
          <Text className={styles.outOfCatalogObserved} size={200}>
            {row.note}
          </Text>
        </div>
      ))}
    </section>
  );
}
