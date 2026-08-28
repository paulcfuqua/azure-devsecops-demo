import { Text, Title3, makeStyles, tokens } from "@fluentui/react-components";
import { useMemo } from "react";
import type { ComplianceState, ControlStatus, StatusCounts } from "./types";
import { STATUS_KEYS } from "./types";

const useStyles = makeStyles({
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
  callout: {
    display: "block",
    margin: "0.75rem 0 1rem",
    padding: "0.75rem 1rem",
    borderRadius: tokens.borderRadiusMedium,
    backgroundColor: tokens.colorNeutralBackground3,
    borderLeft: `4px solid ${tokens.colorPaletteBlueBorderActive}`,
  },
  transitions: {
    display: "flex",
    flexDirection: "column",
    gap: "0.25rem",
    listStyle: "none",
    margin: 0,
    padding: 0,
  },
  transition: {
    padding: "0.35rem 0.6rem",
    borderRadius: tokens.borderRadiusSmall,
    border: `1px solid ${tokens.colorNeutralStroke3}`,
  },
});

/**
 * Ranks statuses on a single verified/passing axis so a transition between
 * them can be called a regression or an improvement. NOT_APPLICABLE is
 * deliberately excluded -- it is a declared exclusion, not a point on a
 * compliance scale, so a transition into or out of it is reported as
 * "changed" rather than mislabelled better/worse.
 */
const RANK: Partial<Record<ControlStatus, number>> = {
  GAP: 0,
  NOT_ASSESSED: 1,
  INCONCLUSIVE: 1,
  PARTIAL: 2,
  COMPLIANT: 3,
};

type TransitionKind = "regressed" | "improved" | "changed";

interface Transition {
  control: string;
  from: ControlStatus;
  to: ControlStatus;
  /** The date of the collection the transition was first observed in
   * (the newer of the two adjacent snapshots being compared). */
  date: string;
  kind: TransitionKind;
}

function classify(from: ControlStatus, to: ControlStatus): TransitionKind {
  const rankFrom = RANK[from];
  const rankTo = RANK[to];
  if (rankFrom === undefined || rankTo === undefined) return "changed";
  if (rankTo < rankFrom) return "regressed";
  if (rankTo > rankFrom) return "improved";
  return "changed";
}

/** Compares each adjacent pair of collections (oldest-first) and lists
 * every control whose status differs between them, attributed to the date
 * of the newer collection -- "named the date a control regressed" per the
 * brief. Counts by status only, per collection; never a blended figure
 * across collections. */
function computeTransitions(history: ComplianceState[]): Transition[] {
  const transitions: Transition[] = [];
  for (let i = 1; i < history.length; i++) {
    const prev = history[i - 1];
    const curr = history[i];
    if (!prev || !curr) continue;
    const prevById = new Map(prev.controls.map((c) => [c.control, c] as const));
    const date = curr.collectedAt.slice(0, 10);
    for (const control of curr.controls) {
      const before = prevById.get(control.control);
      if (before && before.status !== control.status) {
        transitions.push({
          control: control.control,
          from: before.status,
          to: control.status,
          date,
          kind: classify(before.status, control.status),
        });
      }
    }
  }
  return transitions;
}

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

/** Tallies status counts directly from `snapshot.controls` rather than
 * trusting `snapshot.summary.byStatus` -- the two should always agree for a
 * real emitted artifact, but a test fixture (or any future producer of a
 * ComplianceState) that mutates `controls[].status` without also updating
 * the separately-maintained `summary` object would otherwise plot identical
 * counts for two collections that actually differ. Single source of truth:
 * the same array `computeTransitions` below already reads. */
function tallyByStatus(controls: ComplianceState["controls"]): StatusCounts {
  const counts = emptyStatusCounts();
  for (const control of controls) counts[control.status] += 1;
  return counts;
}

function SnapshotTable({ history }: { history: ComplianceState[] }): JSX.Element {
  const styles = useStyles();
  return (
    <table className={styles.matrix} aria-label="Status counts by collection date">
      <thead>
        <tr>
          <th scope="col">Collected</th>
          {STATUS_KEYS.map((status) => (
            <th scope="col" key={status}>
              {status}
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        {history.map((snapshot) => {
          const counts = tallyByStatus(snapshot.controls);
          return (
            <tr key={snapshot.collectedAt}>
              <th scope="row">{snapshot.collectedAt}</th>
              {STATUS_KEYS.map((status) => (
                <td key={status}>{counts[status]}</td>
              ))}
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

export interface TrendProps {
  /** Every collected state artifact this build bundled, in any order --
   * sorted here by `collectedAt` before use. Today there is exactly one
   * (see the single-collection branch below); the design exists so a
   * second dated collection needs no code change to start trending. */
  history: ComplianceState[];
}

export function Trend({ history }: TrendProps): JSX.Element {
  const styles = useStyles();
  const sorted = useMemo(
    () => [...history].sort((a, b) => a.collectedAt.localeCompare(b.collectedAt)),
    [history],
  );
  const transitions = useMemo(() => computeTransitions(sorted), [sorted]);

  if (sorted.length === 0) {
    return (
      <Text as="p" data-testid="trend-empty" className={styles.callout}>
        No collections yet. Once compliance.yml runs at least once, this view plots status
        counts across every committed <code>compliance/state/state-*.json</code> snapshot.
      </Text>
    );
  }

  if (sorted.length === 1) {
    const only = sorted[0];
    return (
      <div>
        <Text as="p" data-testid="trend-single-point" className={styles.callout}>
          One collection so far, on <strong>{only?.collectedAt}</strong>. A trend needs at
          least two dated collections to compare against each other — this is one collection,
          no trend yet, not an empty chart and not an error.
        </Text>
        <SnapshotTable history={sorted} />
      </div>
    );
  }

  return (
    <div>
      <Text as="p" className={styles.callout}>
        {sorted.length} collections, {sorted[0]?.collectedAt} to{" "}
        {sorted[sorted.length - 1]?.collectedAt}. Counts by status only — never a blended
        percentage, score or ratio.
      </Text>
      <div data-testid="trend-chart">
        <SnapshotTable history={sorted} />
      </div>
      <Title3 as="h3">Transitions</Title3>
      {transitions.length === 0 ? (
        <Text as="p">No control changed status between any two collections.</Text>
      ) : (
        <ul className={styles.transitions}>
          {transitions.map((t, i) => (
            <li key={i} className={styles.transition} data-testid="trend-transition">
              <Text>
                {t.control} {t.kind} from {t.from} to {t.to} on {t.date}
              </Text>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
