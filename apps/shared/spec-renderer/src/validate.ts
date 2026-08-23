import Ajv2020 from "ajv/dist/2020.js";
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
