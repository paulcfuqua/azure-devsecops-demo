import { Text, makeStyles, tokens } from "@fluentui/react-components";
import type { ControlRow, StatusCounts } from "./types";
import { STATUS_KEYS } from "./types";
import { StatusBadge } from "./StatusBadge";
import { ProvenanceBadge } from "./ProvenanceBadge";
import type { JSX } from "react";

const useStyles = makeStyles({
  card: {
    border: `1px solid ${tokens.colorNeutralStroke2}`,
    borderRadius: tokens.borderRadiusMedium,
    padding: "0.75rem 1rem",
    marginBottom: "0.75rem",
  },
  heading: {
    display: "flex",
    alignItems: "baseline",
    gap: "0.5rem",
    flexWrap: "wrap",
  },
  row: {
    display: "flex",
    alignItems: "baseline",
    gap: "0.5rem",
    flexWrap: "wrap",
    padding: "0.35rem 0",
    borderTop: `1px solid ${tokens.colorNeutralStroke3}`,
    cursor: "default",
  },
  rowClickable: {
    cursor: "pointer",
    ":hover": { backgroundColor: tokens.colorNeutralBackground3 },
  },
  observed: {
    display: "block",
    color: tokens.colorNeutralForeground2,
  },
  empty: {
    color: tokens.colorNeutralForeground3,
    fontStyle: "italic",
    display: "block",
    padding: "0.35rem 0",
  },
});

/** Non-zero-only summary string, e.g. "GAP 1 · PARTIAL 3 · NOT_ASSESSED 6". */
function summarizeCounts(counts: StatusCounts): string {
  return STATUS_KEYS.filter((key) => counts[key] > 0)
    .map((key) => `${key} ${counts[key]}`)
    .join(" · ");
}

export interface FamilyCardEntry {
  control: ControlRow;
  /**
   * Display label under the framework currently in effect: the control's
   * own id under the catalog's native framework, or its mapped id(s) under
   * any other framework (Board.tsx's `frameworkLabel`). The `data-testid`
   * below is always keyed on `control.control` (the underlying 110-catalog
   * id) regardless of this label, so a framework switch relabels a row
   * without ever changing which record a click resolves to.
   */
  label: string;
}

export interface FamilyCardProps {
  id: string;
  name: string;
  counts: StatusCounts;
  controls: FamilyCardEntry[];
  onSelectControl?: (control: string) => void;
}

export function FamilyCard({ id, name, counts, controls, onSelectControl }: FamilyCardProps): JSX.Element {
  const styles = useStyles();
  return (
    <section className={styles.card} data-testid="family-card">
      <div className={styles.heading}>
        <Text weight="semibold">
          {id} {name}
        </Text>
        <Text size={200}>{summarizeCounts(counts) || "no data"}</Text>
      </div>
      {controls.length === 0 ? (
        <Text as="p" size={200} className={styles.empty}>
          No requirements in this family map to the selected framework.
        </Text>
      ) : (
        controls.map(({ control, label }) => (
          <ControlLine
            key={control.control}
            control={control}
            label={label}
            onSelectControl={onSelectControl}
          />
        ))
      )}
    </section>
  );
}

function ControlLine({
  control,
  label,
  onSelectControl,
}: {
  control: ControlRow;
  label: string;
  onSelectControl?: (control: string) => void;
}): JSX.Element {
  const styles = useStyles();
  const clickable = Boolean(onSelectControl);

  function select(): void {
    onSelectControl?.(control.control);
  }

  return (
    <div
      className={clickable ? `${styles.row} ${styles.rowClickable}` : styles.row}
      data-testid={`control-${control.control}`}
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
      <Text weight="semibold">{label}</Text>
      <StatusBadge status={control.status} />
      <ProvenanceBadge provenance={control.provenance} />
      {/* Authored/observed prose -- rendered as text via JSX interpolation
       * (React escapes by default), never dangerouslySetInnerHTML, and
       * never keyword-matched to pick a colour. */}
      <Text className={styles.observed} size={200}>
        {control.observed}
      </Text>
    </div>
  );
}
