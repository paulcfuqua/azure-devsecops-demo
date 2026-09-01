// @ts-expect-error - generated at build time by scripts/build-validator.mjs
import generatedValidate from "./validate.generated.js";
import type { ErrorObject, ValidateFunction } from "ajv";
import rawSchema from "../spec.schema.json";
import type { Spec } from "./types";

export interface SpecValidationError {
  /** JSON Pointer to the failing location in the document, e.g. "/components/0/data/1". */
  path: string;
  /** Human-readable message, e.g. "must have required property 'title'". */
  message: string;
  /** Ajv keyword that failed, e.g. "required", "enum", "type". */
  keyword: string;
}

export interface SpecValidationResult {
  ok: boolean;
  errors: SpecValidationError[];
}

/** The compiled JSON Schema (draft 2020-12) — also shipped as spec.schema.json. */
export const specSchema: Record<string, unknown> = rawSchema as Record<string, unknown>;

// PRECOMPILED, NOT COMPILED AT RUNTIME (F111).
//
// ajv.compile() generates JavaScript source and evaluates it - `new Function`
// underneath. The dashboards ship a strict Content Security Policy
// (`script-src 'self'`, no 'unsafe-eval'), so the browser refuses and every
// spec is reported as "validation failed unexpectedly" no matter how valid it
// is. That surfaced the first time real data reached the renderer in a browser
// with the CSP applied; no test had ever exercised both at once.
//
// scripts/build-validator.mjs compiles the schema at BUILD time into
// validate.generated.js using Ajv's standalone mode, which emits ordinary
// JavaScript. Weakening the CSP was the other option and it is the wrong one:
// a security demo does not relax the control it is demonstrating to satisfy a
// validation library.
let compiled: ValidateFunction | undefined;

function getValidator(): ValidateFunction {
  if (!compiled) {
    compiled = generatedValidate as unknown as ValidateFunction;
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

/** Type guard built on validateSpec for convenience in TypeScript consumers. */
export function isSpec(json: unknown): json is Spec {
  return validateSpec(json).ok;
}
