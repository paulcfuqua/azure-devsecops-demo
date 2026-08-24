#!/usr/bin/env node
// =============================================================================
// self-heal-triage.mjs — showpiece #3, the triage half.
//
// Given ONE GitHub security alert (Dependabot or code scanning), ask Claude for
// a structured triage verdict and emit two artefacts:
//
//   <OUTPUT_DIR>/triage.json  machine-readable — the workflow builds the patch
//                             and the PR title from this
//   <OUTPUT_DIR>/triage.md    the human-readable explanation posted as the PR
//                             comment (L10 V10.1 stage 2 greps for the marker
//                             string "self-heal triage")
//
// Why this lives in a committed script and not inline YAML: prompt text and
// response parsing are the two things most likely to need iteration, and both
// are unreviewable buried in a `run:` block. Here they are diffable, and the
// pure helpers below are importable by a unit test.
//
// MOCK MODE: with no ANTHROPIC_API_KEY the script emits a deterministic verdict
// derived from the alert payload instead of calling the API. That keeps the
// whole self-heal workflow exercisable before the sponsor provisions the key
// (Phase P has no key and no tenant) and keeps CI free of spend.
//
// Model: claude-opus-5 with adaptive thinking and server-side refusal fallbacks.
// Cost: roughly $0.50 per heal (master plan L10).
// =============================================================================

import { readFileSync, writeFileSync, mkdirSync, appendFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const DEFAULT_MODEL = "claude-opus-5";
export const TRIAGE_MARKER = "self-heal triage";

const SYSTEM_PROMPT = `You are the triage step of an automated self-healing security pipeline for a
public demo monorepo (Node/TypeScript apps, a Python data generator, Bicep infrastructure).

You receive exactly one security alert. Decide the smallest correct remediation and explain it
for a human reading the resulting pull request.

Rules:
- Prefer the minimum version bump that clears the advisory. Never propose a major-version jump
  when a patch or minor release fixes it.
- If the alert is a code-scanning finding rather than a vulnerable dependency, say so and set
  action to "code-change"; do not invent a dependency bump.
- If you cannot determine a safe fix, set action to "no-action" and explain what a human should
  check. A pipeline that honestly refuses a bad heal is worth more than one that always ships.
- Never suggest suppressing, ignoring, or downgrading the severity of a finding.

Respond with a single JSON object and nothing else - no prose before or after, no code fence.
Schema:
{
  "summary": string,                 // one sentence, <= 120 characters
  "severity": "critical" | "high" | "medium" | "low",
  "package": string | null,          // dependency name, null for code-scanning findings
  "ecosystem": string | null,        // "npm" | "pip" | "github-actions" | null
  "vulnerable_version": string | null,
  "patched_version": string | null,  // the exact version to pin
  "manifest_directory": string | null, // repo-relative directory holding the manifest
  "action": "bump-dependency" | "code-change" | "no-action",
  "confidence": "high" | "medium" | "low",
  "explanation_markdown": string     // 2-5 short paragraphs: what, why it matters here, what changed
}`;

// --- pure helpers (exported for unit tests) ---------------------------------

/** Normalises a Dependabot or code-scanning alert into the fields the prompt needs. */
export function normaliseAlert(kind, alert) {
  if (kind === "dependabot") {
    const advisory = alert?.security_advisory ?? {};
    const vuln = alert?.security_vulnerability ?? {};
    return {
      kind,
      number: alert?.number ?? null,
      state: alert?.state ?? null,
      title: advisory.summary ?? "Dependabot alert",
      severity: advisory.severity ?? vuln.severity ?? "unknown",
      identifiers: (advisory.identifiers ?? []).map((i) => `${i.type}:${i.value}`),
      description: advisory.description ?? "",
      package: vuln?.package?.name ?? alert?.dependency?.package?.name ?? null,
      ecosystem: vuln?.package?.ecosystem ?? alert?.dependency?.package?.ecosystem ?? null,
      vulnerableRange: vuln?.vulnerable_version_range ?? null,
      firstPatchedVersion: vuln?.first_patched_version?.identifier ?? null,
      manifestPath: alert?.dependency?.manifest_path ?? null,
      url: alert?.html_url ?? null,
    };
  }
  const rule = alert?.rule ?? {};
  const instance = alert?.most_recent_instance ?? {};
  return {
    kind: "code-scanning",
    number: alert?.number ?? null,
    state: alert?.state ?? null,
    title: rule.description ?? rule.name ?? "Code scanning alert",
    severity: rule.security_severity_level ?? rule.severity ?? "unknown",
    identifiers: rule.id ? [rule.id] : [],
    description: rule.full_description ?? rule.description ?? "",
    package: null,
    ecosystem: null,
    vulnerableRange: null,
    firstPatchedVersion: null,
    manifestPath: instance?.location?.path ?? null,
    url: alert?.html_url ?? null,
  };
}

/** Builds the single user message describing the alert. */
export function buildUserMessage(normalised) {
  const lines = [
    `Alert kind: ${normalised.kind}`,
    `Alert number: ${normalised.number ?? "unknown"}`,
    `Title: ${normalised.title}`,
    `Severity: ${normalised.severity}`,
  ];
  if (normalised.identifiers.length > 0) {
    lines.push(`Identifiers: ${normalised.identifiers.join(", ")}`);
  }
  if (normalised.package) {
    lines.push(`Package: ${normalised.package} (${normalised.ecosystem ?? "unknown ecosystem"})`);
  }
  if (normalised.vulnerableRange) {
    lines.push(`Vulnerable range: ${normalised.vulnerableRange}`);
  }
  if (normalised.firstPatchedVersion) {
    lines.push(`First patched version reported by GitHub: ${normalised.firstPatchedVersion}`);
  }
  if (normalised.manifestPath) {
    lines.push(`Manifest / file path: ${normalised.manifestPath}`);
  }
  if (normalised.description) {
    lines.push("", "Advisory text:", normalised.description.slice(0, 6000));
  }
  lines.push(
    "",
    "Repository layout you may rely on:",
    "- npm workspace root at /, members apps/launch-ops, apps/control-tower, apps/copilot-svc, apps/shared/spec-renderer",
    "- apps/vuln-lab is a standalone npm package deliberately excluded from the workspace",
    "- Python generator package at data/generators (pytest is its only dependency)",
    "",
    "Return the JSON object described in the system prompt.",
  );
  return lines.join("\n");
}

/** Extracts the JSON object from a model response that may or may not be fenced. */
export function extractJson(text) {
  const trimmed = String(text ?? "").trim();
  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/);
  const candidate = fenced ? fenced[1] : trimmed;
  const start = candidate.indexOf("{");
  const end = candidate.lastIndexOf("}");
  if (start === -1 || end === -1 || end < start) {
    throw new Error("No JSON object found in the triage response.");
  }
  return JSON.parse(candidate.slice(start, end + 1));
}

const ACTIONS = new Set(["bump-dependency", "code-change", "no-action"]);
const SEVERITIES = new Set(["critical", "high", "medium", "low"]);

/** Validates and normalises the model's verdict; throws on an unusable shape. */
export function validateVerdict(raw, normalised) {
  if (!raw || typeof raw !== "object") {
    throw new Error("Triage response was not a JSON object.");
  }
  const action = ACTIONS.has(raw.action) ? raw.action : "no-action";
  const severity = SEVERITIES.has(String(raw.severity).toLowerCase())
    ? String(raw.severity).toLowerCase()
    : "medium";
  const verdict = {
    summary: String(raw.summary ?? normalised.title).slice(0, 200),
    severity,
    package: raw.package ?? normalised.package ?? null,
    ecosystem: raw.ecosystem ?? normalised.ecosystem ?? null,
    vulnerable_version: raw.vulnerable_version ?? normalised.vulnerableRange ?? null,
    patched_version: raw.patched_version ?? normalised.firstPatchedVersion ?? null,
    manifest_directory: raw.manifest_directory ?? deriveDirectory(normalised.manifestPath),
    action,
    confidence: ["high", "medium", "low"].includes(raw.confidence) ? raw.confidence : "medium",
    explanation_markdown: String(raw.explanation_markdown ?? "").trim(),
    alert_kind: normalised.kind,
    alert_number: normalised.number,
    alert_url: normalised.url,
  };
  if (verdict.action === "bump-dependency" && (!verdict.package || !verdict.patched_version)) {
    // A bump we cannot express is not a bump. Degrade rather than emit a broken patch.
    verdict.action = "no-action";
    verdict.explanation_markdown +=
      "\n\n_Downgraded to no-action: the triage did not produce both a package name and a patched version._";
  }
  if (!verdict.explanation_markdown) {
    verdict.explanation_markdown = `No explanation was produced for ${verdict.summary}.`;
  }
  return verdict;
}

function deriveDirectory(manifestPath) {
  if (!manifestPath) return null;
  const dir = dirname(manifestPath);
  return dir === "." || dir === "" ? "." : dir;
}

/** Renders the PR comment. The marker string is what L10 V10.1 stage 2 greps for. */
export function renderComment(verdict) {
  const rows = [
    ["Alert", verdict.alert_url ? `[#${verdict.alert_number}](${verdict.alert_url})` : `#${verdict.alert_number}`],
    ["Severity", verdict.severity],
    ["Action", `\`${verdict.action}\``],
    ["Confidence", verdict.confidence],
  ];
  if (verdict.package) {
    rows.push(["Package", `\`${verdict.package}\` (${verdict.ecosystem ?? "unknown"})`]);
  }
  if (verdict.patched_version) {
    rows.push(["Patched version", `\`${verdict.patched_version}\``]);
  }
  if (verdict.manifest_directory) {
    rows.push(["Manifest directory", `\`${verdict.manifest_directory}\``]);
  }

  return [
    `## ${TRIAGE_MARKER}`,
    "",
    `**${verdict.summary}**`,
    "",
    "| | |",
    "|---|---|",
    ...rows.map(([k, v]) => `| ${k} | ${v} |`),
    "",
    verdict.explanation_markdown,
    "",
    "---",
    "",
    "_Produced by `.github/workflows/self-heal.yml` via `.github/scripts/self-heal-triage.mjs`._",
    "_This PR auto-merges once the full CI gauntlet is green — see the workflow header for why that is deliberate here._",
  ].join("\n");
}

/** Deterministic verdict used when no API key is available. */
export function mockVerdict(normalised) {
  const canBump = Boolean(normalised.package && normalised.firstPatchedVersion);
  return validateVerdict(
    {
      summary: `${normalised.package ?? "finding"}: ${normalised.title}`.slice(0, 120),
      severity: String(normalised.severity ?? "medium").toLowerCase(),
      package: normalised.package,
      ecosystem: normalised.ecosystem,
      vulnerable_version: normalised.vulnerableRange,
      patched_version: normalised.firstPatchedVersion,
      manifest_directory: deriveDirectory(normalised.manifestPath),
      action: canBump ? "bump-dependency" : "no-action",
      confidence: "low",
      explanation_markdown: [
        "**Mock triage — no `ANTHROPIC_API_KEY` was available, so this verdict came from the",
        "alert payload rather than from Claude.**",
        "",
        canBump
          ? `GitHub reports the advisory is fixed in \`${normalised.firstPatchedVersion}\`, so the patch pins that version.`
          : "No patched version was reported, so no automated patch was proposed.",
        "",
        "Provide the API key to get a real explanation of blast radius and alternatives.",
      ].join("\n"),
    },
    normalised,
  );
}

// --- API call ---------------------------------------------------------------

async function triageWithClaude(normalised, model) {
  const { default: Anthropic } = await import("@anthropic-ai/sdk");
  const client = new Anthropic();

  const response = await client.beta.messages.create({
    model,
    max_tokens: 16000,
    // Server-side refusal fallbacks: if a safety classifier declines this
    // (security advisories read a lot like exploit requests), the API retries on
    // a fallback model inside the same call rather than leaving the chain dead.
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    thinking: { type: "adaptive" },
    output_config: { effort: "high" },
    system: SYSTEM_PROMPT,
    messages: [{ role: "user", content: buildUserMessage(normalised) }],
  });

  if (response.stop_reason === "refusal") {
    const category = response.stop_details?.category ?? "unknown";
    throw new Error(`Triage refused by the model (category: ${category}).`);
  }

  const text = response.content
    .filter((block) => block.type === "text")
    .map((block) => block.text)
    .join("\n");

  return validateVerdict(extractJson(text), normalised);
}

// --- entry point ------------------------------------------------------------

async function main() {
  const alertFile = process.env.ALERT_FILE;
  const alertKind = process.env.ALERT_KIND === "code-scanning" ? "code-scanning" : "dependabot";
  const outputDir = process.env.OUTPUT_DIR || "self-heal";
  const model = process.env.ANTHROPIC_MODEL || DEFAULT_MODEL;

  if (!alertFile) {
    throw new Error("ALERT_FILE is required (path to the alert JSON payload).");
  }

  const alert = JSON.parse(readFileSync(alertFile, "utf8"));
  const normalised = normaliseAlert(alertKind, alert);

  let verdict;
  let mode;
  if (process.env.ANTHROPIC_API_KEY) {
    mode = "live";
    verdict = await triageWithClaude(normalised, model);
  } else {
    mode = "mock";
    console.warn("ANTHROPIC_API_KEY is not set — emitting a deterministic mock triage.");
    verdict = mockVerdict(normalised);
  }
  verdict.mode = mode;
  verdict.model = mode === "live" ? model : null;

  mkdirSync(outputDir, { recursive: true });
  const jsonPath = join(outputDir, "triage.json");
  const commentPath = join(outputDir, "triage.md");
  writeFileSync(jsonPath, `${JSON.stringify(verdict, null, 2)}\n`, "utf8");
  writeFileSync(commentPath, `${renderComment(verdict)}\n`, "utf8");

  console.log(`Triage (${mode}): ${verdict.action} — ${verdict.summary}`);

  if (process.env.GITHUB_OUTPUT) {
    appendFileSync(
      process.env.GITHUB_OUTPUT,
      [
        `action=${verdict.action}`,
        `package=${verdict.package ?? ""}`,
        `ecosystem=${verdict.ecosystem ?? ""}`,
        `patched_version=${verdict.patched_version ?? ""}`,
        `manifest_directory=${verdict.manifest_directory ?? ""}`,
        `severity=${verdict.severity}`,
        `mode=${mode}`,
        `triage_json=${jsonPath}`,
        `triage_md=${commentPath}`,
        "",
      ].join("\n"),
      "utf8",
    );
  }
}

const invokedDirectly =
  Boolean(process.argv[1]) && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (invokedDirectly) {
  main().catch((error) => {
    console.error(`::error title=Self-heal triage failed::${error.message}`);
    process.exitCode = 1;
  });
}
