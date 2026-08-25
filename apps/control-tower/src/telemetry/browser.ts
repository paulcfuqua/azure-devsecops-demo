/**
 * Browser telemetry — page and request telemetry into Azure Monitor.
 *
 * Two states, like the service side:
 *
 *   connection string present -> the Application Insights JS SDK is loaded
 *       (dynamically, so it is its own chunk) and reports page views, page
 *       visit time, fetch/XHR dependencies and unhandled exceptions, tagged
 *       with this app's cloud role. L7's V7.3 looks for exactly that role name.
 *   connection string absent  -> `initBrowserTelemetry` returns false having
 *       imported nothing and touched no global. That is the state in `vite
 *       dev`, in `vitest`, and in any build made before the tenant exists.
 *
 * WHY THE APPLICATION INSIGHTS SDK AND NOT THE OTEL WEB SDK. There is no
 * supported OpenTelemetry browser exporter for Azure Monitor — the Azure
 * Monitor OTel distro is Node-only. The browser-side path Microsoft supports is
 * this SDK, which emits the same App Insights tables (`AppPageViews`,
 * `AppDependencies`, `AppRequests`) that the service's OTel spans land in, and
 * correlates with them over W3C trace context. Principle #5 asks for
 * Microsoft-native and standards-based; on the browser side those two point at
 * this library.
 *
 * WHY THIS FILE IS DUPLICATED IN apps/launch-ops. It is eleven lines of
 * logic and a config object, and the alternative is a new shared package for
 * two consumers. The two copies differ only in the cloud role passed at the
 * call site; `tests/telemetry.test.ts` in each app pins the behaviour.
 *
 * PRIVACY RULE, enforced by `createTelemetryInitializer` below: no
 * user-entered text and no secret ever becomes telemetry. Query strings and
 * fragments are stripped from every URL, and custom string dimensions are
 * dropped wholesale.
 */

/**
 * The subset of `import.meta.env` this module reads.
 *
 * The index signature is load-bearing, not decoration: without it this is a
 * "weak type" (all properties optional) and TypeScript refuses to accept
 * Vite's `ImportMetaEnv` for it, because the two share no declared property.
 */
export interface TelemetryEnv {
  readonly [key: string]: unknown;
  readonly VITE_APPLICATIONINSIGHTS_CONNECTION_STRING?: string;
  readonly VITE_API_BASE_URL?: string;
}

/**
 * Runtime override hook. A static SPA is built once and deployed to an
 * environment that may not have existed at build time, so the container's
 * entrypoint can stamp `window.__MLS_TELEMETRY__` into index.html and avoid a
 * rebuild per environment. The build-time variable wins when both are present.
 */
export interface TelemetryWindow {
  __MLS_TELEMETRY__?: { connectionString?: string };
}

/** Structural view of an App Insights envelope — see the SDK's ITelemetryItem. */
export interface TelemetryEnvelope {
  name?: string;
  tags?: Record<string, unknown>;
  baseType?: string;
  baseData?: Record<string, unknown>;
}

/** URL fields the SDK populates, all of which may carry a query string. */
const URL_FIELDS = ["uri", "refUri", "url", "data", "target"] as const;

/**
 * Strip everything after the path. A query string is the most likely place for
 * user input to end up in a URL, and none of it is worth keeping: the route is
 * what a dashboard groups by.
 */
export function stripQuery(value: string): string {
  const cut = value.search(/[?#]/);
  const trimmed = cut === -1 ? value : value.slice(0, cut);

  // Only absolute URLs go through the URL parser, and only to normalise them
  // (dropping any userinfo and default port). Parsing everything against a
  // synthetic base was the first version of this and it was wrong: the SDK
  // also puts a bare host in `target`, and a bare host parsed as a relative
  // path comes back as `/api.example.com`.
  if (/^https?:\/\//i.test(trimmed)) {
    try {
      const url = new URL(trimmed);
      return `${url.origin}${url.pathname}`;
    } catch {
      return trimmed;
    }
  }
  return trimmed;
}

export function resolveConnectionString(
  env: TelemetryEnv = {},
  win: TelemetryWindow = {},
): string | undefined {
  const candidate =
    env.VITE_APPLICATIONINSIGHTS_CONNECTION_STRING ??
    win.__MLS_TELEMETRY__?.connectionString;
  const trimmed = candidate?.trim();
  return trimmed === undefined || trimmed === "" ? undefined : trimmed;
}

/**
 * Hosts that may receive correlation headers. Only the API origin, and only
 * when it is cross-origin: adding `traceparent` to a third-party request (the
 * Direct Line channel, a font CDN) turns a working call into a CORS failure.
 */
export function correlationDomains(env: TelemetryEnv = {}): string[] {
  const base = env.VITE_API_BASE_URL?.trim();
  if (!base || !base.startsWith("http")) return [];
  try {
    return [new URL(base).host];
  } catch {
    return [];
  }
}

/**
 * The scrubber. Runs on every envelope before it leaves the browser:
 * stamps the cloud role, strips query strings and fragments from every URL
 * field, and deletes custom string dimensions outright.
 *
 * `measurements` is deliberately kept — it is a map of numbers, so it cannot
 * carry text — while `properties` is deliberately dropped, because it can.
 */
export function createTelemetryInitializer(
  cloudRole: string,
): (envelope: TelemetryEnvelope) => boolean {
  return (envelope) => {
    const tags = envelope.tags ?? (envelope.tags = {});
    // App Insights renders this as AppRoleName, which V7.3 asserts against the
    // app name from naming.bicep.
    tags["ai.cloud.role"] = cloudRole;

    const baseData = envelope.baseData;
    if (baseData) {
      for (const field of URL_FIELDS) {
        const value = baseData[field];
        if (typeof value === "string") baseData[field] = stripQuery(value);
      }
      delete baseData.properties;
    }
    return true;
  };
}

export interface InitOptions {
  /** App name, as in naming.bicep — becomes AppRoleName. */
  cloudRole: string;
  env?: TelemetryEnv;
  win?: TelemetryWindow;
  onError?: (message: string) => void;
}

/**
 * Start browser telemetry if a connection string is configured.
 * Resolves to whether telemetry is actually running. Never throws: a broken
 * instrument must not break the app it is measuring.
 */
export async function initBrowserTelemetry(options: InitOptions): Promise<boolean> {
  const env = options.env ?? {};
  const win = options.win ?? (globalThis as unknown as TelemetryWindow);
  const connectionString = resolveConnectionString(env, win);
  if (!connectionString) return false;

  const onError =
    options.onError ??
    ((message: string) => console.warn(`[${options.cloudRole}] ${message}`));

  try {
    // Dynamic: with no connection string the SDK is never fetched, so a
    // pre-tenant build does not ship ~100 KB of unused telemetry code.
    const { ApplicationInsights } = await import("@microsoft/applicationinsights-web");
    const domains = correlationDomains(env);

    const appInsights = new ApplicationInsights({
      config: {
        connectionString,
        // No cookies: nothing to consent to, and no cross-site identifier.
        disableCookiesUsage: true,
        autoTrackPageVisitTime: true,
        // These apps are tab-switchers, not routers — one page view is honest.
        enableAutoRouteTracking: false,
        // Headers can carry credentials. Never record them.
        enableRequestHeaderTracking: false,
        enableResponseHeaderTracking: false,
        enableCorsCorrelation: domains.length > 0,
        correlationHeaderDomains: domains,
      },
    });

    appInsights.loadAppInsights();
    appInsights.addTelemetryInitializer(
      createTelemetryInitializer(options.cloudRole) as never,
    );
    appInsights.trackPageView();
    return true;
  } catch (error) {
    onError(
      `browser telemetry did not start: ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
    return false;
  }
}
