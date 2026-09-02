import {
  Button,
  makeStyles,
  MessageBar,
  MessageBarBody,
  MessageBarTitle,
  Spinner,
  Text,
  Textarea,
  tokens,
} from "@fluentui/react-components";
import { useCallback, useEffect, useRef, useState } from "react";
import { AdaptiveCardView } from "./AdaptiveCardView";
import { activityToTurn, appendTurn, userTurn } from "./agent/transcript";
import type { AdaptiveAction, AgentConnection, AgentProvider, AgentTurn } from "./agent/types";
import type { JSX } from "react";

const useStyles = makeStyles({
  panel: { display: "flex", flexDirection: "column", gap: "1rem" },
  transcript: {
    display: "flex",
    flexDirection: "column",
    gap: "0.75rem",
    minHeight: "12rem",
  },
  turn: {
    display: "flex",
    flexDirection: "column",
    gap: "0.375rem",
    padding: "0.625rem 0.875rem",
    borderRadius: tokens.borderRadiusMedium,
    maxWidth: "44rem",
  },
  userTurn: {
    alignSelf: "flex-end",
    backgroundColor: tokens.colorBrandBackground2,
  },
  agentTurn: {
    alignSelf: "flex-start",
    backgroundColor: tokens.colorNeutralBackground1,
    border: `1px solid ${tokens.colorNeutralStroke2}`,
  },
  composer: { display: "flex", flexDirection: "row", gap: "0.5rem", alignItems: "flex-end" },
  input: { flexGrow: 1 },
  status: { color: tokens.colorNeutralForeground3 },
  pending: {
    display: "flex",
    flexDirection: "row",
    gap: "0.5rem",
    alignItems: "center",
    padding: "0.5rem 0.75rem",
    color: tokens.colorNeutralForeground3,
  },
});

export interface AskPanelProps {
  /** The Ask tab's seam. Dumb by contract: no transport details reach here. */
  provider: AgentProvider;
}

type ConnectionState =
  | { status: "offline"; reason: string }
  | { status: "connecting" }
  | { status: "ready"; connection: AgentConnection }
  | { status: "error"; message: string; signInUrl?: string };

/**
 * The Ask tab. Structurally the same shape as `SpecPanel`: a small state
 * machine over a provider-supplied resource, with every piece of data shaping
 * delegated to the pure helpers in `agent/transcript.ts`.
 */
export function AskPanel({ provider }: AskPanelProps): JSX.Element {
  const styles = useStyles();
  const [state, setState] = useState<ConnectionState>({ status: "connecting" });
  const [turns, setTurns] = useState<readonly AgentTurn[]>([]);
  const [draft, setDraft] = useState("");
  const [sending, setSending] = useState(false);
  // AWAITING THE REPLY, WHICH IS NOT THE SAME AS SENDING, and conflating them is
  // what made the tab look dead. `sending` covers the POST to Direct Line and
  // that returns in about 200ms; the agent's answer arrives seconds later on the
  // activity stream - a lakehouse query, and up to ~30s more when the tool
  // server is cold. So the button re-enabled almost immediately and then nothing
  // visible happened, which reads as "my question was dropped".
  const [awaitingReply, setAwaitingReply] = useState(false);
  const [sendError, setSendError] = useState<string | null>(null);
  const connectionRef = useRef<AgentConnection | null>(null);

  useEffect(() => {
    let cancelled = false;
    setTurns([]);
    setSendError(null);

    if (!provider.available) {
      setState({
        status: "offline",
        reason: provider.unavailableReason ?? "The agent is not configured.",
      });
      return;
    }

    setState({ status: "connecting" });
    provider.connect().then(
      (connection) => {
        if (cancelled) {
          connection.close();
          return;
        }
        connectionRef.current = connection;
        connection.onActivity((activity) => {
          const turn = activityToTurn(activity);
          if (turn) {
            setTurns((current) => appendTurn(current, turn));
            // Any activity FROM THE AGENT ends the wait - including an error
            // message, which is still an answer and must not leave the
            // indicator spinning forever.
            if (turn.role !== "user") setAwaitingReply(false);
          }
        });
        connection.onError((error) => {
          setSendError(error.message);
          setAwaitingReply(false);
        });
        setState({ status: "ready", connection });
      },
      (error: unknown) => {
        if (cancelled) return;
        // An expired sign-in carries somewhere to go (F149). Everything else
        // carries nothing, so the UI cannot offer a sign-in link for a problem
        // that signing in would not fix.
        const signInUrl =
          typeof (error as { signInUrl?: unknown })?.signInUrl === "string"
            ? (error as { signInUrl: string }).signInUrl
            : undefined;
        setState({
          status: "error",
          message: error instanceof Error ? error.message : String(error),
          ...(signInUrl ? { signInUrl } : {}),
        });
      },
    );

    return () => {
      cancelled = true;
      connectionRef.current?.close();
      connectionRef.current = null;
    };
  }, [provider]);

  const send = useCallback(
    async (text: string): Promise<void> => {
      const connection = connectionRef.current;
      const trimmed = text.trim();
      if (!connection || trimmed === "" || sending) return;
      setSending(true);
      setSendError(null);
      setTurns((current) => appendTurn(current, userTurn(trimmed)));
      try {
        await connection.send(trimmed);
        setDraft("");
        // Only after the send SUCCEEDS: a failed send has nothing to wait for.
        setAwaitingReply(true);
      } catch (error: unknown) {
        setSendError(error instanceof Error ? error.message : String(error));
        setAwaitingReply(false);
      } finally {
        setSending(false);
      }
    },
    [sending],
  );

  const onCardAction = useCallback(
    (action: AdaptiveAction): void => {
      // Adaptive Card `Action.Submit`/`Action.Execute` continue the
      // conversation. Direct Line carries the payload as an activity value; the
      // demo sends the action's own string data when it has one and falls back
      // to its title, which is what the agent's trigger phrases match on.
      const value = typeof action.data === "string" ? action.data : (action.title ?? "");
      void send(value);
    },
    [send],
  );

  if (state.status === "offline") {
    return (
      <div className={styles.panel} data-testid="ask-offline">
        <MessageBar intent="warning">
          <MessageBarBody>
            <MessageBarTitle>Ask is offline in local mode</MessageBarTitle> The
            Copilot Studio agent is cloud-only, so this tab needs the deployed
            environment — a published agent, its Direct Line channel, and the
            token endpoint that exchanges the Direct Line secret server-side.{" "}
            {state.reason}
          </MessageBarBody>
        </MessageBar>
        <Text block>
          This is a stated, accepted cost of the 2026-08-24 amendment: moving all
          runtime LLM work into Copilot Studio means showpiece&nbsp;#1 can no longer
          be proven on a laptop with no tenant. The Dev, Sec and Ops tabs are
          unaffected and keep running from local fixtures.
        </Text>
        <Text block size={200} className={styles.status}>
          To bring this tab online, deploy <code>apps/directline-token</code> and build
          the control tower with <code>VITE_DIRECTLINE_TOKEN_URL</code> pointing at it.
          Nothing here answers questions offline — no mock agent, no canned reply.
        </Text>
      </div>
    );
  }

  if (state.status === "connecting") {
    return <Spinner label="Connecting to the agent…" style={{ padding: "2rem" }} />;
  }

  if (state.status === "error") {
    return (
      <MessageBar intent="error">
        <MessageBarBody>
          <MessageBarTitle>Agent unavailable</MessageBarTitle> {state.message}
          {state.signInUrl ? (
            <>
              {" "}
              {/* A LINK, not an automatic redirect: navigating on a 401 is how one
                  bad token becomes a redirect loop. One click, and Entra answers
                  it from the existing browser session. */}
              <a href={state.signInUrl} data-testid="ask-signin-again">
                Sign in again
              </a>
              .
            </>
          ) : null}
        </MessageBarBody>
      </MessageBar>
    );
  }

  return (
    <div className={styles.panel} data-testid="ask-ready">
      <div className={styles.transcript} role="log" aria-label="Agent transcript">
        {turns.length === 0 ? (
          <Text block className={styles.status}>
            Ask the agent about launch operations, security posture or cost. Answers
            come back as Adaptive Cards.
          </Text>
        ) : (
          turns.map((turn) => (
            <div
              key={turn.id}
              className={`${styles.turn} ${
                turn.role === "user" ? styles.userTurn : styles.agentTurn
              }`}
              data-testid={`turn-${turn.role}`}
            >
              {turn.text ? <Text block>{turn.text}</Text> : null}
              {turn.cards.map((card, i) => (
                <AdaptiveCardView key={i} card={card} onAction={onCardAction} />
              ))}
              {turn.otherAttachments.map((attachment, i) => (
                <Text key={i} size={200} className={styles.status}>
                  Attachment of type “{attachment.contentType}” is not rendered here.
                </Text>
              ))}
            </div>
          ))
        )}
      </div>

      {awaitingReply ? (
        <div className={styles.pending} data-testid="ask-pending" role="status" aria-live="polite">
          <Spinner size="tiny" />
          <Text size={200}>
            The agent is working. A lakehouse question takes a few seconds, and up to
            about half a minute if the tool server was idle.
          </Text>
        </div>
      ) : null}

      {sendError ? (
        <MessageBar intent="error">
          <MessageBarBody>
            <MessageBarTitle>Direct Line error</MessageBarTitle> {sendError}
          </MessageBarBody>
        </MessageBar>
      ) : null}

      <form
        className={styles.composer}
        onSubmit={(event) => {
          event.preventDefault();
          void send(draft);
        }}
      >
        <Textarea
          className={styles.input}
          value={draft}
          resize="vertical"
          aria-label="Ask the agent"
          placeholder="Ask the agent…"
          onChange={(_, data) => setDraft(data.value)}
        />
        <Button
          type="submit"
          appearance="primary"
          disabled={sending || awaitingReply || draft.trim() === ""}
        >
          Ask
        </Button>
      </form>

      <Text block size={200} className={styles.status}>
        Agent source: {provider.source}. Conversation {state.connection.conversationId}.
      </Text>
    </div>
  );
}
