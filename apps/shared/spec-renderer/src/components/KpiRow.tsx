import { makeStyles, tokens } from "@fluentui/react-components";
import type { ReactNode } from "react";
import type { KpiRowSpec } from "../types";
import { Section } from "./Section";
import { KpiTile } from "./StatCard";

const useStyles = makeStyles({
  row: {
    display: "flex",
    flexDirection: "row",
    flexWrap: "wrap",
    gap: tokens.spacingHorizontalM,
  },
});

export function KpiRowView({ spec }: { spec: KpiRowSpec }): ReactNode {
  const styles = useStyles();
  return (
    <Section title={spec.title} description={spec.description}>
      <div className={styles.row} role="list">
        {spec.items.map((item, i) => (
          <div role="listitem" key={`${item.label}-${i}`}>
            <KpiTile item={item} />
          </div>
        ))}
      </div>
    </Section>
  );
}
