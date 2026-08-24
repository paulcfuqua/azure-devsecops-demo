/**
 * Spec validation gate — the L8 safety boundary.
 *
 * The copilot returns a JSON component spec, NEVER generated UI code. Before
 * any spec leaves this service it is validated against the renderer contract:
 * `@mls/spec-renderer/spec.schema.json` (the package's exported schema file).
 *
 * Why the schema export and not the package's own `validateSpec` function:
 * the built `@mls/spec-renderer` bundle imports React + Fluent UI at module
 * scope, which does not load in a plain Node server process. The package
 * exports the schema file precisely for this consumer (see its README:
 * "`@mls/spec-renderer/spec.schema.json` resolves to the schema file itself").
 * This module mirrors the semantics of the library's `validateSpec`
 * (src/validate.ts) exactly — same Ajv 2020 options, same error shape — and
 * the type contract (`SpecValidationResult`) is imported from the package so
 * drift breaks the build.
 */
import { createRequire } from "node:module";
import type { ErrorObject, Options, ValidateFunction } from "ajv";
import type { Ajv2020 as Ajv2020Instance } from "ajv/dist/2020.js";
import type { SpecValidationError, SpecValidationResult } from "@mls/spec-renderer";

const require = createRequire(import.meta.url);

// ajv's 2020 entry is CJS with `module.exports = Ajv2020` (the class itself,
// not a namespace) — require it so it is constructable under NodeNext.
const Ajv2020 = require("ajv/dist/2020.js") as new (opts?: Options) => Ajv2020Instance;

/** The renderer contract schema (draft 2020-12), straight from the package. */
export const specSchema: Record<string, unknown> = require(
  "@mls/spec-renderer/spec.schema.json",
) as Record<string, unknown>;

let compiled: ValidateFunction | undefined;

function getValidator(): ValidateFunction {
  if (!compiled) {
    const ajv = new Ajv2020({
      allErrors: true,
      discriminator: true,
      strict: false,
    });
    compiled = ajv.compile(specSchema);
  }
  return compiled;
}

function toError(e: ErrorObject): SpecValidationError {
  let message = e.message ?? "invalid";
  if (e.keyword === "enum" && Array.isArray(e.params?.allowedValues)) {
    message += `: ${(e.params.allowedValues as unknown[]).map((v) => JSON.stringify(v)).join(", ")}`;
  }
  if (e.keyword === "additionalProperties" && typeof e.params?.additionalProperty === "string") {
    message += `: '${e.params.additionalProperty}'`;
  }
  return { path: e.instancePath || "/", message, keyword: e.keyword };
}

/**
 * Validate an arbitrary JSON value against the component-spec schema.
 * Never throws; returns { ok, errors } with JSON-Pointer error paths.
 * Mirrors @mls/spec-renderer's validateSpec.
 */
export function validateSpec(json: unknown): SpecValidationResult {
  try {
    const validate = getValidator();
    const ok = validate(json) as boolean;
    if (ok) {
      return { ok: true, errors: [] };
    }
    const seen = new Set<string>();
    const errors: SpecValidationError[] = [];
    for (const e of validate.errors ?? []) {
      const item = toError(e);
      const key = `${item.path}|${item.keyword}|${item.message}`;
      if (!seen.has(key)) {
        seen.add(key);
        errors.push(item);
      }
    }
    if (errors.length === 0) {
      errors.push({ path: "/", message: "spec failed validation", keyword: "unknown" });
    }
    return { ok: false, errors };
  } catch (err) {
    return {
      ok: false,
      errors: [
        {
          path: "/",
          message: `validation failed unexpectedly: ${err instanceof Error ? err.message : String(err)}`,
          keyword: "exception",
        },
      ],
    };
  }
}

/**
 * Extract a candidate spec JSON from the model's final text. Accepts either
 * bare JSON or a ```json fenced block. Returns a discriminated result — never
 * throws.
 */
export function tryParseSpecJson(
  text: string,
): { ok: true; value: unknown } | { ok: false; error: string } {
  let candidate = text.trim();
  const fence = candidate.match(/```(?:json)?\s*\n?([\s\S]*?)```/);
  if (fence?.[1]) {
    candidate = fence[1].trim();
  }
  if (candidate.length === 0) {
    return { ok: false, error: "empty response" };
  }
  try {
    return { ok: true, value: JSON.parse(candidate) };
  } catch (err) {
    return {
      ok: false,
      error: `response was not parseable JSON: ${err instanceof Error ? err.message : String(err)}`,
    };
  }
}
