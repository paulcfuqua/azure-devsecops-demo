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

type PillarId = "dev" | "sec" | "ops";

export interface AppProps {
  provider: DataProvider;
}

export function App({ provider }: AppProps): JSX.Element {
  const styles = useStyles();
  const [pillar, setPillar] = useState<PillarId>("dev");

  // Bind loaders once per provider so SpecPanel effects don't re-fire on render.
  const loaders = useMemo(
    () => ({
      dev: () => provider.getDevSpec(),
      sec: () => provider.getSecSpec(),
      ops: () => provider.getOpsSpec(),
    }),
    [provider],
  );

  const onTabSelect = (_: SelectTabEvent, data: SelectTabData): void => {
    setPillar(data.value as PillarId);
  };

  return (
    <FluentProvider theme={webLightTheme}>
      <div className={styles.shell}>
        <header className={styles.header}>
          <Title2>Meridian Launch Systems — Control Tower</Title2>
          <Text>
            Dev / Sec / Ops posture on Well-Architected pillars.
          </Text>
        </header>
        <TabList selectedValue={pillar} onTabSelect={onTabSelect} style={{ padding: "0 1rem" }}>
          <Tab value="dev">Dev</Tab>
          <Tab value="sec">Sec</Tab>
          <Tab value="ops">Ops</Tab>
        </TabList>
        <main className={styles.content}>
          <SpecPanel key={pillar} load={loaders[pillar]} />
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
