import {
  MessageBar,
  MessageBarBody,
  MessageBarTitle,
  makeStyles,
  tokens,
} from "@fluentui/react-components";
import type { ErrorInfo, ReactNode } from "react";
import { Component, useMemo } from "react";
import {
  AreaChartView,
  BarChartView,
  DonutChartView,
  LineChartView,
} from "./components/Charts";
import { DataTableView } from "./components/DataTableView";
import { KpiRowView } from "./components/KpiRow";
import { MarkdownBlockView } from "./components/MarkdownBlockView";
import { StatCardView } from "./components/StatCard";
import { TimelineView } from "./components/TimelineView";
import type { ComponentSpec, Spec } from "./types";
import { validateSpec, type SpecValidationError } from "./validate";

const MAX_ERRORS_SHOWN = 10;

const useStyles = makeStyles({
  stack: {
    display: "flex",
    flexDirection: "column",
    rowGap: tokens.spacingVerticalL,
  },
  grid: {
    display: "grid",
    gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))",
    gap: tokens.spacingHorizontalL,
    alignItems: "start",
  },
  errorList: {
    margin: "0",
    paddingLeft: tokens.spacingHorizontalXL,
  },
});

function ComponentView({ spec }: { spec: ComponentSpec }): ReactNode {
  switch (spec.type) {
    case "barChart":
      return <BarChartView spec={spec} />;
    case "lineChart":
      return <LineChartView spec={spec} />;
    case "areaChart":
      return <AreaChartView spec={spec} />;
    case "statCard":
      return <StatCardView spec={spec} />;
    case "kpiRow":
      return <KpiRowView spec={spec} />;
    case "dataTable":
      return <DataTableView spec={spec} />;
    case "timeline":
      return <TimelineView spec={spec} />;
    case "donutChart":
      return <DonutChartView spec={spec} />;
    case "markdownBlock":
      return <MarkdownBlockView spec={spec} />;
  }
}

interface BoundaryProps {
  componentType: string;
  children: ReactNode;
}

interface BoundaryState {
  failed: boolean;
}

/**
 * Last line of defense: a component that throws mid-render (e.g. a chart edge
 * case) degrades to a warning bar instead of taking down the whole response.
 */
class ComponentErrorBoundary extends Component<BoundaryProps, BoundaryState> {
  state: BoundaryState = { failed: false };

  static getDerivedStateFromError(): BoundaryState {
    return { failed: true };
  }

  componentDidCatch(_error: Error, _info: ErrorInfo): void {
    // Intentionally swallowed: the renderer must never throw on bad input.
  }

  render(): ReactNode {
    if (this.state.failed) {
      return (
        <MessageBar intent="warning" data-testid="spec-renderer-component-error">
          <MessageBarBody>
            <MessageBarTitle>Component failed to render</MessageBarTitle>
            The {this.props.componentType} component could not be displayed.
          </MessageBarBody>
        </MessageBar>
      );
    }
    return this.props.children;
  }
}

function ValidationErrors({ errors }: { errors: SpecValidationError[] }): ReactNode {
  const styles = useStyles();
  const shown = errors.slice(0, MAX_ERRORS_SHOWN);
  const hidden = errors.length - shown.length;
  return (
    <MessageBar intent="error" layout="multiline" data-testid="spec-renderer-error">
      <MessageBarBody>
        <MessageBarTitle>Invalid spec</MessageBarTitle>
        The response does not match the component-spec schema and was not rendered.
        <ul className={styles.errorList}>
          {shown.map((e, i) => (
            <li key={i}>
              <code>{e.path}</code> — {e.message}
            </li>
          ))}
        </ul>
        {hidden > 0 && <>…and {hidden} more.</>}
      </MessageBarBody>
    </MessageBar>
  );
}

export interface SpecRendererProps {
  /** Untrusted JSON (e.g. straight from the copilot). Validated before rendering. */
  spec: unknown;
}

/**
 * Fixed renderer for copilot output: validates the JSON spec against
 * spec.schema.json, then renders the corresponding Fluent UI components.
 * Invalid input renders an error MessageBar — this component never throws.
 */
export function SpecRenderer({ spec }: SpecRendererProps): ReactNode {
  const styles = useStyles();
  const result = useMemo(() => validateSpec(spec), [spec]);

  if (!result.ok) {
    return <ValidationErrors errors={result.errors} />;
  }

  const validSpec = spec as Spec;
  return (
    <div className={validSpec.layout === "grid" ? styles.grid : styles.stack}>
      {validSpec.components.map((component, i) => (
        <ComponentErrorBoundary key={i} componentType={component.type}>
          <ComponentView spec={component} />
        </ComponentErrorBoundary>
      ))}
    </div>
  );
}
