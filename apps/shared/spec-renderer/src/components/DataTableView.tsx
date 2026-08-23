import {
  Table,
  TableBody,
  TableCell,
  TableHeader,
  TableHeaderCell,
  TableRow,
  Text,
  makeStyles,
  tokens,
} from "@fluentui/react-components";
import type { ReactNode } from "react";
import type { DataTableCell, DataTableSpec } from "../types";
import { Section } from "./Section";

const useStyles = makeStyles({
  scroller: {
    overflowX: "auto",
  },
  empty: {
    color: tokens.colorNeutralForeground3,
  },
});

function cellText(value: DataTableCell | undefined): string {
  if (value === null || value === undefined) {
    return "—";
  }
  if (typeof value === "boolean") {
    return value ? "Yes" : "No";
  }
  if (typeof value === "number") {
    return value.toLocaleString("en-US");
  }
  return value;
}

export function DataTableView({ spec }: { spec: DataTableSpec }): ReactNode {
  const styles = useStyles();
  return (
    <Section title={spec.title} description={spec.description}>
      <div className={styles.scroller}>
        <Table size="small" aria-label={spec.title}>
          <TableHeader>
            <TableRow>
              {spec.columns.map((col) => (
                <TableHeaderCell key={col.key} style={{ textAlign: col.align ?? "left" }}>
                  {col.label}
                </TableHeaderCell>
              ))}
            </TableRow>
          </TableHeader>
          <TableBody>
            {spec.rows.map((row, i) => (
              <TableRow key={i}>
                {spec.columns.map((col) => (
                  <TableCell key={col.key} style={{ textAlign: col.align ?? "left" }}>
                    {cellText(row[col.key])}
                  </TableCell>
                ))}
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
      {spec.rows.length === 0 && (
        <Text size={200} className={styles.empty}>
          No rows
        </Text>
      )}
    </Section>
  );
}
