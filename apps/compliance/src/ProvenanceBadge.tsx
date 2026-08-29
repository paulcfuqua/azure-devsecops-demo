import { Badge, type BadgeProps } from "@fluentui/react-components";
import type { Provenance } from "./types";
import type { JSX } from "react";

/**
 * Provenance -> Badge colour. This badge shows a SINGLE control row's own
 * provenance value, which is fine to render plainly -- the hazard this
 * platform guards against is a bare *aggregate* total
 * (`summary.byProvenance["machine-verified"]`), never a single row's own
 * value. See Board.tsx / FamilyCard.tsx, which read
 * `summary.byProvenanceAndStatus` exclusively for anything aggregate.
 *
 * `machine-verified` does not mean passing -- a criterion a machine
 * explicitly declined to run also earns it (SKIP -> INCONCLUSIVE). COMPLIANT
 * is the only status that means verified and passing, so this badge is
 * always shown beside a StatusBadge, never in place of one.
 */
const PROVENANCE_COLOR: Record<Provenance, BadgeProps["color"]> = {
  "machine-verified": "brand",
  asserted: "subtle",
  declared: "subtle",
  none: "subtle",
};

export interface ProvenanceBadgeProps {
  provenance: Provenance;
}

export function ProvenanceBadge({ provenance }: ProvenanceBadgeProps): JSX.Element {
  return (
    <Badge
      appearance="outline"
      data-testid="provenance"
      color={PROVENANCE_COLOR[provenance]}
      aria-label={`provenance: ${provenance}`}
    >
      {provenance}
    </Badge>
  );
}
