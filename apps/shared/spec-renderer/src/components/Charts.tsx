import {
  AreaChart,
  DonutChart,
  LineChart,
  VerticalBarChart,
  type ChartProps,
  type LineChartDataPoint,
} from "@fluentui/react-charts";
import type { ReactNode } from "react";
import { formatValue } from "../format";
import type {
  AreaChartSpec,
  BarChartSpec,
  DonutChartSpec,
  LineChartSpec,
  XyPoint,
} from "../types";
import { Section } from "./Section";

const CHART_HEIGHT = 280;

/**
 * LineChart/AreaChart accept only number | Date x values. The spec allows
 * string x too, so coerce: all-numeric stays numeric, parseable dates become
 * Dates, anything else falls back to evenly spaced index positions.
 */
function coerceLinePoints(data: XyPoint[]): LineChartDataPoint[] {
  if (data.every((p) => typeof p.x === "number")) {
    return data.map((p) => ({ x: p.x as number, y: p.y }));
  }
  const timestamps = data.map((p) =>
    typeof p.x === "string" ? Date.parse(p.x) : Number.NaN,
  );
  if (timestamps.every((t) => !Number.isNaN(t))) {
    return data.map((p, i) => ({ x: new Date(timestamps[i] as number), y: p.y }));
  }
  return data.map((p, i) => ({ x: i, y: p.y }));
}

function toLineData(title: string, data: XyPoint[]): ChartProps {
  return {
    lineChartData: [{ legend: title, data: coerceLinePoints(data) }],
  };
}

export function BarChartView({ spec }: { spec: BarChartSpec }): ReactNode {
  return (
    <Section title={spec.title} description={spec.description}>
      <VerticalBarChart
        // `color` only when the spec sets one; otherwise the library keeps its
        // categorical palette. Spreading an undefined colour makes Fluent fall
        // back to black rather than to its own palette.
        data={spec.data.map((p) => (p.color ? { x: p.x, y: p.y, color: p.color } : { x: p.x, y: p.y }))}
        height={CHART_HEIGHT}
        hideLegend
        yAxisTickFormat={(value: number | string) =>
          typeof value === "number" ? formatValue(value, { decimals: spec.decimals }) : String(value)
        }
      />
    </Section>
  );
}

export function LineChartView({ spec }: { spec: LineChartSpec }): ReactNode {
  return (
    <Section title={spec.title} description={spec.description}>
      <LineChart data={toLineData(spec.title, spec.data)} height={CHART_HEIGHT} hideLegend />
    </Section>
  );
}

export function AreaChartView({ spec }: { spec: AreaChartSpec }): ReactNode {
  return (
    <Section title={spec.title} description={spec.description}>
      <AreaChart data={toLineData(spec.title, spec.data)} height={CHART_HEIGHT} hideLegend />
    </Section>
  );
}

export function DonutChartView({ spec }: { spec: DonutChartSpec }): ReactNode {
  const total = spec.data.reduce((sum, p) => sum + p.value, 0);
  return (
    <Section title={spec.title} description={spec.description}>
      <DonutChart
        data={{
          chartData: spec.data.map((p) => ({ legend: p.label, data: p.value })),
        }}
        innerRadius={58}
        height={CHART_HEIGHT}
        valueInsideDonut={formatValue(total, spec)}
      />
    </Section>
  );
}
