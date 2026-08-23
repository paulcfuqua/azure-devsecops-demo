export interface FormatHints {
  unit?: string;
  decimals?: number;
}

const NO_SPACE_UNITS = new Set(["%", "°", "″", "′"]);

/** Format a value for display honoring the spec's unit/decimals hints. */
export function formatValue(value: number | string, hints: FormatHints = {}): string {
  let text: string;
  if (typeof value === "number") {
    text = value.toLocaleString("en-US", {
      minimumFractionDigits: hints.decimals,
      maximumFractionDigits: hints.decimals ?? 3,
    });
  } else {
    text = value;
  }
  if (hints.unit && typeof value === "number") {
    text += NO_SPACE_UNITS.has(hints.unit) ? hints.unit : ` ${hints.unit}`;
  }
  return text;
}
