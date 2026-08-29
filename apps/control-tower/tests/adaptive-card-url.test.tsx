import { render, screen } from "@testing-library/react";
import { FluentProvider, webLightTheme } from "@fluentui/react-components";
import { describe, expect, it } from "vitest";
import { AdaptiveCardView } from "../src/AdaptiveCardView";
import type { AdaptiveCard } from "../src/agent/types";
import type { JSX } from "react";

/**
 * F11: Action.OpenUrl.url and Image.url must refuse anything that is not an
 * http(s) URL before it reaches Fluent's Link / <img>. Card content comes
 * from the Copilot Studio agent over Direct Line with no validation upstream
 * (agent/transcript.ts), so a prompt injection can put any string here,
 * including a javascript: URI, which React 18 renders with only a
 * dev-mode console warning (it does not block it), and which Fluent's
 * useLinkBase_unstable forwards straight to the href attribute unchanged.
 *
 * The unsafe cases below are deliberately more than the brief's literal list:
 * a guard that blocklists "javascript:" case-sensitively, or that trims only
 * leading/trailing whitespace, still lets some of these through. An allowlist
 * regex anchored on ^https?:// is immune to all of them, which is the point
 * of testing them explicitly here rather than trusting that property.
 */

function withTheme(node: React.ReactNode): JSX.Element {
  return <FluentProvider theme={webLightTheme}>{node}</FluentProvider>;
}

function cardWithAction(url: string): AdaptiveCard {
  return {
    type: "AdaptiveCard",
    actions: [{ type: "Action.OpenUrl", title: "View report", url }],
  };
}

function cardWithImage(url: string): AdaptiveCard {
  return {
    type: "AdaptiveCard",
    body: [{ type: "Image", url }],
  };
}

const LEADING_SPACE = " javascript:alert(1)";
const LEADING_TAB = "\tjavascript:alert(1)";
const LEADING_NEWLINE = "\n javascript:alert(1)";
const SCHEME_WITH_EMBEDDED_TAB = "javascript\t:alert(1)";
const LEADING_NUL = "\x00javascript:alert(1)";

const UNSAFE_URLS = [
  "javascript:alert(1)",
  "JaVaScRiPt:alert(1)",
  LEADING_SPACE,
  LEADING_TAB,
  LEADING_NEWLINE,
  SCHEME_WITH_EMBEDDED_TAB,
  LEADING_NUL,
  "data:text/html,<script>alert(1)</script>",
  "vbscript:msgbox(1)",
];

describe("AdaptiveCardView - Action.OpenUrl scheme guard (F11)", () => {
  it.each(UNSAFE_URLS)("refuses to render an unsafe Action.OpenUrl url: %j", (url) => {
    render(withTheme(<AdaptiveCardView card={cardWithAction(url)} />));
    expect(screen.queryByRole("link")).toBeNull();
    expect(screen.getByTestId("adaptive-card-unsupported")).toBeTruthy();
  });

  it("still renders an https link", () => {
    render(withTheme(<AdaptiveCardView card={cardWithAction("https://example.test/r")} />));
    expect(screen.getByRole("link").getAttribute("href")).toBe("https://example.test/r");
  });

  it("still renders an http link", () => {
    render(withTheme(<AdaptiveCardView card={cardWithAction("http://example.test/r")} />));
    expect(screen.getByRole("link").getAttribute("href")).toBe("http://example.test/r");
  });
});

describe("AdaptiveCardView - Image scheme guard (F11)", () => {
  // An <img> with alt="" (no altText on the card) gets ARIA role "presentation",
  // not "img" - asserting via getByRole("img") would pass even if an <img> with
  // an unsafe src rendered, so this queries the DOM directly instead.
  it.each(UNSAFE_URLS)("refuses to render an unsafe Image url: %j", (url) => {
    const { container } = render(withTheme(<AdaptiveCardView card={cardWithImage(url)} />));
    expect(container.querySelector("img")).toBeNull();
    expect(screen.getByTestId("adaptive-card-unsupported")).toBeTruthy();
  });

  it("still renders an https image", () => {
    const { container } = render(
      withTheme(<AdaptiveCardView card={cardWithImage("https://example.test/p.png")} />),
    );
    expect(container.querySelector("img")?.getAttribute("src")).toBe(
      "https://example.test/p.png",
    );
  });
});
