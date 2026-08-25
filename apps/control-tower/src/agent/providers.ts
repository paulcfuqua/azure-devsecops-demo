import { connectDirectLine, type DirectLineTransportOptions } from "./DirectLineTransport";
import { createTokenFetcher } from "./directLineToken";
import type { AgentConnection, AgentProvider, TokenFetcher } from "./types";

/**
 * The two `AgentProvider` implementations — the mirror of `LocalProvider` /
 * `ApiProvider` on the data side.
 */

/**
 * Local mode. Copilot Studio is cloud-only: the 2026-08-24 amendment records
 * this as a deliberate, accepted loss ("Lost capability — stated plainly:
 * Copilot Studio is cloud-only... after this change it requires the tenant, a
 * Power Platform environment, and Fabric capacity").
 *
 * So there is no local agent, and this provider does not invent one. It is
 * *not* a mock: `available` is false, `connect()` throws if anyone calls it
 * anyway, and the Ask tab renders an offline state that says why. The Dev, Sec
 * and Ops tabs are unaffected — they keep working from fixtures.
 */
export class OfflineAgentProvider implements AgentProvider {
  readonly available = false;

  constructor(readonly unavailableReason: string) {}

  get source(): string {
    return "offline — no Direct Line configuration";
  }

  connect(): Promise<AgentConnection> {
    return Promise.reject(
      new Error(
        "The Ask tab is offline. " +
          this.unavailableReason +
          " Nothing here fabricates an answer.",
      ),
    );
  }
}

export interface DirectLineAgentProviderOptions
  extends Omit<DirectLineTransportOptions, "tokenFetcher"> {
  /** URL of the server-side token endpoint (apps/directline-token). */
  tokenUrl: string;
  /** Override only in tests; production always builds one from `tokenUrl`. */
  tokenFetcher?: TokenFetcher;
}

/**
 * Deployed mode. Talks Direct Line 3.0 to the published Copilot Studio agent.
 *
 * The provider is constructed eagerly (so the App can read `source` and
 * `available` without I/O) but performs no network call until `connect()`,
 * which the Ask tab calls when the tab is first opened. A misconfigured or
 * unreachable token endpoint therefore degrades to an error message inside the
 * Ask tab, never a failure of the app shell.
 */
export class DirectLineAgentProvider implements AgentProvider {
  readonly available = true;

  readonly source: string;

  private readonly transportOptions: DirectLineTransportOptions;

  constructor(options: DirectLineAgentProviderOptions) {
    const { tokenUrl, tokenFetcher, ...transport } = options;
    this.source = `Copilot Studio agent via Direct Line (token endpoint ${tokenUrl})`;
    this.transportOptions = {
      ...transport,
      tokenFetcher:
        tokenFetcher ?? createTokenFetcher(tokenUrl, { fetchImpl: transport.fetchImpl }),
    };
  }

  connect(): Promise<AgentConnection> {
    return connectDirectLine(this.transportOptions);
  }
}
