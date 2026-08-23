// jsdom lacks a few browser APIs that Fluent UI v9 and @fluentui/react-charts touch.
// Stub them so chart components can mount in tests.

/* eslint-disable @typescript-eslint/no-explicit-any */

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
