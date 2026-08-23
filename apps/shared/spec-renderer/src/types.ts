/**
 * TypeScript mirror of spec.schema.json. The JSON Schema is the source of
 * truth for the copilot contract; these types exist for library consumers.
 */

export type Layout = "stack" | "grid";

export type Trend = "up" | "down" | "flat";

export interface XyPoint {
  x: string | number;
  y: number;
}

export interface LabelValuePoint {
  label: string;
  value: number;
}

interface FormattingHints {
  /** Display unit appended to formatted values, e.g. "%", "kg", "$". */
  unit?: string;
  /** Number of fraction digits when formatting numeric values (0-6). */
  decimals?: number;
}

export interface BarChartSpec extends FormattingHints {
  type: "barChart";
  title: string;
  description?: string;
  data: XyPoint[];
}

export interface LineChartSpec extends FormattingHints {
  type: "lineChart";
  title: string;
  description?: string;
  data: XyPoint[];
}

export interface AreaChartSpec extends FormattingHints {
  type: "areaChart";
  title: string;
  description?: string;
  data: XyPoint[];
}

export interface StatCardSpec extends FormattingHints {
  type: "statCard";
  title: string;
  description?: string;
  value: number | string;
  trend?: Trend;
  /** Change versus the previous period, shown next to the trend arrow. */
  delta?: number;
}

export interface KpiItem extends FormattingHints {
  label: string;
  value: number | string;
  trend?: Trend;
}

export interface KpiRowSpec {
  type: "kpiRow";
  title: string;
  description?: string;
  items: KpiItem[];
}

export interface DataTableColumn {
  key: string;
  label: string;
  align?: "left" | "center" | "right";
}

export type DataTableCell = string | number | boolean | null;

export interface DataTableSpec {
  type: "dataTable";
  title: string;
  description?: string;
  columns: DataTableColumn[];
  rows: Array<Record<string, DataTableCell>>;
}

export type TimelineEventKind = "info" | "success" | "warning" | "danger";

export interface TimelineEvent {
  date: string;
  label: string;
  description?: string;
  kind?: TimelineEventKind;
}

export interface TimelineSpec {
  type: "timeline";
  title: string;
  description?: string;
  events: TimelineEvent[];
}

export interface DonutChartSpec extends FormattingHints {
  type: "donutChart";
  title: string;
  description?: string;
  data: LabelValuePoint[];
}

export interface MarkdownBlockSpec {
  type: "markdownBlock";
  title?: string;
  markdown: string;
}

export type ComponentSpec =
  | BarChartSpec
  | LineChartSpec
  | AreaChartSpec
  | StatCardSpec
  | KpiRowSpec
  | DataTableSpec
  | TimelineSpec
  | DonutChartSpec
  | MarkdownBlockSpec;

export type ComponentType = ComponentSpec["type"];

export interface Spec {
  version: "1";
  layout: Layout;
  components: ComponentSpec[];
}
