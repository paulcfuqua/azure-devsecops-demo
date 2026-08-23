import { makeStyles, tokens } from "@fluentui/react-components";
import type { ReactNode } from "react";
import { renderMarkdown } from "../markdown";
import type { MarkdownBlockSpec } from "../types";
import { Section } from "./Section";

const useStyles = makeStyles({
  body: {
    color: tokens.colorNeutralForeground1,
    fontSize: tokens.fontSizeBase300,
    lineHeight: tokens.lineHeightBase300,
    display: "flex",
    flexDirection: "column",
    rowGap: tokens.spacingVerticalS,
  },
});

export function MarkdownBlockView({ spec }: { spec: MarkdownBlockSpec }): ReactNode {
  const styles = useStyles();
  return (
    <Section title={spec.title}>
      <div className={styles.body}>{renderMarkdown(spec.markdown)}</div>
    </Section>
  );
}
