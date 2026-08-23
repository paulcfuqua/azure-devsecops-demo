import { Card, Text, makeStyles, tokens } from "@fluentui/react-components";
import type { ReactNode } from "react";
import { formatValue } from "../format";
import type { KpiItem, StatCardSpec, Trend } from "../types";

const useStyles = makeStyles({
  card: {
    display: "flex",
    flexDirection: "column",
    rowGap: tokens.spacingVerticalXS,
    minWidth: "160px",
  },
  label: {
    color: tokens.colorNeutralForeground3,
  },
  value: {
    color: tokens.colorNeutralForeground1,
    lineHeight: tokens.lineHeightHero700,
  },
  description: {
    color: tokens.colorNeutralForeground3,
  },
  trendUp: { color: tokens.colorPaletteGreenForeground1 },
  trendDown: { color: tokens.colorPaletteRedForeground1 },
  trendFlat: { color: tokens.colorNeutralForeground3 },
});

const TREND_GLYPH: Record<Trend, string> = { up: "▲", down: "▼", flat: "→" };

function TrendBadge({ trend, delta }: { trend: Trend; delta?: number }): ReactNode {
  const styles = useStyles();
  const cls =
    trend === "up" ? styles.trendUp : trend === "down" ? styles.trendDown : styles.trendFlat;
  return (
    <Text size={200} className={cls}>
      {TREND_GLYPH[trend]}
      {delta !== undefined ? ` ${formatValue(delta)}` : ""}
    </Text>
  );
}

export function StatCardView({ spec }: { spec: StatCardSpec }): ReactNode {
  const styles = useStyles();
  return (
    <Card className={styles.card} appearance="filled">
      <Text size={300} weight="semibold" className={styles.label}>
        {spec.title}
      </Text>
      <Text as="strong" size={800} weight="bold" className={styles.value}>
        {formatValue(spec.value, spec)}
      </Text>
      {spec.trend !== undefined && <TrendBadge trend={spec.trend} delta={spec.delta} />}
      {spec.description !== undefined && (
        <Text size={200} className={styles.description}>
          {spec.description}
        </Text>
      )}
    </Card>
  );
}

export function KpiTile({ item }: { item: KpiItem }): ReactNode {
  const styles = useStyles();
  return (
    <Card className={styles.card} appearance="filled">
      <Text size={300} weight="semibold" className={styles.label}>
        {item.label}
      </Text>
      <Text as="strong" size={600} weight="bold" className={styles.value}>
        {formatValue(item.value, item)}
      </Text>
      {item.trend !== undefined && <TrendBadge trend={item.trend} />}
    </Card>
  );
}
