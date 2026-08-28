import {
  Badge,
  FluentProvider,
  Tab,
  TabList,
  Text,
  Title2,
  Title3,
  tokens,
  webLightTheme,
  makeStyles,
  type BadgeProps,
  type SelectTabData,
  type SelectTabEvent,
} from "@fluentui/react-components";
import { useMemo, useState } from "react";
import type {
  CatalogRequirement,
  ComplianceCatalog,
  ComplianceState,
  ControlRow,
  ControlStatus,
  FrameworkId,
  Provenance,
} from "./types";
import { PROVENANCE_KEYS, STATUS_KEYS } from "./types";

// ============================================================================
// THE MOUNTING SEAM (read this before touching Board.tsx, ControlDetail.tsx,
// FrameworkSwitcher.tsx or Trend.tsx)
// ============================================================================
//
// Tasks 10, 11 and 12 each add a component that has to be wired up somewhere
// a person can reach it, but none of those tasks' Files lists this file --
// so all three end up editing it anyway. This seam exists so three
// independent edits land as three small, additive diffs instead of three
// competing rewrites, one of which wins and silently drops the other two's
// mounts.
//
// What this file owns, and how each task plugs in:
//
//   `framework: FrameworkId` (state below) -- which framework's mappings
//   label the board. Task 11's FrameworkSwitcher reads and sets it:
//       <FrameworkSwitcher framework={framework} onChange={setFramework} />
//   Nothing else should introduce a second, competing notion of "current
//   framework" -- Board, ControlDetail and the family summary below all
//   read this one piece of state.
//
//   `selectedControl: string | null` (state below) -- the control id under
//   inspection, or null when none is selected. Task 10's Board sets it (on
//   a control row click); Task 11's ControlDetail reads it:
//       {selectedControl && (
//         <ControlDetail control={selectedControl} state={state} catalog={catalog} />
//       )}
//   Render that beside or below the board -- see the `VIEW: "board"` case in
//   renderView() below for exactly where.
//
//   Two tabs, `"board"` and `"trend"` (VIEW_IDS below). The board tab's
//   content is FamilySummary, a scaffold placeholder good enough to satisfy
//   this task's own tests (family names, an unmissable NOT_ASSESSED count,
//   never a percentage) -- Task 10 replaces the FamilySummary element with
//   <Board state={state} catalog={catalog} framework={framework}
//          onSelectControl={setSelectedControl} /> and nothing else in
//   renderView() needs to move. The trend tab is a placeholder string;
//   Task 12 replaces it with <Trend history={history} />.
//
// Adding a genuinely new top-level view later: extend VIEW_IDS and the
// switch in renderView(). Do not replace the switch with a lookup table of
// components keyed by prop signatures that don't exist yet -- three tasks
// guessing at a shared interface is exactly the coordination problem this
// seam exists to avoid. Land the component, then extend the switch.
// ============================================================================

type ViewId = "board" | "trend";
const VIEW_IDS: readonly ViewId[] = ["board", "trend"];
const VIEW_LABELS: Record<ViewId, string> = {
  board: "Board",
  trend: "Trend",
};

export interface AppProps {
  state: ComplianceState;
  catalog: ComplianceCatalog;
  /**
   * Preceding state artifacts (oldest first), for Task 12's trend view.
   * Optional so this task's own tests -- and anything else that only cares
   * about the current snapshot -- don't have to supply history nothing yet
   * reads. main.tsx wires the real thing from every compliance/state/*.json
   * Vite bundles in; an omitted prop degrades to "no history yet" rather
   * than throwing.
   */
  history?: ComplianceState[];
}

const useStyles = makeStyles({
  shell: {
    minHeight: "100vh",
    backgroundColor: tokens.colorNeutralBackground2,
  },
  header: {
    display: "flex",
    flexDirection: "column",
    gap: "0.25rem",
    padding: "1.25rem 1.5rem 0.5rem",
  },
  content: {
    padding: "1rem 1.5rem 2rem",
    maxWidth: "1200px",
  },
  footer: {
    padding: "0 1.5rem 1.5rem",
    color: tokens.colorNeutralForeground3,
  },
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
  familyCard: {
    border: `1px solid ${tokens.colorNeutralStroke2}`,
    borderRadius: tokens.borderRadiusMedium,
    padding: "0.75rem 1rem",
    marginBottom: "0.75rem",
  },
  familyHeading: {
    display: "flex",
    alignItems: "baseline",
    gap: "0.5rem",
    flexWrap: "wrap",
  },
  controlRow: {
    display: "flex",
    alignItems: "baseline",
    gap: "0.5rem",
    flexWrap: "wrap",
    padding: "0.35rem 0",
    borderTop: `1px solid ${tokens.colorNeutralStroke3}`,
  },
  controlObserved: {
    display: "block",
    color: tokens.colorNeutralForeground2,
  },
  outOfCatalogSection: {
    marginTop: "1.5rem",
    paddingTop: "1rem",
    borderTop: `2px dashed ${tokens.colorNeutralStroke2}`,
  },
});

// Status -> Badge colour. This is a scaffold choice, not a fixed design:
// Task 10 owns StatusBadge.tsx and is free to choose differently. The rule
// that must survive whatever it picks: colour alone never carries the
// distinction (every badge also carries its own text), and NOT_ASSESSED
// must read as visually distinct from both GAP (a look that failed) and
// NOT_APPLICABLE (a look that was excused) -- "we have not looked" is a
// third thing, not a shade of either.
const STATUS_COLOR: Record<ControlStatus, BadgeProps["color"]> = {
  COMPLIANT: "success",
  PARTIAL: "warning",
  GAP: "danger",
  INCONCLUSIVE: "severe",
  NOT_APPLICABLE: "subtle",
  NOT_ASSESSED: "informative",
};

const PROVENANCE_COLOR: Record<Provenance, BadgeProps["color"]> = {
  "machine-verified": "brand",
  asserted: "subtle",
  declared: "subtle",
  none: "subtle",
};

function StatusPill({ status }: { status: ControlStatus }): JSX.Element {
  return (
    <Badge color={STATUS_COLOR[status]} aria-label={`status: ${status}`}>
      {status}
    </Badge>
  );
}

function ProvenancePill({ provenance }: { provenance: Provenance }): JSX.Element {
  return (
    <Badge
      appearance="outline"
      color={PROVENANCE_COLOR[provenance]}
      aria-label={`provenance: ${provenance}`}
    >
      {provenance}
    </Badge>
  );
}

function emptyStatusCounts(): Record<ControlStatus, number> {
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
  controls: ControlRow[];
  counts: Record<ControlStatus, number>;
}

/** Groups by the CATALOG's family list (always the full 14, in catalog
 * order) so a family with zero assessed controls still gets a row -- never
 * derive the family list from `state.controls` alone, or a family nothing
 * was ever said about would silently vanish instead of showing 100%
 * NOT_ASSESSED. `outOfCatalogControls` never enters this grouping: it has
 * no `family` a catalog requirement owns, and joining it in here is exactly
 * the cross-attribution the data contract forbids. */
function groupByFamily(
  state: ComplianceState,
  catalog: ComplianceCatalog,
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
    const controls = byFamily.get(id) ?? [];
    const counts = emptyStatusCounts();
    for (const control of controls) counts[control.status] += 1;
    return { id, name: names.get(id) ?? id, controls, counts };
  });
}

/** Non-zero-only summary string, e.g. "GAP 1 - PARTIAL 3 - NOT_ASSESSED 6".
 * A compact per-family line, not a substitute for the always-render-every-
 * key totals in the header callout and the provenance matrix below. */
function summarizeCounts(counts: Record<ControlStatus, number>): string {
  return STATUS_KEYS.filter((key) => counts[key] > 0)
    .map((key) => `${key} ${counts[key]}`)
    .join(" · ");
}

/**
 * The Task 9 scaffold's own placeholder for the board. Deliberately minimal
 * -- Task 10 replaces this element (not this file's structure) with the
 * real <Board>. Kept inline rather than in its own file so that replacement
 * is a clean swap with nothing left over to delete.
 */
function FamilySummary({
  state,
  catalog,
}: {
  state: ComplianceState;
  catalog: ComplianceCatalog;
}): JSX.Element {
  const styles = useStyles();
  const families = useMemo(() => groupByFamily(state, catalog), [state, catalog]);
  const { summary } = state;

  return (
    <div>
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
        <section className={styles.familyCard} key={family.id} data-testid="family-summary">
          <div className={styles.familyHeading}>
            <Text weight="semibold">
              {family.id} {family.name}
            </Text>
            <Text size={200}>{summarizeCounts(family.counts) || "no data"}</Text>
          </div>
          {family.controls.map((control) => (
            <div className={styles.controlRow} key={control.control}>
              <Text weight="semibold">{control.control}</Text>
              <StatusPill status={control.status} />
              <ProvenancePill provenance={control.provenance} />
              <Text className={styles.controlObserved} size={200}>
                {control.observed}
              </Text>
            </div>
          ))}
        </section>
      ))}

      {state.outOfCatalogControls.length > 0 && (
        <section className={styles.outOfCatalogSection}>
          <Title3 as="h3">Assessed under other frameworks</Title3>
          <Text as="p" size={200}>
            Not part of the {summary.totalRequirements}-requirement catalog above.
            Each row below carries an orientation-only mapping to a catalog
            requirement; that mapping is never applied to the requirement's own
            status.
          </Text>
          {state.outOfCatalogControls.map((row) => (
            <div className={styles.controlRow} key={row.control}>
              <Text weight="semibold">
                {row.control} ({row.framework})
              </Text>
              <StatusPill status={row.status} />
              <ProvenancePill provenance={row.provenance} />
              <Text className={styles.controlObserved} size={200}>
                {row.note}
              </Text>
            </div>
          ))}
        </section>
      )}
    </div>
  );
}

export function App({ state, catalog, history = [] }: AppProps): JSX.Element {
  const styles = useStyles();
  const [view, setView] = useState<ViewId>("board");
  // Owned here for Task 11's FrameworkSwitcher / ControlDetail -- see the
  // seam comment at the top of this file.
  const [framework, setFramework] = useState<FrameworkId>(
    state.framework as FrameworkId,
  );
  const [selectedControl, setSelectedControl] = useState<string | null>(null);
  // `framework`, `setFramework`, `selectedControl` and `setSelectedControl`
  // are not read anywhere in this file yet -- they exist for Task 11 to
  // thread into FrameworkSwitcher/ControlDetail per the seam comment above.
  // There is no lint step in this repo to placate (no eslint config in the
  // tree) and `noUnusedLocals` is off, so this compiles clean as-is.

  const onTabSelect = (_: SelectTabEvent, data: SelectTabData): void => {
    setView(data.value as ViewId);
  };

  function renderView(): JSX.Element {
    switch (view) {
      case "board":
        // Task 10 replaces <FamilySummary .../> with:
        //   <Board state={state} catalog={catalog} framework={framework}
        //          onSelectControl={setSelectedControl} />
        // Task 11 additionally renders <FrameworkSwitcher .../> above it and,
        // when selectedControl is set, <ControlDetail .../> alongside it.
        return <FamilySummary state={state} catalog={catalog} />;
      case "trend":
        // Task 12 replaces this with <Trend history={history} />.
        return (
          <Text as="p">
            Trend view lands in a later task. {history.length} preceding
            snapshot{history.length === 1 ? "" : "s"} already bundled.
          </Text>
        );
    }
  }

  return (
    <FluentProvider theme={webLightTheme}>
      <div className={styles.shell}>
        <header className={styles.header}>
          <Title2>Meridian Launch Systems — Compliance</Title2>
          <Text>
            {state.frameworkName}. Counts by status and provenance only —
            never a blended percentage, score or ratio.
          </Text>
          <Text size={200}>
            Collected {state.collectedAt} from commit {state.commitShort} (
            {state.workingTreeClean ? "clean tree" : "tree had uncommitted changes"}
            ).
          </Text>
        </header>
        <TabList selectedValue={view} onTabSelect={onTabSelect} style={{ padding: "0 1rem" }}>
          {VIEW_IDS.map((id) => (
            <Tab value={id} key={id}>
              {VIEW_LABELS[id]}
            </Tab>
          ))}
        </TabList>
        <main className={styles.content}>{renderView()}</main>
        <footer className={styles.footer}>
          <Text size={200}>
            Synthetic data — Meridian Launch Systems is fictional.{" "}
            {state.collectors.length} collectors ran; see state.collectors for
            each one's limitation.
          </Text>
        </footer>
      </div>
    </FluentProvider>
  );
}
