/**
 * Precompile the component-spec JSON Schema into a standalone validator.
 *
 * WHY THIS EXISTS (F111). `ajv.compile()` builds its validator by generating
 * JavaScript source and evaluating it — `new Function` under the hood. The
 * dashboards ship a deliberately strict Content Security Policy
 * (`script-src 'self'`, no `'unsafe-eval'`), so the browser refuses, and the
 * renderer reports "validation failed unexpectedly" for a spec that is
 * perfectly valid. It surfaced the moment real data reached the renderer for
 * the first time; nothing before that had ever exercised this path in a
 * browser with the CSP applied.
 *
 * The fix is NOT to allow 'unsafe-eval'. Weakening the CSP of a security demo
 * to satisfy a validation library would be trading the thing being
 * demonstrated for the thing demonstrating it. Ajv supports standalone code
 * generation for exactly this case: the schema is compiled HERE, at build
 * time, into ordinary JavaScript that runs under the strict policy unchanged.
 */
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import standaloneCode from "ajv/dist/standalone/index.js";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const schema = JSON.parse(
  await import("node:fs/promises").then((fs) =>
    fs.readFile(resolve(root, "spec.schema.json"), "utf-8"),
  ),
);

// `code.source` is what makes the output standalone. The options must match
// src/validate.ts's runtime Ajv options exactly, or the precompiled validator
// accepts a different language than the one the tests exercise.
const ajv = new Ajv2020({
  allErrors: true,
  discriminator: true,
  strict: false,
  code: { source: true, esm: true },
});

const validate = ajv.compile(schema);
const source = standaloneCode(ajv, validate);

const out = resolve(root, "src", "validate.generated.js");
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, source, "utf-8");
console.log(`spec-renderer: precompiled validator -> src/validate.generated.js (${source.length} bytes)`);
