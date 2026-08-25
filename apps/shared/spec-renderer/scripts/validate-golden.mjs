/**
 * `npm run validate:golden` — the command L7's V7.2 runs verbatim.
 *
 * docs/runbooks/layers/L07.md pins the criterion's query as
 *
 *     npm --prefix apps/shared/spec-renderer run validate:golden
 *
 * and verification/layer-07-audit.ps1 shells out to exactly that, treating a
 * non-zero exit as a FAIL that is never retried ("V7.2 rolls back in the repo
 * only"). The script it names did not exist, so the criterion failed with
 * npm's "Missing script" no matter what the estate looked like. This is it.
 *
 * Deliberately dependency-light and build-free: it reads spec.schema.json and
 * compiles it with the same Ajv configuration src/validate.ts uses, so it can
 * run from a clean checkout without `npm run build` first. The vitest suite
 * covers the same fixtures through the library's own entry point; this is the
 * standalone gate, and the two agreeing is the point.
 *
 * Both directions are checked. A validator that accepts everything passes a
 * valid-only sweep, which is why the three `invalid-*` fixtures must be
 * REJECTED for this to exit 0.
 */
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import Ajv2020 from "ajv/dist/2020.js";

const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const fixturesDir = join(packageRoot, "fixtures");
const schemaPath = join(packageRoot, "spec.schema.json");

/** Every component type the renderer ships, per L07.md ("all ~9 component types"). */
const EXPECTED_COMPONENT_TYPES = [
  "areaChart",
  "barChart",
  "dataTable",
  "donutChart",
  "kpiRow",
  "lineChart",
  "markdownBlock",
  "statCard",
  "timeline",
];

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf-8"));
}

function main() {
  const schema = readJson(schemaPath);
  // Identical to src/validate.ts — a golden check that compiled the schema
  // differently from the library would prove nothing about the library.
  const ajv = new Ajv2020({ allErrors: true, discriminator: true, strict: false });
  const validate = ajv.compile(schema);

  const names = readdirSync(fixturesDir)
    .filter((name) => name.endsWith(".json"))
    .sort();

  const problems = [];
  const seenTypes = new Set();
  let validCount = 0;
  let invalidCount = 0;

  for (const name of names) {
    const shouldBeValid = name.startsWith("valid-");
    const shouldBeInvalid = name.startsWith("invalid-");
    if (!shouldBeValid && !shouldBeInvalid) {
      problems.push(`${name}: fixtures must be named valid-*.json or invalid-*.json`);
      continue;
    }

    let spec;
    try {
      spec = readJson(join(fixturesDir, name));
    } catch (error) {
      problems.push(`${name}: not readable JSON — ${error.message}`);
      continue;
    }

    const ok = validate(spec);
    if (shouldBeValid) {
      validCount += 1;
      for (const component of spec.components ?? []) {
        if (typeof component?.type === "string") seenTypes.add(component.type);
      }
      if (!ok) {
        const detail = (validate.errors ?? [])
          .map((e) => `${e.instancePath || "/"} ${e.message}`)
          .join("; ");
        problems.push(`${name}: expected VALID, schema rejected it — ${detail}`);
      }
    } else {
      invalidCount += 1;
      if (ok) {
        problems.push(
          `${name}: expected INVALID, schema accepted it. A validator that accepts a known-bad spec is the failure this fixture exists to catch.`,
        );
      }
    }
  }

  const missingTypes = EXPECTED_COMPONENT_TYPES.filter((t) => !seenTypes.has(t));
  if (missingTypes.length > 0) {
    problems.push(
      `no valid fixture covers: ${missingTypes.join(", ")} — L07.md V7.2 requires the fixture set to cover every component type`,
    );
  }

  console.log(
    `validate:golden — ${validCount} valid + ${invalidCount} invalid fixture(s), ${seenTypes.size} component type(s) covered`,
  );

  if (problems.length > 0) {
    for (const problem of problems) console.error(`  FAIL ${problem}`);
    console.error(`validate:golden FAILED with ${problems.length} problem(s).`);
    process.exit(1);
  }

  console.log("validate:golden OK — every golden spec validates against spec.schema.json.");
}

main();
