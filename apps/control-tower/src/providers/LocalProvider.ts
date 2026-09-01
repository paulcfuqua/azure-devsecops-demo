import type { Spec } from "@mls/spec-renderer";
import { buildDevSpec, buildOpsSpec, buildSecSpec } from "./specs";
import type { DataProvider, FeedBundle, JsonLoader } from "./types";

// ---------------------------------------------------------------------------
// LOCAL FIXTURES (Phase P). These committed JSON files are hand-authored
// stand-ins for the live feeds the master plan wires at L7/L9. Each file is
// structured to match its real interface so the builders and the ApiProvider
// consume identical shapes:
//   github-workflow-runs.fixture.json        -> GitHub Actions runs API
//   github-code-scanning-alerts.fixture.json -> GitHub code scanning API
//   github-dependabot-alerts.fixture.json    -> GitHub Dependabot alerts API
//   defender-secure-score*.fixture.json      -> Defender for Cloud secure score APIs
//   log-analytics-app-requests.fixture.json  -> Log Analytics query API
// ---------------------------------------------------------------------------
import codeScanningAlertsFixture from "../fixtures/github-code-scanning-alerts.fixture.json";
import dependabotAlertsFixture from "../fixtures/github-dependabot-alerts.fixture.json";
import workflowRunsFixture from "../fixtures/github-workflow-runs.fixture.json";
import secureScoreControlsFixture from "../fixtures/defender-secure-score-controls.fixture.json";
import secureScoreFixture from "../fixtures/defender-secure-score.fixture.json";
import appRequestsFixture from "../fixtures/log-analytics-app-requests.fixture.json";
import azureCostFixture from "../fixtures/cost-management-azure-cost.fixture.json";

/** The committed local fixture bundle for Dev + Sec tabs. */
export const localFixtures: FeedBundle = {
  workflowRuns: workflowRunsFixture,
  appRequests: appRequestsFixture,
  codeScanningAlerts: codeScanningAlertsFixture,
  dependabotAlerts: dependabotAlertsFixture,
  secureScore: secureScoreFixture,
  secureScoreControls: secureScoreControlsFixture,
  azureCost: azureCostFixture,
};

/**
 * Local mode provider (Phase P default in dev). All three tabs now render from
 * the committed fixtures above.
 *
 * The Ops tab used to read the Track A generator output
 * (`data/generated/cost_daily.json` + `telemetry_summary.json`) through the
 * loader below. It no longer does: since F117 that tab reports what the ESTATE
 * COSTS TO RUN, from Cost Management via data-api, rather than the fictional
 * launch company's programme budget and flight telemetry.
 *
 * The loader and the /local-data vite middleware are kept - they are the
 * facility for rendering a generated table locally, and `fetchLocalJson` is
 * exported API - but no tab currently uses one.
 */
export class LocalProvider implements DataProvider {
  readonly source =
    "local fixtures (Dev/Sec) + data/generated (Ops), seed 20260822";

  private readonly cache = new Map<string, Promise<unknown>>();

  constructor(
    private readonly loader: JsonLoader = fetchLocalJson,
    private readonly fixtures: FeedBundle = localFixtures,
  ) {}

  private table<T>(name: string): Promise<T[]> {
    let pending = this.cache.get(name);
    if (!pending) {
      pending = this.loader(name).then((json) => {
        if (!Array.isArray(json)) {
          throw new Error(`Expected ${name}.json to contain an array of rows.`);
        }
        return json;
      });
      // Drop failed loads so a retry (e.g. after running the generators) works.
      pending.catch(() => this.cache.delete(name));
      this.cache.set(name, pending);
    }
    return pending as Promise<T[]>;
  }

  async getDevSpec(): Promise<Spec> {
    return buildDevSpec(this.fixtures.workflowRuns, this.fixtures.appRequests);
  }

  async getSecSpec(): Promise<Spec> {
    return buildSecSpec(
      this.fixtures.codeScanningAlerts,
      this.fixtures.dependabotAlerts,
      this.fixtures.secureScore,
      this.fixtures.secureScoreControls,
    );
  }

  async getOpsSpec(): Promise<Spec> {
    // Fixture-backed like Dev and Sec since F117: the Ops tab reads Cost
    // Management, not the generator's synthetic cost_daily table.
    return buildOpsSpec(this.fixtures.azureCost);
  }
}

/** Default loader: fetch a generated table from the vite local-data middleware. */
export async function fetchLocalJson(table: string): Promise<unknown> {
  const res = await fetch(`/local-data/${table}.json`);
  if (!res.ok) {
    throw new Error(
      `Local data ${table}.json is unavailable (HTTP ${res.status}). ` +
        "Generate it with `python -m generators build` from the data/ directory, then reload.",
    );
  }
  return res.json();
}
