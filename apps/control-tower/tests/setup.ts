// jsdom lacks a few browser APIs that Fluent UI v9 and @fluentui/react-charts
// touch. Same stubs as apps/shared/spec-renderer/tests/setup.ts (kept local —
// the library does not export its test scaffolding).

/* eslint-disable @typescript-eslint/no-explicit-any */

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

// jsdom has no canvas 2d context; chart axis-label measurement uses one.
if (typeof window !== "undefined") {
  const canvasProto = (window as any).HTMLCanvasElement?.prototype;
  if (canvasProto) {
    canvasProto.getContext = function getContext() {
      return {
        font: "",
        measureText: (text: string) => ({ width: text.length * 7 }),
      };
    };
  }
}

// SVG text-measurement APIs used by chart axis layout.
if (typeof window !== "undefined") {
  const svgProto = (window as any).SVGElement?.prototype;
  if (svgProto) {
    if (typeof svgProto.getComputedTextLength !== "function") {
      svgProto.getComputedTextLength = () => 50;
    }
    if (typeof svgProto.getBBox !== "function") {
      svgProto.getBBox = () => ({ x: 0, y: 0, width: 50, height: 10 });
    }
  }
}
