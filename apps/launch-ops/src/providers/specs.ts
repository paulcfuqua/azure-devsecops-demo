import type {
  ComponentSpec,
  DataTableCell,
  Spec,
  TimelineEvent,
  TimelineEventKind,
} from "@mls/spec-renderer";
import type { LaunchRow, PadRow, ScrubRow, VehicleRow } from "./types";

/**
 * Pure spec builders: generator/API rows in, `@mls/spec-renderer` specs out.
 * Shared by LocalJsonProvider (LOCAL_DATA mode) and ApiProvider (L7 live
 * mode) so both modes render identically for the same rows.
 */

const WEEKDAYS = [
  "Sunday",
  "Monday",
  "Tuesday",
  "Wednesday",
  "Thursday",
  "Friday",
  "Saturday",
] as const;

/** Parse "YYYY-MM-DD" as UTC midnight; null when absent/unparseable. */
function parseDate(value: string | null | undefined): Date | null {
  if (!value || !/^\d{4}-\d{2}-\d{2}/.test(value)) return null;
  const d = new Date(`${value.slice(0, 10)}T00:00:00Z`);
  return Number.isNaN(d.getTime()) ? null : d;
}

function round(value: number, decimals: number): number {
  const f = 10 ** decimals;
  return Math.round(value * f) / f;
}

function titleCase(value: string): string {
  return value
    .split(/[_\s]+/)
    .filter(Boolean)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");
}

function cell(value: string | number | boolean | null | undefined): DataTableCell {
  return value === undefined ? null : value;
}

const OUTCOME_KIND: Record<string, TimelineEventKind> = {
  success: "success",
  partial_failure: "warning",
  failure: "danger",
};

export function buildScheduleSpec(
  launches: LaunchRow[],
  vehicles: VehicleRow[],
  pads: PadRow[],
): Spec {
  const vehicleName = new Map(vehicles.map((v) => [v.vehicle_id, v.name]));
  const padName = new Map(pads.map((p) => [p.pad_id, p.name]));

  const dated = launches
    .filter((l) => parseDate(l.planned_date) !== null)
    .sort((a, b) => b.planned_date.localeCompare(a.planned_date));

  const recent = dated.slice(0, 20);
  const rows = recent.map((l) => ({
    mission: cell(l.mission_name),
    customer: cell(l.customer),
    vehicle: cell(vehicleName.get(l.vehicle_id) ?? l.vehicle_id),
    pad: cell(padName.get(l.pad_id) ?? l.pad_id),
    planned: cell(l.planned_date),
    actual: cell(l.actual_date),
    outcome: cell(titleCase(l.outcome)),
    payload_kg: cell(l.payload_mass_kg),
  }));

  const events: TimelineEvent[] = dated
    .filter((l) => l.actual_date !== null)
    .slice(0, 12)
    .reverse()
    .map((l) => ({
      date: l.actual_date ?? l.planned_date,
      label: `${l.mission_name} — ${titleCase(l.outcome)}`,
      description: `${vehicleName.get(l.vehicle_id) ?? l.vehicle_id} from ${
        padName.get(l.pad_id) ?? l.pad_id
      }`,
      kind: OUTCOME_KIND[l.outcome] ?? "info",
    }));

  const components: ComponentSpec[] = [
    {
      type: "dataTable",
      title: "Launch schedule",
      description: "20 most recent launches by planned date.",
      columns: [
        { key: "mission", label: "Mission" },
        { key: "customer", label: "Customer" },
        { key: "vehicle", label: "Vehicle" },
        { key: "pad", label: "Pad" },
        { key: "planned", label: "Planned" },
        { key: "actual", label: "Actual" },
        { key: "outcome", label: "Outcome" },
        { key: "payload_kg", label: "Payload (kg)", align: "right" },
      ],
      rows,
    },
  ];
  if (events.length > 0) {
    components.push({
      type: "timeline",
      title: "Recent launch milestones",
      description: "Latest flown missions, oldest first.",
      events,
    });
  }
  return { version: "1", layout: "stack", components };
}

export function buildOutcomesSpec(launches: LaunchRow[]): Spec {
  const total = launches.length;
  const byOutcome = new Map<string, number>();
  for (const l of launches) {
    const key = l.outcome || "unknown";
    byOutcome.set(key, (byOutcome.get(key) ?? 0) + 1);
  }
  const successes = byOutcome.get("success") ?? 0;
  const successRate = total > 0 ? round((successes / total) * 100, 1) : 0;
  const totalScrubs = launches.reduce((sum, l) => sum + (l.scrub_count ?? 0), 0);

  const outcomeOrder = ["success", "partial_failure", "failure"];
  const outcomeData = [...byOutcome.entries()]
    .sort(
      (a, b) =>
        (outcomeOrder.indexOf(a[0]) + 1 || 99) - (outcomeOrder.indexOf(b[0]) + 1 || 99),
    )
    .map(([outcome, count]) => ({ x: titleCase(outcome), y: count }));

  const weekdayCounts = new Array<number>(7).fill(0);
  for (const l of launches) {
    const d = parseDate(l.actual_date) ?? parseDate(l.planned_date);
    if (d) weekdayCounts[d.getUTCDay()] = (weekdayCounts[d.getUTCDay()] ?? 0) + 1;
  }
  // Monday-first display order.
  const weekdayData = [1, 2, 3, 4, 5, 6, 0].map((day) => ({
    x: WEEKDAYS[day] as string,
    y: weekdayCounts[day] ?? 0,
  }));

  const components: ComponentSpec[] = [
    {
      type: "kpiRow",
      title: "Launch outcomes at a glance",
      items: [
        { label: "Total launches", value: total },
        { label: "Success rate", value: successRate, unit: "%", decimals: 1 },
        {
          label: "Scrubs per launch",
          value: total > 0 ? round(totalScrubs / total, 2) : 0,
          decimals: 2,
        },
      ],
    },
  ];
  if (outcomeData.length > 0) {
    components.push({
      type: "barChart",
      title: "Launch outcomes",
      description: "Mission count by final outcome.",
      data: outcomeData,
    });
  }
  components.push({
    type: "barChart",
    title: "Launches by weekday",
    description:
      "Range scheduling favours Saturday launch windows — the weekday bias is real in the data, not a rendering artifact.",
    data: weekdayData,
  });
  return { version: "1", layout: "stack", components };
}

export function buildScrubAnalysisSpec(scrubs: ScrubRow[]): Spec {
  const total = scrubs.length;

  const recycle = scrubs
    .map((s) => s.recycle_hours)
    .filter((h): h is number => typeof h === "number" && Number.isFinite(h));
  const avgRecycle =
    recycle.length > 0 ? round(recycle.reduce((a, b) => a + b, 0) / recycle.length, 1) : 0;

  const byCategory = new Map<string, number>();
  for (const s of scrubs) {
    const key = s.category || "unknown";
    byCategory.set(key, (byCategory.get(key) ?? 0) + 1);
  }
  const topCategory = [...byCategory.entries()].sort((a, b) => b[1] - a[1])[0];

  const byMonth = new Map<string, number>();
  for (const s of scrubs) {
    if (parseDate(s.scrub_date) === null) continue;
    const month = s.scrub_date.slice(0, 7);
    byMonth.set(month, (byMonth.get(month) ?? 0) + 1);
  }
  const monthly = [...byMonth.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    // Anchor buckets at noon UTC: the renderer coerces ISO strings to Date and
    // charts display in the viewer's local zone, so midnight would slide the
    // label back a day west of Greenwich.
    .map(([month, count]) => ({ x: `${month}-01T12:00:00Z`, y: count }));

  const components: ComponentSpec[] = [
    { type: "statCard", title: "Total scrubs", value: total },
    {
      type: "statCard",
      title: "Avg recycle time",
      description: "Hours from scrub call to the next attempt.",
      value: avgRecycle,
      unit: "h",
      decimals: 1,
    },
    {
      type: "statCard",
      title: "Top scrub cause",
      description: topCategory
        ? `${topCategory[1]} of ${total} scrubs (${round((topCategory[1] / total) * 100, 0)}%).`
        : undefined,
      value: topCategory ? titleCase(topCategory[0]) : "n/a",
    },
  ];
  if (monthly.length >= 2) {
    components.push({
      type: "lineChart",
      title: "Scrubs per month",
      description: "Scrub events aggregated by calendar month.",
      data: monthly,
    });
  }
  return { version: "1", layout: "grid", components };
}

export function buildReferenceSpec(vehicles: VehicleRow[], pads: PadRow[]): Spec {
  const vehicleRows = vehicles.slice(0, 200).map((v) => ({
    name: cell(v.name),
    class: cell(v.vehicle_class ? titleCase(v.vehicle_class) : null),
    stages: cell(v.stages),
    reusable: cell(v.reusable),
    leo_kg: cell(v.leo_capacity_kg),
    gto_kg: cell(v.gto_capacity_kg),
    first_flight: cell(v.first_flight_year),
    status: cell(v.status ? titleCase(v.status) : null),
  }));
  const padRows = pads.slice(0, 200).map((p) => ({
    name: cell(p.name),
    site: cell(p.site),
    country: cell(p.country),
    first_used: cell(p.first_used_year),
    status: cell(p.status ? titleCase(p.status) : null),
  }));
  return {
    version: "1",
    layout: "stack",
    components: [
      {
        type: "dataTable",
        title: "Vehicle fleet",
        description: "Launch vehicles available to Meridian missions.",
        columns: [
          { key: "name", label: "Vehicle" },
          { key: "class", label: "Class" },
          { key: "stages", label: "Stages", align: "right" },
          { key: "reusable", label: "Reusable" },
          { key: "leo_kg", label: "LEO (kg)", align: "right" },
          { key: "gto_kg", label: "GTO (kg)", align: "right" },
          { key: "first_flight", label: "First flight", align: "right" },
          { key: "status", label: "Status" },
        ],
        rows: vehicleRows,
      },
      {
        type: "dataTable",
        title: "Launch pads",
        description: "Pads in the demo dataset (public sites; synthetic usage).",
        columns: [
          { key: "name", label: "Pad" },
          { key: "site", label: "Site" },
          { key: "country", label: "Country" },
          { key: "first_used", label: "First used", align: "right" },
          { key: "status", label: "Status" },
        ],
        rows: padRows,
      },
    ],
  };
}
