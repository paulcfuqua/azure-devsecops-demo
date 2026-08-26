import { Button, Link, makeStyles, Text, tokens } from "@fluentui/react-components";
import type { AdaptiveAction, AdaptiveCard, AdaptiveElement } from "./agent/types";

/**
 * Adaptive Card view — the governance story, rendered.
 *
 * The 2026-08-24 amendment keeps the `@mls/spec-renderer` contract in force for
 * the app's own dashboards and extends the same principle to the agent: "the
 * agent returns declarative Adaptive Cards, never generated UI code". This
 * component is the other half of that promise. It walks a declarative card and
 * maps each element onto a Fluent UI primitive. Nothing the agent sends is
 * evaluated, injected as HTML, or turned into markup verbatim.
 *
 * SCOPE, STATED HONESTLY. The target profile is **Adaptive Cards 1.5 with
 * `Action.Submit`** (see `ADAPTIVE_CARD_TARGET_VERSION` for why: it is the one
 * payload that renders on Web Chat *and* Teams). Within that profile this
 * renders TextBlock, RichTextBlock, Image, FactSet, Container, ColumnSet,
 * ActionSet, `Action.OpenUrl` and `Action.Submit`. Anything outside it —
 * including `Action.Execute`, which Web Chat does not support — is reported in
 * place rather than silently dropped, so a card that will not render is visible
 * as a gap here instead of failing on another surface.
 *
 * Microsoft's own renderer is the `adaptivecards` npm package (3.0.6), which is
 * what Bot Framework Web Chat embeds. Swapping this component for it is a
 * self-contained change — the transcript hands it the same card JSON — and is
 * the right move once the app can take the dependency.
 */

const useStyles = makeStyles({
  card: {
    display: "flex",
    flexDirection: "column",
    gap: "0.5rem",
    padding: "0.75rem 1rem",
    borderRadius: tokens.borderRadiusMedium,
    border: `1px solid ${tokens.colorNeutralStroke2}`,
    backgroundColor: tokens.colorNeutralBackground1,
  },
  container: { display: "flex", flexDirection: "column", gap: "0.375rem" },
  columns: { display: "flex", flexDirection: "row", gap: "1rem", flexWrap: "wrap" },
  column: { display: "flex", flexDirection: "column", gap: "0.375rem", minWidth: "8rem" },
  facts: { display: "grid", gridTemplateColumns: "auto 1fr", gap: "0.25rem 0.75rem" },
  actions: { display: "flex", flexDirection: "row", gap: "0.5rem", flexWrap: "wrap" },
  image: { maxWidth: "100%", borderRadius: tokens.borderRadiusSmall },
  unsupported: {
    color: tokens.colorNeutralForeground3,
    fontStyle: "italic",
  },
});

/** Adaptive Cards `size` on a TextBlock, mapped onto Fluent's ramp. */
const TEXT_SIZE: Record<string, 200 | 300 | 400 | 500 | 600> = {
  small: 200,
  default: 300,
  medium: 400,
  large: 500,
  extraLarge: 600,
};

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

/**
 * F11: `Action.OpenUrl.url` and `Image.url` arrive from the Copilot Studio
 * agent over Direct Line with no validation upstream (`agent/transcript.ts`),
 * so a prompt injection can put any string here — including a `javascript:`
 * URI. Fluent's `useLinkBase_unstable` forwards `href` to the `<a>` element
 * unsanitised, and React 18 only warns about it in development; it does not
 * block it. `Image.url` cannot execute script via `<img src>`, but an
 * attacker-controlled scheme there is still an outbound beacon.
 *
 * This is an ALLOWLIST, not a blocklist: only `http://` / `https://` passes.
 * That is what makes it immune to case variation (`JaVaScRiPt:`) and
 * leading-whitespace tricks that defeat a naive `startsWith("javascript:")`
 * check — an anchored, case-insensitive match on the scheme we *want* is safe
 * by construction, unlike enumerating every scheme we don't.
 */
const SAFE_URL = /^https?:\/\//i;

function safeUrl(value: unknown): string | undefined {
  const s = str(value);
  if (!s) return undefined;
  const trimmed = s.trim();
  return SAFE_URL.test(trimmed) ? trimmed : undefined;
}

function elements(value: unknown): AdaptiveElement[] {
  return Array.isArray(value) ? (value as AdaptiveElement[]) : [];
}

export interface AdaptiveCardViewProps {
  card: AdaptiveCard;
  /**
   * Invoked for `Action.Submit` / `Action.Execute`. The Ask tab turns this into
   * a Direct Line message so a card button continues the conversation.
   */
  onAction?: (action: AdaptiveAction) => void;
}

export function AdaptiveCardView({ card, onAction }: AdaptiveCardViewProps): JSX.Element {
  const styles = useStyles();
  return (
    <div className={styles.card} data-testid="adaptive-card">
      {elements(card.body).map((element, i) => (
        <CardElement key={i} element={element} onAction={onAction} />
      ))}
      <CardActions actions={card.actions} onAction={onAction} />
    </div>
  );
}

interface ElementProps {
  element: AdaptiveElement;
  onAction?: (action: AdaptiveAction) => void;
}

function CardElement({ element, onAction }: ElementProps): JSX.Element {
  const styles = useStyles();

  switch (element.type) {
    case "TextBlock": {
      const size = TEXT_SIZE[str(element.size) ?? "default"] ?? 300;
      return (
        <Text
          size={size}
          weight={element.weight === "Bolder" ? "semibold" : "regular"}
          block
          style={element.isSubtle === true ? { color: tokens.colorNeutralForeground3 } : undefined}
        >
          {str(element.text) ?? ""}
        </Text>
      );
    }

    case "RichTextBlock":
      return (
        <Text block>
          {elements(element.inlines).map((inline, i) => (
            <Text key={i} weight={inline.weight === "Bolder" ? "semibold" : "regular"}>
              {str(inline.text) ?? ""}
            </Text>
          ))}
        </Text>
      );

    case "Image": {
      const url = safeUrl(element.url);
      if (!url) return <UnsupportedElement type="Image (no url, or unsafe scheme)" />;
      return <img className={styles.image} src={url} alt={str(element.altText) ?? ""} />;
    }

    case "FactSet":
      return (
        <div className={styles.facts}>
          {elements(element.facts).map((fact, i) => (
            <FactRow key={i} title={str(fact.title)} value={str(fact.value)} />
          ))}
        </div>
      );

    case "Container":
      return (
        <div className={styles.container}>
          {elements(element.items).map((child, i) => (
            <CardElement key={i} element={child} onAction={onAction} />
          ))}
        </div>
      );

    case "ColumnSet":
      return (
        <div className={styles.columns}>
          {elements(element.columns).map((column, i) => (
            <div className={styles.column} key={i}>
              {elements(column.items).map((child, j) => (
                <CardElement key={j} element={child} onAction={onAction} />
              ))}
            </div>
          ))}
        </div>
      );

    case "ActionSet":
      return <CardActions actions={element.actions} onAction={onAction} />;

    default:
      return <UnsupportedElement type={element.type} />;
  }
}

function FactRow({ title, value }: { title?: string; value?: string }): JSX.Element {
  return (
    <>
      <Text size={200} weight="semibold">
        {title ?? ""}
      </Text>
      <Text size={200}>{value ?? ""}</Text>
    </>
  );
}

function CardActions({
  actions,
  onAction,
}: {
  actions: unknown;
  onAction?: (action: AdaptiveAction) => void;
}): JSX.Element | null {
  const styles = useStyles();
  const list = Array.isArray(actions) ? (actions as AdaptiveAction[]) : [];
  if (list.length === 0) return null;

  return (
    <div className={styles.actions}>
      {list.map((action, i) => {
        const title = action.title ?? action.type;
        if (action.type === "Action.OpenUrl") {
          const url = safeUrl(action.url);
          return url ? (
            <Link key={i} href={url} target="_blank" rel="noreferrer noopener">
              {title}
            </Link>
          ) : (
            <UnsupportedElement key={i} type="Action.OpenUrl (no url, or unsafe scheme)" />
          );
        }
        if (action.type === "Action.Submit") {
          return (
            <Button key={i} size="small" onClick={() => onAction?.(action)}>
              {title}
            </Button>
          );
        }
        // `Action.Execute` is deliberately NOT rendered. It is valid Adaptive
        // Cards, but Bot Framework Web Chat does not support it and Teams caps
        // at schema 1.5 — so a card using it renders here and nowhere else.
        // Surfacing it is what keeps the agent's cards portable.
        return <UnsupportedElement key={i} type={action.type} />;
      })}
    </div>
  );
}

/**
 * Reported, not swallowed. A card element this renderer does not know about is
 * a real gap in the agent's answer, and the demo is better served by saying so
 * than by rendering a convincing-looking partial card.
 */
function UnsupportedElement({ type }: { type: string }): JSX.Element {
  const styles = useStyles();
  return (
    <Text size={200} className={styles.unsupported} data-testid="adaptive-card-unsupported">
      Adaptive Card element “{type}” is outside the subset this build renders.
    </Text>
  );
}
