import {
  FluentProvider,
  makeStyles,
  Tab,
  TabList,
  Text,
  Title2,
  tokens,
  webLightTheme,
  type SelectTabData,
  type SelectTabEvent,
} from "@fluentui/react-components";
import { useMemo, useState } from "react";
import { SpecPanel } from "./SpecPanel";
import type { DataProvider } from "./providers/types";
import type { JSX } from "react";

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
});

type ViewId = "schedule" | "outcomes" | "scrubs" | "reference";

export interface AppProps {
  provider: DataProvider;
}

export function App({ provider }: AppProps): JSX.Element {
  const styles = useStyles();
  const [view, setView] = useState<ViewId>("schedule");

  // Bind loaders once per provider so SpecPanel effects don't re-fire on render.
  const loaders = useMemo(
    () => ({
      schedule: () => provider.getScheduleSpec(),
      outcomes: () => provider.getOutcomesSpec(),
      scrubs: () => provider.getScrubAnalysisSpec(),
      reference: () => provider.getReferenceSpec(),
    }),
    [provider],
  );

  const onTabSelect = (_: SelectTabEvent, data: SelectTabData): void => {
    setView(data.value as ViewId);
  };

  return (
    <FluentProvider theme={webLightTheme}>
      <div className={styles.shell}>
        <header className={styles.header}>
          <Title2>Meridian Launch Systems — Launch Ops</Title2>
          <Text>Schedule, outcomes, scrub analysis, and fleet reference.</Text>
        </header>
        <TabList selectedValue={view} onTabSelect={onTabSelect} style={{ padding: "0 1rem" }}>
          <Tab value="schedule">Schedule</Tab>
          <Tab value="outcomes">Outcomes</Tab>
          <Tab value="scrubs">Scrub analysis</Tab>
          <Tab value="reference">Fleet & pads</Tab>
        </TabList>
        <main className={styles.content}>
          <SpecPanel key={view} load={loaders[view]} />
        </main>
        <footer className={styles.footer}>
          <Text size={200}>
            Data source: {provider.source}. Synthetic data — Meridian Launch Systems is
            fictional.
          </Text>
        </footer>
      </div>
    </FluentProvider>
  );
}
