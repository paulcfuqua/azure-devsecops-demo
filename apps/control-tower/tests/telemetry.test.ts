/**
 * Browser telemetry: the no-op state, and the privacy scrubber.
 *
 * The scrubber is the part worth testing. Everything else here is SDK
 * configuration that only proves itself against a real Application Insights
 * resource, but "no user-entered text and no secret ever leaves the browser as
 * telemetry" is a claim that can be pinned down exactly, and it is the claim
 * that would be embarrassing to get wrong.
 */
import { describe, expect, it, vi } from "vitest";
import {
  correlationDomains,
  createTelemetryInitializer,
  initBrowserTelemetry,
  resolveConnectionString,
  stripQuery,
  type TelemetryEnvelope,
} from "../src/telemetry/browser";

const CONNECTION_STRING =
  "InstrumentationKey=00000000-1111-2222-3333-444444444444;" +
  "IngestionEndpoint=https://eastus-1.in.applicationinsights.azure.com/";

describe("resolveConnectionString", () => {
  it("is undefined when nothing is configured", () => {
    expect(resolveConnectionString({}, {})).toBeUndefined();
  });

  it("treats an empty or blank value as absent", () => {
    expect(
      resolveConnectionString({ VITE_APPLICATIONINSIGHTS_CONNECTION_STRING: "  " }, {}),
    ).toBeUndefined();
  });

  it("reads the build-time variable", () => {
    expect(
      resolveConnectionString(
        { VITE_APPLICATIONINSIGHTS_CONNECTION_STRING: CONNECTION_STRING },
        {},
      ),
    ).toBe(CONNECTION_STRING);
  });

  it("falls back to the runtime window hook", () => {
    expect(
      resolveConnectionString({}, { __MLS_TELEMETRY__: { connectionString: CONNECTION_STRING } }),
    ).toBe(CONNECTION_STRING);
  });

  it("prefers the build-time variable over the runtime hook", () => {
    expect(
      resolveConnectionString(
        { VITE_APPLICATIONINSIGHTS_CONNECTION_STRING: "build" },
        { __MLS_TELEMETRY__: { connectionString: "runtime" } },
      ),
    ).toBe("build");
  });
});

describe("stripQuery", () => {
  it.each([
    ["https://app.example.com/tables/launches?limit=50", "https://app.example.com/tables/launches"],
    ["https://app.example.com/x#fragment", "https://app.example.com/x"],
    ["/api/tables/launches?limit=50", "/api/tables/launches"],
    ["/api/feeds/secure-score", "/api/feeds/secure-score"],
    ["app.example.com", "app.example.com"],
  ])("%s -> %s", (input, expected) => {
    expect(stripQuery(input)).toBe(expected);
  });
});

describe("correlationDomains", () => {
  it("is empty when the API is same-origin", () => {
    expect(correlationDomains({})).toEqual([]);
    expect(correlationDomains({ VITE_API_BASE_URL: "/api" })).toEqual([]);
  });

  it("names only the API host when the API is cross-origin", () => {
    expect(
      correlationDomains({ VITE_API_BASE_URL: "https://mls-data-api-demo-ca.example.io/api" }),
    ).toEqual(["mls-data-api-demo-ca.example.io"]);
  });

  it("is empty for an unparseable value rather than throwing", () => {
    expect(correlationDomains({ VITE_API_BASE_URL: "http://" })).toEqual([]);
  });
});

describe("the telemetry initializer", () => {
  const initializer = createTelemetryInitializer("control-tower");

  it("stamps the cloud role V7.3 asserts on", () => {
    const envelope: TelemetryEnvelope = {};
    initializer(envelope);
    expect(envelope.tags?.["ai.cloud.role"]).toBe("control-tower");
  });

  it("strips query strings from every URL field", () => {
    const envelope: TelemetryEnvelope = {
      baseType: "RemoteDependencyData",
      baseData: {
        uri: "https://app.example.com/?token=SECRET",
        refUri: "https://app.example.com/x?q=SECRET",
        url: "/api/tables/launches?limit=SECRET",
        data: "https://api.example.com/feeds/secure-score?sig=SECRET",
        target: "api.example.com",
      },
    };
    initializer(envelope);
    expect(JSON.stringify(envelope)).not.toContain("SECRET");
    expect(envelope.baseData?.data).toBe("https://api.example.com/feeds/secure-score");
    expect(envelope.baseData?.target).toBe("api.example.com");
  });

  it("drops custom string dimensions wholesale", () => {
    const envelope: TelemetryEnvelope = {
      baseData: {
        name: "PageView",
        properties: { userTypedQuestion: "how much did Propulsion spend?" },
        measurements: { duration: 42 },
      },
    };
    initializer(envelope);
    expect(envelope.baseData?.properties).toBeUndefined();
    // Numbers cannot carry text, so measurements survive.
    expect(envelope.baseData?.measurements).toEqual({ duration: 42 });
  });

  it("leaves an envelope without baseData alone", () => {
    const envelope: TelemetryEnvelope = { name: "Metric" };
    expect(initializer(envelope)).toBe(true);
  });
});

describe("initBrowserTelemetry", () => {
  it("does nothing and loads no SDK when no connection string is configured", async () => {
    const onError = vi.fn();
    await expect(
      initBrowserTelemetry({ cloudRole: "control-tower", env: {}, win: {}, onError }),
    ).resolves.toBe(false);
    expect(onError).not.toHaveBeenCalled();
  });

  it("reports rather than throws if the SDK cannot start", async () => {
    const onError = vi.fn();
    // jsdom has no real ingestion endpoint; whatever the SDK does here, the
    // contract is that the caller gets a boolean and the app keeps rendering.
    const started = await initBrowserTelemetry({
      cloudRole: "control-tower",
      env: { VITE_APPLICATIONINSIGHTS_CONNECTION_STRING: CONNECTION_STRING },
      win: {},
      onError,
    });
    expect(typeof started).toBe("boolean");
    if (!started) expect(onError).toHaveBeenCalled();
  });
});
