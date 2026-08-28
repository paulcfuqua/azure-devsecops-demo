import {
  FluentProvider,
  Tab,
  TabList,
  Text,
  Title2,
  tokens,
  webLightTheme,
  makeStyles,
  type SelectTabData,
  type SelectTabEvent,
} from "@fluentui/react-components";
import { useState } from "react";
import type { ComplianceCatalog, ComplianceState, FrameworkId } from "./types";
import { Board } from "./Board";
import { ControlDetail } from "./ControlDetail";
import { FrameworkSwitcher } from "./FrameworkSwitcher";
import { Trend } from "./Trend";

// ============================================================================
// THE MOUNTING SEAM (read this before touching Board.tsx, ControlDetail.tsx,
// FrameworkSwitcher.tsx or Trend.tsx)
// ============================================================================
//
// Tasks 10, 11 and 12 each added a component that had to be wired up
// somewhere a person can reach it, but none of those tasks' Files lists this
// file -- so all three landed here too, as small additive diffs against this
// seam rather than three competing rewrites of this file.
//
// What this file owns:
//
//   `framework: FrameworkId` -- which framework's mappings label the board.
//   Set by FrameworkSwitcher; read by Board (relabels/filters the same 110
//   records, never a second data source) and passed to ControlDetail's
//   selection below. Nothing else introduces a second, competing notion of
//   "current framework".
//
//   `selectedControl: string | null` -- the control id under inspection, or
//   null when none is selected. Set by Board (via `onSelectControl`, on a
//   control row click) and by FrameworkSwitcher's `onChange` (cleared, since
//   a control selected under one framework's labels may not be the same row
//   under another); read by ControlDetail, rendered only when non-null.
//
//   Two tabs, `"board"` and `"trend"` (VIEW_IDS below). The board tab
//   renders FrameworkSwitcher, Board and (when a control is selected)
//   ControlDetail. The trend tab renders Trend, given every dated
//   `compliance/state/state-*.json` snapshot main.tsx bundled (oldest
//   first) as `history`.
//
// Adding a genuinely new top-level view later: extend VIEW_IDS and the
// switch in renderView(). Do not replace the switch with a lookup table of
// components keyed by prop signatures that don't exist yet -- three tasks
// guessing at a shared interface is exactly the coordination problem this
// seam existed to avoid during Tasks 10-12. Land the component, then extend
// the switch.
// ============================================================================

type ViewId = "board" | "trend";
const VIEW_IDS: readonly ViewId[] = ["board", "trend"];
const VIEW_LABELS: Record<ViewId, string> = {
  board: "Board",
  trend: "Trend",
};

export interface AppProps {
  state: ComplianceState;
  catalog: ComplianceCatalog;
  /**
   * Preceding state artifacts (oldest first), for Task 12's trend view.
   * Optional so this task's own tests -- and anything else that only cares
   * about the current snapshot -- don't have to supply history nothing yet
   * reads. main.tsx wires the real thing from every compliance/state/*.json
   * Vite bundles in; an omitted prop degrades to "no history yet" rather
   * than throwing.
   */
  history?: ComplianceState[];
}

const useStyles = makeStyles({
  shell: {
    minHeight: "100vh",
    backgroundColor: tokens.colorNeutralBackground2,
  },
  header: {
    display: "flex",
    flexDirection: "column",
    gap: "0.25rem",
    padding: "1.25rem 1.5rem 0.5rem",
  },
  content: {
    padding: "1rem 1.5rem 2rem",
    maxWidth: "1200px",
  },
  footer: {
    padding: "0 1.5rem 1.5rem",
    color: tokens.colorNeutralForeground3,
  },
  board: {
    display: "flex",
    flexDirection: "column",
    gap: "1rem",
  },
  switcher: {
    marginBottom: "0.25rem",
  },
});

export function App({ state, catalog, history = [] }: AppProps): JSX.Element {
  const styles = useStyles();
  const [view, setView] = useState<ViewId>("board");
  // Owned here for Task 11's FrameworkSwitcher / ControlDetail -- see the
  // seam comment at the top of this file.
  const [framework, setFramework] = useState<FrameworkId>(
    state.framework as FrameworkId,
  );
  const [selectedControl, setSelectedControl] = useState<string | null>(null);

  const onTabSelect = (_: SelectTabEvent, data: SelectTabData): void => {
    setView(data.value as ViewId);
  };

  function renderView(): JSX.Element {
    switch (view) {
      case "board":
        return (
          <div className={styles.board}>
            <div className={styles.switcher}>
              <FrameworkSwitcher
                framework={framework}
                onChange={(next) => {
                  setFramework(next);
                  // A row selected under one framework's labels may not exist
                  // (or may mean something else) under another -- clear the
                  // detail panel rather than leave it pointing at a control
                  // the visible board no longer shows.
                  setSelectedControl(null);
                }}
              />
            </div>
            <Board
              state={state}
              catalog={catalog}
              framework={framework}
              onSelectControl={setSelectedControl}
            />
            {selectedControl && (
              <ControlDetail control={selectedControl} state={state} catalog={catalog} />
            )}
          </div>
        );
      case "trend":
        return <Trend history={history} />;
    }
  }

  return (
    <FluentProvider theme={webLightTheme}>
      <div className={styles.shell}>
        <header className={styles.header}>
          <Title2>Meridian Launch Systems — Compliance</Title2>
          <Text>
            {state.frameworkName}. Counts by status and provenance only —
            never a blended percentage, score or ratio.
          </Text>
          <Text size={200}>
            Collected {state.collectedAt} from commit {state.commitShort} (
            {state.workingTreeClean ? "clean tree" : "tree had uncommitted changes"}
            ).
          </Text>
        </header>
        <TabList selectedValue={view} onTabSelect={onTabSelect} style={{ padding: "0 1rem" }}>
          {VIEW_IDS.map((id) => (
            <Tab value={id} key={id}>
              {VIEW_LABELS[id]}
            </Tab>
          ))}
        </TabList>
        <main className={styles.content}>{renderView()}</main>
        <footer className={styles.footer}>
          <Text size={200}>
            Synthetic data — Meridian Launch Systems is fictional.{" "}
            {state.collectors.length} collectors ran; see state.collectors for
            each one's limitation.
          </Text>
        </footer>
      </div>
    </FluentProvider>
  );
}
