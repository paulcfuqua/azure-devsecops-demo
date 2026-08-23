import { Text, makeStyles, tokens } from "@fluentui/react-components";
import type { ReactNode } from "react";
import type { TimelineEventKind, TimelineSpec } from "../types";
import { Section } from "./Section";

const useStyles = makeStyles({
  list: {
    listStyleType: "none",
    margin: "0",
    padding: "0",
    display: "flex",
    flexDirection: "column",
    rowGap: tokens.spacingVerticalM,
  },
  item: {
    display: "grid",
    gridTemplateColumns: "auto 1fr",
    columnGap: tokens.spacingHorizontalM,
  },
  rail: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    rowGap: tokens.spacingVerticalXXS,
  },
  dot: {
    width: "10px",
    height: "10px",
    borderRadius: tokens.borderRadiusCircular,
    marginTop: "6px",
    flexShrink: 0,
  },
  line: {
    width: "2px",
    flexGrow: 1,
    backgroundColor: tokens.colorNeutralStroke2,
  },
  body: {
    display: "flex",
    flexDirection: "column",
    rowGap: tokens.spacingVerticalXXS,
    paddingBottom: tokens.spacingVerticalS,
  },
  date: {
    color: tokens.colorNeutralForeground3,
  },
  description: {
    color: tokens.colorNeutralForeground2,
  },
});

const KIND_COLOR: Record<TimelineEventKind, string> = {
  info: tokens.colorBrandBackground,
  success: tokens.colorPaletteGreenBackground3,
  warning: tokens.colorPaletteMarigoldBackground3,
  danger: tokens.colorPaletteRedBackground3,
};

export function TimelineView({ spec }: { spec: TimelineSpec }): ReactNode {
  const styles = useStyles();
  return (
    <Section title={spec.title} description={spec.description}>
      <ol className={styles.list}>
        {spec.events.map((event, i) => (
          <li key={i} className={styles.item}>
            <span className={styles.rail} aria-hidden="true">
              <span
                className={styles.dot}
                style={{ backgroundColor: KIND_COLOR[event.kind ?? "info"] }}
              />
              {i < spec.events.length - 1 && <span className={styles.line} />}
            </span>
            <span className={styles.body}>
              <Text size={200} className={styles.date}>
                {event.date}
              </Text>
              <Text size={300} weight="semibold">
                {event.label}
              </Text>
              {event.description !== undefined && (
                <Text size={200} className={styles.description}>
                  {event.description}
                </Text>
              )}
            </span>
          </li>
        ))}
      </ol>
    </Section>
  );
}
