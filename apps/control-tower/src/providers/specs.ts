import type { ComponentSpec, Spec } from "@mls/spec-renderer";
import type {
  CodeScanningAlert,
  CostDailyRow,
  DependabotAlert,
  LogAnalyticsResult,
  SecureScoreControlsResponse,
  SecureScoreResponse,
  TelemetrySummaryRow,
  WorkflowRunsFeed,
} from "./types";

/**
 * Pure spec builders: feed payloads in, `@mls/spec-renderer` specs out.
 * Shared by LocalProvider (fixtures + generated JSON) and ApiProvider (live
 * feeds at L7/L9) so both modes render identically for the same payloads.
 */

function round(value: number, decimals: number): number {
  const f = 10 ** decimals;
  return Math.round(value * f) / f;
}

function median(values: number[]): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  const lower = sorted[mid - 1] ?? 0;
  const upper = sorted[mid] ?? 0;
  return sorted.length % 2 === 0 ? (lower + upper) / 2 : upper;
}

function minutesBetween(startIso: string, endIso: string): number | null {
  const start = Date.parse(startIso);
  const end = Date.parse(endIso);
  if (Number.isNaN(start) || Number.isNaN(end) || end < start) return null;
  return (end - start) / 60_000;
}

/**
 * A feed that did not answer, carried alongside the data that did.
 *
 * WHY THIS TYPE EXISTS (F116). Every tab used to fetch its feeds with
 * `Promise.all`, so one rejection discarded the panels that had already
 * resolved. With three GitHub feeds answering 503 for want of a token, the Dev
 * tab threw away the `app-requests` data it was holding and rendered a single
 * "Data unavailable" line - five of Control Tower's eight routes were serving
 * real data and the default view showed none of it.
 *
 * The builders therefore take NULLABLE feeds plus the list of what failed, and
 * render everything they can. A missing feed costs you its panels and says so;
 * it no longer costs you the whole tab.
 */
export interface FeedOutage {
  readonly feed: string;
  readonly reason: string;
}

/**
 * The notice for feeds that did not answer.
 *
 * It names the feed AND repeats the reason the server gave, because the reason
 * is the actionable half - "MLS_GITHUB_TOKEN is empty on this instance" tells a
 * reader what to do, where "unavailable" starts an investigation.
 */
function outageNotice(outages: readonly FeedOutage[]): ComponentSpec | null {
  if (outages.length === 0) return null;
  const lines = outages.map((o) => `- \`${o.feed}\` — ${o.reason}`).join("\n");
  return {
    type: "markdownBlock",
    title: outages.length === 1 ? "One feed is unavailable" : `${outages.length} feeds are unavailable`,
    markdown:
      "The panels below are rendered from the feeds that answered. These did not, " +
      "so anything derived from them is absent rather than zero:\n\n" +
      lines,
  };
}

/* ---------------------------------------------------------------- Dev tab */

export function buildDevSpec(
  runs: WorkflowRunsFeed | null,
  appRequests: LogAnalyticsResult | null,
  outages: readonly FeedOutage[] = [],
): Spec {
  const allRuns = runs?.workflow_runs ?? [];
  const completed = allRuns.filter(
    (r) => r.status === "completed" && r.conclusion !== null,
  );
  const successes = completed.filter((r) => r.conclusion === "success").length;
  const successRate =
    completed.length > 0 ? round((successes / completed.length) * 100, 1) : 0;

  const durations = completed
    .map((r) => minutesBetween(r.run_started_at, r.updated_at))
    .filter((m): m is number => m !== null);
  const medianDuration = round(median(durations), 1);

  const byWorkflow = new Map<string, number>();
  for (const r of allRuns) {
    byWorkflow.set(r.name, (byWorkflow.get(r.name) ?? 0) + 1);
  }
  const workflowData = [...byWorkflow.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 100)
    .map(([name, count]) => ({ x: name, y: count }));

  // Log Analytics result -> daily request success rate (all app roles pooled).
  const primary = appRequests?.tables.find((t) => t.name === "PrimaryResult");
  const successSeries: Array<{ x: string; y: number }> = [];
  if (primary) {
    const col = (name: string): number =>
      primary.columns.findIndex((c) => c.name === name);
    const timeIdx = col("TimeGenerated");
    const reqIdx = col("RequestCount");
    const failIdx = col("FailedCount");
    if (timeIdx >= 0 && reqIdx >= 0 && failIdx >= 0) {
      const byDay = new Map<string, { requests: number; failed: number }>();
      for (const row of primary.rows) {
        const time = row[timeIdx];
        const requests = row[reqIdx];
        const failed = row[failIdx];
        if (typeof time !== "string" || typeof requests !== "number") continue;
        const day = time.slice(0, 10);
        const agg = byDay.get(day) ?? { requests: 0, failed: 0 };
        agg.requests += requests;
        agg.failed += typeof failed === "number" ? failed : 0;
        byDay.set(day, agg);
      }
      for (const [day, agg] of [...byDay.entries()].sort((a, b) =>
        a[0].localeCompare(b[0]),
      )) {
        if (agg.requests <= 0) continue;
        successSeries.push({
          // Anchor at noon UTC: the renderer coerces ISO strings to Date and
          // charts display in the viewer's local zone, so midnight would slide
          // the label back a day west of Greenwich.
          x: `${day}T12:00:00Z`,
          y: round((1 - agg.failed / agg.requests) * 100, 2),
        });
      }
    }
  }

  const recentRuns = [...allRuns]
    .sort((a, b) => b.run_started_at.localeCompare(a.run_started_at))
    .slice(0, 10)
    .map((r) => ({
      workflow: r.name,
      branch: r.head_branch,
      event: r.event,
      conclusion: r.conclusion ?? r.status,
      started: r.run_started_at.slice(0, 16).replace("T", " "),
      minutes: (() => {
        const m = minutesBetween(r.run_started_at, r.updated_at);
        return m === null ? null : round(m, 1);
      })(),
    }));

  const components: ComponentSpec[] = [];
  const notice = outageNotice(outages);
  if (notice) components.push(notice);
  // The KPI row is skipped entirely rather than shown with zeros: a "CI success
  // rate: 0%" for a feed that never answered is a confident wrong number, and
  // the schema requires at least one item anyway.
  if (runs) {
    components.push({
      type: "kpiRow",
      title: "Delivery health",
      description:
        "Well-Architected: Operational Excellence — CI throughput and reliability.",
      items: [
        { label: "Workflow runs (14 days)", value: runs.total_count },
        { label: "CI success rate", value: successRate, unit: "%", decimals: 1 },
        { label: "Median run duration", value: medianDuration, unit: "min", decimals: 1 },
        { label: "Active workflows", value: byWorkflow.size },
      ],
    });
  }
  if (workflowData.length > 0) {
    components.push({
      type: "barChart",
      title: "Runs by workflow",
      description: "Path-filtered per-app pipelines plus scheduled CodeQL scans.",
      data: workflowData,
    });
  }
  if (successSeries.length >= 2) {
    components.push({
      type: "lineChart",
      title: "Request success rate",
      description: "Daily HTTP success percentage across both apps (App Insights).",
      data: successSeries,
      unit: "%",
      decimals: 2,
    });
  }
  if (recentRuns.length > 0) {
    components.push({
      type: "dataTable",
      title: "Recent workflow runs",
      columns: [
        { key: "workflow", label: "Workflow" },
        { key: "branch", label: "Branch" },
        { key: "event", label: "Event" },
        { key: "conclusion", label: "Conclusion" },
        { key: "started", label: "Started (UTC)" },
        { key: "minutes", label: "Duration (min)", align: "right" },
      ],
      rows: recentRuns,
    });
  }
  return { version: "1", layout: "stack", components };
}

/* ---------------------------------------------------------------- Sec tab */

const SEVERITY_ORDER = ["critical", "high", "medium", "low"] as const;

/** GitHub Dependabot uses "moderate" where code scanning uses "medium". */
function normalizeSeverity(value: string | undefined): string {
  const v = (value ?? "").toLowerCase();
  if (v === "moderate") return "medium";
  return SEVERITY_ORDER.includes(v as (typeof SEVERITY_ORDER)[number]) ? v : "low";
}

function severityLabel(value: string): string {
  return value.charAt(0).toUpperCase() + value.slice(1);
}

export function buildSecSpec(
  codeAlerts: CodeScanningAlert[] | null,
  depAlerts: DependabotAlert[] | null,
  secureScore: SecureScoreResponse | null,
  controls: SecureScoreControlsResponse | null,
  outages: readonly FeedOutage[] = [],
): Spec {
  const openCode = (codeAlerts ?? []).filter((a) => a.state === "open");
  const openDep = (depAlerts ?? []).filter((a) => a.state === "open");

  const severityCounts = new Map<string, number>(SEVERITY_ORDER.map((s) => [s, 0]));
  for (const a of openCode) {
    const s = normalizeSeverity(a.rule.security_severity_level);
    severityCounts.set(s, (severityCounts.get(s) ?? 0) + 1);
  }
  for (const a of openDep) {
    const s = normalizeSeverity(a.security_advisory.severity);
    severityCounts.set(s, (severityCounts.get(s) ?? 0) + 1);
  }
  const criticalOpen = severityCounts.get("critical") ?? 0;

  // AN UNREPORTED SECURE SCORE IS NOT A SCORE OF ZERO.
  //
  // This read `score ? round(...) : 0`, so a Defender response carrying no score
  // rendered "Defender secure score: 0.0%" - the most alarming number the panel
  // can show, produced by having no number at all. The live estate answers this
  // feed `200 {"value":[]}`, so that is what the dashboard was displaying.
  //
  // Worse, an empty list is exactly what Defender's ARM API returns to a caller
  // who cannot read it, so "0%" was standing in for two different states, one of
  // which is "you are not allowed to know". That is the absence-vs-denial class
  // this repository has now paid for five times (F102, F103, F104, F105, F106).
  // The identity does currently hold Security Reader, which makes a genuine
  // empty the likelier of the two - but the panel cannot tell them apart, so it
  // must not assert either.
  const score = secureScore?.value[0]?.properties.score;
  const scorePct = score ? round(score.percentage * 100, 1) : null;

  const severityRank = (s: string): number => {
    const i = SEVERITY_ORDER.indexOf(s as (typeof SEVERITY_ORDER)[number]);
    return i === -1 ? SEVERITY_ORDER.length : i;
  };
  const openRows = [
    ...openCode.map((a) => ({
      source: a.tool.name,
      reference: a.rule.id,
      severity: normalizeSeverity(a.rule.security_severity_level),
      detail: a.rule.description,
      since: a.created_at.slice(0, 10),
    })),
    ...openDep.map((a) => ({
      source: "Dependabot",
      reference: a.security_advisory.cve_id ?? a.security_advisory.ghsa_id,
      severity: normalizeSeverity(a.security_advisory.severity),
      detail: `${a.dependency.package.ecosystem}/${a.dependency.package.name}: ${a.security_advisory.summary}`,
      since: a.created_at.slice(0, 10),
    })),
  ]
    .sort(
      (a, b) => severityRank(a.severity) - severityRank(b.severity) || a.since.localeCompare(b.since),
    )
    .slice(0, 15)
    .map((r) => ({ ...r, severity: severityLabel(r.severity) }));

  const components: ComponentSpec[] = [];
  const notice = outageNotice(outages);
  if (notice) components.push(notice);
  components.push(
    {
      type: "kpiRow",
      title: "Security posture",
      description:
        "Well-Architected: Security — GitHub Advanced Security findings and Defender for Cloud secure score.",
      items: [
        // Same rule as the secure score below: a feed that did not answer yields
        // "not reported", never 0. "Open code scanning alerts: 0" is the single
        // most reassuring thing this dashboard can say, and saying it because
        // the endpoint returned 503 is the exact failure the working agreement
        // on absence-vs-denial exists to stop.
        codeAlerts === null
          ? { label: "Open code scanning alerts", value: "not reported" }
          : { label: "Open code scanning alerts", value: openCode.length },
        depAlerts === null
          ? { label: "Open dependency alerts", value: "not reported" }
          : { label: "Open dependency alerts", value: openDep.length },
        codeAlerts === null || depAlerts === null
          ? { label: "Critical (open)", value: "not reported" }
          : {
              label: "Critical (open)",
              value: criticalOpen,
              trend: criticalOpen > 0 ? "up" : "flat",
            },
        scorePct === null
          ? { label: "Defender secure score", value: "not reported" }
          : { label: "Defender secure score", value: scorePct, unit: "%", decimals: 1 },
      ],
    },
    {
      type: "barChart",
      title: "Open alerts by severity",
      description: "Code scanning + Dependabot, open alerts only.",
      data: SEVERITY_ORDER.map((s) => ({
        x: severityLabel(s),
        y: severityCounts.get(s) ?? 0,
      })),
    },
  );
  const controlData = (controls?.value ?? [])
    .slice(0, 100)
    .map((c) => ({
      x: c.properties.displayName,
      y: round(c.properties.score.percentage * 100, 0),
    }));
  if (controlData.length > 0) {
    components.push({
      type: "barChart",
      title: "Secure score by control",
      description: "Defender for Cloud secure score controls, percent achieved.",
      data: controlData,
      unit: "%",
    });
  }
  if (openRows.length > 0) {
    components.push({
      type: "dataTable",
      title: "Open security alerts",
      description: "Highest severity first. Sec feeds go live at L9.",
      columns: [
        { key: "source", label: "Source" },
        { key: "reference", label: "Rule / CVE" },
        { key: "severity", label: "Severity" },
        { key: "detail", label: "Detail" },
        { key: "since", label: "Open since" },
      ],
      rows: openRows,
    });
  }
  return { version: "1", layout: "stack", components };
}

/* ---------------------------------------------------------------- Ops tab */

export function buildOpsSpec(
  costRows: CostDailyRow[] | null,
  telemetry: TelemetrySummaryRow[] | null,
  outages: readonly FeedOutage[] = [],
): Spec {
  const byMonth = new Map<string, { amount: number; budget: number }>();
  const byCenter = new Map<string, number>();
  let totalAmount = 0;
  let totalBudget = 0;
  for (const row of costRows ?? []) {
    if (typeof row.amount_usd !== "number" || !row.date) continue;
    const month = row.date.slice(0, 7);
    const agg = byMonth.get(month) ?? { amount: 0, budget: 0 };
    agg.amount += row.amount_usd;
    agg.budget += typeof row.budget_usd === "number" ? row.budget_usd : 0;
    byMonth.set(month, agg);
    totalAmount += row.amount_usd;
    totalBudget += typeof row.budget_usd === "number" ? row.budget_usd : 0;
    if (row.cost_center) {
      byCenter.set(row.cost_center, (byCenter.get(row.cost_center) ?? 0) + row.amount_usd);
    }
  }
  const monthly = [...byMonth.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    // Noon-UTC anchor, same reason as the Dev series above.
    .map(([month, agg]) => ({
      x: `${month}-01T12:00:00Z`,
      y: round(agg.amount / 1000, 1),
    }));
  const centerData = [...byCenter.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 24)
    .map(([center, amount]) => ({ label: center, value: round(amount / 1000, 0) }));

  const budgetVariance =
    totalBudget > 0 ? round(((totalAmount - totalBudget) / totalBudget) * 100, 1) : 0;

  const tele = telemetry ?? [];
  const coverage = tele
    .map((t) => t.telemetry_coverage_pct)
    .filter((v): v is number => typeof v === "number" && Number.isFinite(v));
  const avgCoverage =
    coverage.length > 0
      ? round(coverage.reduce((a, b) => a + b, 0) / coverage.length, 2)
      : 0;
  const totalAnomalies = tele.reduce((sum, t) => sum + (t.anomaly_count ?? 0), 0);
  const flightsWithAnomalies = tele.filter((t) => (t.anomaly_count ?? 0) > 0).length;
  const dropouts = tele
    .map((t) => t.data_dropout_s)
    .filter((v): v is number => typeof v === "number" && Number.isFinite(v));
  const avgDropout =
    dropouts.length > 0
      ? round(dropouts.reduce((a, b) => a + b, 0) / dropouts.length, 1)
      : 0;

  const components: ComponentSpec[] = [];
  const notice = outageNotice(outages);
  if (notice) components.push(notice);
  components.push({
    type: "kpiRow",
    title: "Cost & reliability",
    description:
      "Well-Architected: Cost Optimization + Reliability — cost exports and flight telemetry from the lakehouse.",
    items: [
      // Same rule as the Sec tab: a store that did not answer yields "not
      // reported", never a number. A spend of 0 k$ and 0 flight anomalies are
      // both plausible-looking figures that would be read as fact.
      costRows === null
        ? { label: "Program spend (all time)", value: "not reported" }
        : {
            label: "Program spend (all time)",
            value: round(totalAmount / 1000, 0),
            unit: "k$",
          },
      costRows === null
        ? { label: "Budget variance", value: "not reported" }
        : {
            label: "Budget variance",
            value: budgetVariance,
            unit: "%",
            decimals: 1,
            trend: budgetVariance > 0 ? "up" : budgetVariance < 0 ? "down" : "flat",
          },
      telemetry === null
        ? { label: "Avg telemetry coverage", value: "not reported" }
        : { label: "Avg telemetry coverage", value: avgCoverage, unit: "%", decimals: 2 },
      telemetry === null
        ? { label: "Flight anomalies", value: "not reported" }
        : { label: "Flight anomalies", value: totalAnomalies },
    ],
  });
  if (monthly.length >= 2) {
    components.push({
      type: "lineChart",
      title: "Monthly program spend",
      description: "Cost Management daily export aggregated by month, all cost centers.",
      data: monthly,
      unit: "k$",
      decimals: 1,
    });
  }
  if (centerData.length > 0) {
    components.push({
      type: "donutChart",
      title: "Spend by cost center",
      data: centerData,
      unit: "k$",
    });
  }
  components.push(
    {
      type: "statCard",
      title: "Launches with anomalies",
      description:
        tele.length > 0
          ? `${flightsWithAnomalies} of ${tele.length} flights recorded at least one anomaly.`
          : "No telemetry rows loaded.",
      value: flightsWithAnomalies,
    },
    {
      type: "statCard",
      title: "Avg data dropout",
      description: "Mean telemetry dropout per flight.",
      value: avgDropout,
      unit: "s",
      decimals: 1,
    },
  );
  return { version: "1", layout: "stack", components };
}
