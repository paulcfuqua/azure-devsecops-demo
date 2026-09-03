import type { ComponentSpec, Spec } from "@mls/spec-renderer";
import type {
  AzureCostFeed,
  CodeScanningAlert,
  DependabotAlert,
  LogAnalyticsResult,
  SecureScoreControlsResponse,
  SecureScoreResponse,
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

/**
 * SEVERITY COLOUR IS SEMANTIC, NOT CATEGORICAL (F154).
 *
 * Without these the chart library assigns from a categorical palette by index,
 * and the security board rendered Critical blue, **High green**, Medium and Low
 * pink. Green is the one colour that reads as "fine", sitting on the second-most
 * serious bar on the page. Colour was actively working against the reader.
 *
 * Chosen to stay legible on the dark ground the board renders on, and to keep an
 * order a reader can rank without the labels.
 */
const SEVERITY_COLOR: Record<string, string> = {
  critical: "#b3261e",
  high: "#d97706",
  medium: "#b8a326",
  low: "#6b7f99",
};

/**
 * Alerts deliberately planted for the demo live in `apps/vuln-lab` (L9's negative
 * test seeds them and V9.2 proves CI fails on them). Three of the eight open
 * Dependabot alerts are seeds, INCLUDING one of the two criticals - so a board
 * that does not separate them reports a fixture as posture.
 *
 * They are labelled, never hidden: removing them would be the mirror-image lie.
 */
const SEEDED_PATH_PREFIX = "apps/vuln-lab/";

/** GitHub Dependabot uses "moderate" where code scanning uses "medium". */
function normalizeSeverity(value: string | undefined): string {
  const v = (value ?? "").toLowerCase();
  if (v === "moderate") return "medium";
  return SEVERITY_ORDER.includes(v as (typeof SEVERITY_ORDER)[number]) ? v : "low";
}

function severityLabel(value: string): string {
  return value.charAt(0).toUpperCase() + value.slice(1);
}

/**
 * When a finding was closed, or null while it is open (F166).
 * `fixed_at` for a remediated alert, `dismissed_at` for one triaged away.
 */
export function closedOn(alert: {
  fixed_at?: string | null;
  dismissed_at?: string | null;
}): string | null {
  return alert.fixed_at ?? alert.dismissed_at ?? null;
}

/**
 * Opened and closed counts per day, oldest first.
 *
 * WHY THIS EXISTS. The board reported "88 open" and nothing else, which is the
 * least flattering true sentence available about this repository: 323 findings
 * have been closed. A backlog count answers "what is wrong"; posture over time
 * answers "are we winning", and the second is the question a reader actually
 * has.
 */
export function postureByDate(
  alerts: readonly { created_at: string; fixed_at?: string | null; dismissed_at?: string | null }[],
): { date: string; opened: number; closed: number }[] {
  const byDay = new Map<string, { opened: number; closed: number }>();
  const bump = (day: string, key: "opened" | "closed"): void => {
    const row = byDay.get(day) ?? { opened: 0, closed: 0 };
    row[key] += 1;
    byDay.set(day, row);
  };
  for (const a of alerts) {
    if (a.created_at) bump(a.created_at.slice(0, 10), "opened");
    const closed = closedOn(a);
    if (closed) bump(closed.slice(0, 10), "closed");
  }
  return [...byDay.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([date, v]) => ({ date, ...v }));
}

export function buildSecSpec(
  codeAlerts: CodeScanningAlert[] | null,
  depAlerts: DependabotAlert[] | null,
  secureScore: SecureScoreResponse | null,
  controls: SecureScoreControlsResponse | null,
  outages: readonly FeedOutage[] = [],
): Spec {
  // The feeds now carry EVERY state (F166), so "open" is a filter here rather
  // than something the API decided for us - and the closed ones are the half of
  // the story the board used to throw away.
  const allCode = codeAlerts ?? [];
  const allDep = depAlerts ?? [];
  const openCode = allCode.filter((a) => a.state === "open");
  const openDep = allDep.filter((a) => a.state === "open");
  const closedCount =
    allCode.filter((a) => a.state !== "open").length +
    allDep.filter((a) => a.state !== "open").length;
  const totalEverSeen = allCode.length + allDep.length;
  const openCount = openCode.length + openDep.length;

  const isSeeded = (a: DependabotAlert): boolean =>
    (a.dependency.manifest_path ?? "").startsWith(SEEDED_PATH_PREFIX);
  const seededDep = openDep.filter(isSeeded);
  const realDep = openDep.filter((a) => !isSeeded(a));

  // COUNT DISTINCT ISSUES, NOT ALERT INSTANCES (F154).
  //
  // 88 open code-scanning alerts are 30 distinct rules: the container scan raises
  // the same base-image CVE once per image, so three images inflate every finding
  // threefold. "88 open alerts" is a true number that overstates the work by 3x,
  // and this repository's whole argument is that it does not overstate itself.
  // Instances are still reported - as instances, beside the issue count.
  const codeKey = (a: CodeScanningAlert): string => a.rule.id;
  const depKey = (a: DependabotAlert): string =>
    a.security_advisory.cve_id ?? a.security_advisory.ghsa_id;

  const distinct = new Map<string, string>();
  for (const a of openCode) {
    distinct.set(`code:${codeKey(a)}`, normalizeSeverity(a.rule.security_severity_level));
  }
  for (const a of realDep) {
    distinct.set(`dep:${depKey(a)}`, normalizeSeverity(a.security_advisory.severity));
  }
  const seededDistinct = new Set(seededDep.map((a) => `dep:${depKey(a)}`));

  const severityCounts = new Map<string, number>(SEVERITY_ORDER.map((s) => [s, 0]));
  for (const sev of distinct.values()) {
    severityCounts.set(sev, (severityCounts.get(sev) ?? 0) + 1);
  }
  const criticalOpen = severityCounts.get("critical") ?? 0;
  const instanceCount = openCode.length + realDep.length;

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
      // THE CHART SAID 1 CRITICAL AND THE TABLE SAID 2 (F166). Both were right:
      // the chart excludes seeded fixtures, the table listed everything, and
      // nothing on screen explained the difference. Marking the row reconciles
      // them without hiding anything.
      source: isSeeded(a) ? "Dependabot (seeded)" : "Dependabot",
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
        codeAlerts === null || depAlerts === null
          ? { label: "Open findings (distinct)", value: "not reported" }
          : { label: "Open findings (distinct)", value: distinct.size },
        codeAlerts === null || depAlerts === null
          ? { label: "Alert instances", value: "not reported" }
          : { label: "Alert instances", value: instanceCount },
        // NOT A GAP IN THE POSTURE - A TEST FIXTURE (F166). These CVEs are planted
        // in apps/vuln-lab on purpose, and V9.2 asserts that CI FAILS on them and
        // passes once pinned. They are the evidence the pipeline blocks vulnerable
        // builds, so a board that lists them beside real exposure reports the proof
        // as though it were the problem. Labelled as what they are, and excluded
        // from the severity counts above.
        depAlerts === null
          ? { label: "Seeded CVEs (pipeline test)", value: "not reported" }
          : {
              label: "Seeded CVEs (pipeline test)",
              value: seededDistinct.size,
              trend: "flat",
            },
        codeAlerts === null || depAlerts === null
          ? { label: "Findings closed", value: "not reported" }
          : { label: "Findings closed", value: closedCount, trend: "down" },
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
      title: "Open findings by severity",
      description:
        `Distinct issues, open only — ${instanceCount} alert instances collapse to ` +
        `${distinct.size} findings, because a base-image CVE is raised once per image. ` +
        `Excludes ${seededDistinct.size} deliberately seeded in apps/vuln-lab.`,
      data: SEVERITY_ORDER.map((s) => ({
        x: severityLabel(s),
        y: severityCounts.get(s) ?? 0,
        color: SEVERITY_COLOR[s] ?? SEVERITY_COLOR.low,
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
  // POSTURE OVER TIME, not a backlog snapshot (F166). Two series on one chart:
  // what arrived, and what was dealt with. The shape is lumpy - most of this
  // estate's findings arrived and were closed on the day CodeQL first swept every
  // image - and that is the truth about a repository twelve days old rather than
  // a reason to draw something smoother.
  const posture = postureByDate([...allCode, ...allDep]);
  if (posture.length >= 2) {
    components.push({
      type: "barChart",
      title: "Findings opened and closed, by date",
      description:
        `${totalEverSeen} findings seen in total: ${closedCount} closed, ${openCount} still open. ` +
        "Opened in amber, closed in green.",
      data: [
        ...posture.map((p) => ({
          x: `${p.date} opened`,
          y: p.opened,
          color: SEVERITY_COLOR.high,
        })),
        ...posture.map((p) => ({
          x: `${p.date} closed`,
          y: p.closed,
          color: "#2c6f52",
        })),
      ],
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

/**
 * Donut slices that still sum to the whole (F156).
 *
 * Charting only the top N and discarding the tail makes the ring disagree with
 * the total printed directly above it, and makes a small line disappear
 * entirely - which is exactly what would happen to a newly enabled Defender
 * plan billing cents beside a database billing dollars. The tail is grouped and
 * labelled with its own count instead, so nothing is dropped without saying so.
 */
export function donutWithRemainder(
  services: readonly { name: string; cost: number }[],
  top: number,
  money: (n: number) => number,
): { label: string; value: number }[] {
  const named = services.slice(0, top).map((sv) => ({ label: sv.name, value: money(sv.cost) }));
  const rest = services.slice(top);
  if (rest.length === 0) return named;
  const remainder = rest.reduce((sum, sv) => sum + sv.cost, 0);
  return [...named, { label: `Other (${rest.length} services)`, value: money(remainder) }];
}

export function buildOpsSpec(
  cost: AzureCostFeed | null,
  outages: readonly FeedOutage[] = [],
): Spec {
  const components: ComponentSpec[] = [];
  const notice = outageNotice(outages);
  if (notice) components.push(notice);

  if (!cost) {
    // Nothing to be partial about. The KPI row still renders so the tab has a
    // shape, and every figure says what it is: absent, not zero.
    components.push({
      type: "kpiRow",
      title: "Platform run cost",
      description: "Azure Cost Management - what this estate costs to operate.",
      items: [
        { label: "Total run cost", value: "not reported" },
        { label: "Services billing", value: "not reported" },
        { label: "Largest line item", value: "not reported" },
      ],
    });
    return { version: "1", layout: "stack", components };
  }

  const money = (n: number): number => Math.round(n * 100) / 100;
  const top = cost.byService[0];

  // The window and the freshness belong ON the tab, not in a tooltip. "$14.81"
  // means nothing without "month to date", and a retained figure presented as a
  // current one is the same defect as an empty list presented as a zero.
  const asOfLabel = cost.asOf.slice(0, 16).replace("T", " ");
  components.push({
    type: "kpiRow",
    title: "Platform run cost",
    description:
      `Azure Cost Management, ${cost.timeframe} actual cost in ${cost.currency}. ` +
      `Read ${asOfLabel} UTC${cost.stale ? " - RETAINED, the upstream refused a fresh query" : ""}.`,
    items: [
      { label: "Total run cost", value: money(cost.total), unit: cost.currency, decimals: 2 },
      { label: "Services billing", value: cost.byService.length },
      top
        ? { label: `Largest: ${top.name}`, value: money(top.cost), unit: cost.currency, decimals: 2 }
        : { label: "Largest line item", value: "nothing billed yet" },
      {
        label: "Resource groups billing",
        value: cost.byResourceGroup.length,
      },
    ],
  });

  if (cost.daily.length >= 2) {
    components.push({
      type: "lineChart",
      title: "Daily run cost",
      description: `Actual cost per day across every service, in ${cost.currency}.`,
      // Noon UTC for the same reason the Dev tab's series uses it: the renderer
      // coerces to Date and charts in the viewer's zone, so midnight slides the
      // label back a day west of Greenwich.
      data: cost.daily.map((d) => ({ x: `${d.date}T12:00:00Z`, y: money(d.cost) })),
      unit: cost.currency,
      decimals: 2,
    });
  }

  if (cost.byService.length > 0) {
    components.push({
      type: "donutChart",
      title: "Cost by Azure service",
      description:
        `Every service billing, ${cost.timeframe}. The eight largest are named; ` +
        "the rest are grouped so the ring still totals the whole bill.",
      // A DONUT THAT DROPS SLICES DOES NOT ADD UP. This took the top 8 and
      // discarded the tail silently, so the ring totalled less than the KPI
      // beside it and a small line - a newly enabled Defender plan, say - simply
      // vanished from the chart. Grouping the tail keeps the ring reconcilable
      // with the total, which is the one property a cost chart has to have.
      data: donutWithRemainder(cost.byService, 8, money),
      unit: cost.currency,
    });
  }

  if (cost.byResourceGroup.length > 0) {
    components.push({
      type: "barChart",
      title: "Cost by resource group",
      description: "Platform, apps, data and ops - the four groups teardown deletes.",
      data: cost.byResourceGroup.map((rg) => ({ x: rg.name, y: money(rg.cost) })),
      unit: cost.currency,
      decimals: 2,
    });
  }

  if (cost.byService.length > 0) {
    components.push({
      type: "dataTable",
      title: "Run cost by service",
      description: `Actual cost, ${cost.timeframe}, highest first.`,
      columns: [
        { key: "service", label: "Azure service" },
        { key: "cost", label: `Cost (${cost.currency})`, align: "right" },
      ],
      rows: cost.byService.map((sv) => ({ service: sv.name, cost: money(sv.cost) })),
    });
  }

  return { version: "1", layout: "stack", components };
}
