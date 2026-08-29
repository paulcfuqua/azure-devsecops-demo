import { Tab, TabList, type SelectTabData, type SelectTabEvent } from "@fluentui/react-components";
import type { FrameworkId } from "./types";
import type { JSX } from "react";

/** Human labels for the four framework ids the catalog's `mappings` key on.
 * Reference data, not a resource name -- CLAUDE.md's naming rule is about
 * Azure resource names (`mls-<app>-<env>-<type>`), not UI copy. Exported so
 * Board.tsx can name the active framework in its headline/cross-tab when a
 * filtered view is in effect (single source of truth for the label text). */
export const FRAMEWORK_LABELS: Record<FrameworkId, string> = {
  "nist-800-171r2": "NIST SP 800-171 Rev 2",
  "nist-800-53r5": "NIST SP 800-53 Rev 5 (mapped)",
  "cmmc-2.0": "CMMC 2.0",
  "far-52.204-21": "FAR 52.204-21 (CMMC Level 1)",
};

const FRAMEWORK_IDS: readonly FrameworkId[] = [
  "nist-800-171r2",
  "nist-800-53r5",
  "cmmc-2.0",
  "far-52.204-21",
];

export interface FrameworkSwitcherProps {
  framework: FrameworkId;
  onChange: (framework: FrameworkId) => void;
}

/**
 * Filters and relabels the same 110 assessment records under a different
 * framework's ids -- no second data source. Board.tsx (via `frameworkLabel`)
 * does the actual relabeling/filtering; this component only picks which
 * framework is in effect.
 */
export function FrameworkSwitcher({ framework, onChange }: FrameworkSwitcherProps): JSX.Element {
  const onTabSelect = (_: SelectTabEvent, data: SelectTabData): void => {
    onChange(data.value as FrameworkId);
  };

  return (
    <TabList selectedValue={framework} onTabSelect={onTabSelect} aria-label="Framework view">
      {FRAMEWORK_IDS.map((id) => (
        <Tab value={id} key={id} data-testid={`framework-tab-${id}`}>
          {FRAMEWORK_LABELS[id]}
        </Tab>
      ))}
    </TabList>
  );
}
