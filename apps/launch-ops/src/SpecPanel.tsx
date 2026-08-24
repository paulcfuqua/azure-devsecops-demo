import {
  MessageBar,
  MessageBarBody,
  MessageBarTitle,
  Spinner,
} from "@fluentui/react-components";
import { SpecRenderer, type Spec } from "@mls/spec-renderer";
import { useEffect, useState } from "react";

export interface SpecPanelProps {
  /** Builds the spec for this panel — a bound DataProvider method. */
  load: () => Promise<Spec>;
}

type PanelState =
  | { status: "loading" }
  | { status: "error"; message: string }
  | { status: "ready"; spec: Spec };

/**
 * Dumb view: awaits a provider-built spec and hands it to SpecRenderer.
 * All data shaping lives in the provider layer.
 */
export function SpecPanel({ load }: SpecPanelProps): JSX.Element {
  const [state, setState] = useState<PanelState>({ status: "loading" });

  useEffect(() => {
    let cancelled = false;
    setState({ status: "loading" });
    load().then(
      (spec) => {
        if (!cancelled) setState({ status: "ready", spec });
      },
      (err: unknown) => {
        if (!cancelled) {
          setState({
            status: "error",
            message: err instanceof Error ? err.message : String(err),
          });
        }
      },
    );
    return () => {
      cancelled = true;
    };
  }, [load]);

  if (state.status === "loading") {
    return <Spinner label="Loading data…" style={{ padding: "2rem" }} />;
  }
  if (state.status === "error") {
    return (
      <MessageBar intent="error">
        <MessageBarBody>
          <MessageBarTitle>Data unavailable</MessageBarTitle> {state.message}
        </MessageBarBody>
      </MessageBar>
    );
  }
  return <SpecRenderer spec={state.spec} />;
}
