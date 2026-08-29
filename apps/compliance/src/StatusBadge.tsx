import { Badge, type BadgeProps } from "@fluentui/react-components";
import type { ControlStatus } from "./types";
import type { JSX } from "react";

/**
 * Status -> Badge colour. NOT_ASSESSED ("we have not looked") must never
 * read as a shade of GAP ("we looked and it failed") or NOT_APPLICABLE
 * ("we looked and excused it") -- it is a third thing, distinct from both.
 * Colour is never the only signal either: the badge's own text is always
 * the literal status enum, and `aria-label` restates it for anything that
 * can't perceive colour at all.
 */
const STATUS_COLOR: Record<ControlStatus, BadgeProps["color"]> = {
  COMPLIANT: "success",
  PARTIAL: "warning",
  GAP: "danger",
  INCONCLUSIVE: "severe",
  NOT_APPLICABLE: "subtle",
  NOT_ASSESSED: "informative",
};

export interface StatusBadgeProps {
  status: ControlStatus;
}

export function StatusBadge({ status }: StatusBadgeProps): JSX.Element {
  return (
    <Badge data-testid="status" color={STATUS_COLOR[status]} aria-label={`status: ${status}`}>
      {status}
    </Badge>
  );
}
