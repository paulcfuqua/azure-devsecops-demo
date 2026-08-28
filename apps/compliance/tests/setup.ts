// jsdom lacks a few browser APIs Fluent UI v9 touches. Same stubs as
// apps/control-tower/tests/setup.ts and apps/shared/spec-renderer/tests/setup.ts
// (kept local — neither exports its test scaffolding).
//
// Unlike those sibling apps (which stick to plain vitest assertions --
// .toBeTruthy(), etc.), this app's own test sketches in the plan (and every
// one of Tasks 10-12's) use jest-dom matchers (toBeInTheDocument,
// toHaveTextContent, toHaveAttribute, toBeEmptyDOMElement). Nothing in the
// repo installed @testing-library/jest-dom before this task; it is added
// here once so Tasks 10-12 do not each have to.

/* eslint-disable @typescript-eslint/no-explicit-any */

import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach } from "vitest";

// Auto-cleanup is opt-in unless vitest runs with `globals: true`. Without it,
// Fluent's focus manager keeps a MutationObserver alive past environment
// teardown and jsdom logs a spurious "NodeFilter is not defined".
afterEach(() => {
  cleanup();
});

if (typeof (globalThis as any).ResizeObserver === "undefined") {
  class ResizeObserverStub {
    observe(): void {}
    unobserve(): void {}
    disconnect(): void {}
  }
  (globalThis as any).ResizeObserver = ResizeObserverStub;
}

if (typeof window !== "undefined" && typeof window.matchMedia !== "function") {
  window.matchMedia = (query: string): MediaQueryList =>
    ({
      matches: false,
      media: query,
      onchange: null,
      addListener: () => {},
      removeListener: () => {},
      addEventListener: () => {},
      removeEventListener: () => {},
      dispatchEvent: () => false,
    }) as unknown as MediaQueryList;
}
