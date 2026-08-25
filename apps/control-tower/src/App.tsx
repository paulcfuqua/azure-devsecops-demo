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
import type { AgentProvider } from "./agent/types";
import { AskPanel } from "./AskPanel";
import { OfflineAgentProvider } from "./agent/providers";
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

/**
 * Three Well-Architected posture pillars, plus the Copilot Studio agent.
 * "ask" is not a pillar — it is showpiece #1's answer surface, embedded here
 * per the sponsor's 2026-08-24 decision — so it rides a separate provider and
 * renders its own panel rather than a `@mls/spec-renderer` spec.
 */
type PillarId = "dev" | "sec" | "ops";
type TabId = PillarId | "ask";

export interface AppProps {
  provider: DataProvider;
  /**
   * Optional so every existing caller (and every existing test) keeps working.
   * Omitted means the Ask tab is offline, which is exactly right for a host
   * that never configured Direct Line.
   */
  agent?: AgentProvider;
}

export function App({ provider, agent }: AppProps): JSX.Element {
  const styles = useStyles();
  const [tab, setTab] = useState<TabId>("dev");

  // Bind loaders once per provider so SpecPanel effects don't re-fire on render.
  const loaders = useMemo(
    () => ({
      dev: () => provider.getDevSpec(),
      sec: () => provider.getSecSpec(),
      ops: () => provider.getOpsSpec(),
    }),
    [provider],
  );

  // A stable fallback: constructing it once keeps AskPanel's connect effect
  // from re-firing, and it does no I/O.
  const agentProvider = useMemo(
    () =>
      agent ??
      new OfflineAgentProvider(
        "No agent provider was supplied to the control tower shell.",
      ),
    [agent],
  );

  const onTabSelect = (_: SelectTabEvent, data: SelectTabData): void => {
    setTab(data.value as TabId);
  };

  return (
    <FluentProvider theme={webLightTheme}>
      <div className={styles.shell}>
        <header className={styles.header}>
          <Title2>Meridian Launch Systems — Control Tower</Title2>
          <Text>
            Dev / Sec / Ops posture on Well-Architected pillars, and Ask — the
            Copilot Studio agent.
          </Text>
        </header>
        <TabList selectedValue={tab} onTabSelect={onTabSelect} style={{ padding: "0 1rem" }}>
          <Tab value="dev">Dev</Tab>
          <Tab value="sec">Sec</Tab>
          <Tab value="ops">Ops</Tab>
          <Tab value="ask">Ask</Tab>
        </TabList>
        <main className={styles.content}>
          {tab === "ask" ? (
            <AskPanel provider={agentProvider} />
          ) : (
            <SpecPanel key={tab} load={loaders[tab]} />
          )}
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
