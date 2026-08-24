/**
 * UI-free build entry — published as `@mls/spec-renderer/validate`.
 *
 * This module is the single source of truth for the copilot's output contract
 * on the server side. Its import graph is deliberately limited to
 * `./validate` -> (ajv, ../spec.schema.json) and the type-only `./types`, so
 * it loads in a plain Node process. It must NEVER import React, ReactDOM,
 * `@fluentui/*`, or anything under `src/components/` — the package root entry
 * (`@mls/spec-renderer`) is where those live, and pulling them in here would
 * reintroduce the module-scope browser dependency that made `validateSpec`
 * unusable from `copilot-svc`.
 *
 * `tests/node/import-graph.test.ts` enforces that rule automatically.
 */
export {
  isSpec,
  specSchema,
  validateSpec,
  type SpecValidationError,
  type SpecValidationResult,
} from "./validate";
export type {
  AreaChartSpec,
  BarChartSpec,
  ComponentSpec,
  ComponentType,
  DataTableCell,
  DataTableColumn,
  DataTableSpec,
  DonutChartSpec,
  KpiItem,
  KpiRowSpec,
  LabelValuePoint,
  Layout,
  LineChartSpec,
  MarkdownBlockSpec,
  Spec,
  StatCardSpec,
  TimelineEvent,
  TimelineEventKind,
  TimelineSpec,
  Trend,
  XyPoint,
} from "./types";
