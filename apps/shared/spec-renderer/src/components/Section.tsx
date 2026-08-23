import { Text, makeStyles, tokens } from "@fluentui/react-components";
import type { ReactNode } from "react";

const useStyles = makeStyles({
  root: {
    display: "flex",
    flexDirection: "column",
    rowGap: tokens.spacingVerticalS,
    minWidth: "0",
  },
  title: {
    color: tokens.colorNeutralForeground1,
  },
  description: {
    color: tokens.colorNeutralForeground3,
  },
});

export interface SectionProps {
  title?: string;
  description?: string;
  children: ReactNode;
}

/** Shared title/description chrome around every rendered component. */
export function Section({ title, description, children }: SectionProps): ReactNode {
  const styles = useStyles();
  return (
    <section className={styles.root}>
      {title !== undefined && (
        <Text as="h3" weight="semibold" size={400} className={styles.title}>
          {title}
        </Text>
      )}
      {description !== undefined && (
        <Text size={200} className={styles.description}>
          {description}
        </Text>
      )}
      {children}
    </section>
  );
}
