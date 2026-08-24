/**
 * Spec validation gate — the L8 safety boundary.
 *
 * The copilot returns a JSON component spec, NEVER generated UI code. Before
 * any spec leaves this service it is validated against the renderer contract.
 *
 * Single source of truth: the validator itself is the renderer library's own
 * `validateSpec`, imported from `@mls/spec-renderer/validate` — the package's
 * UI-free subpath export (no React, no Fluent, nothing DOM in its import
 * graph, so it loads in a plain Node process). The service therefore runs the
 * exact same Ajv compilation of the exact same `spec.schema.json` the browser
 * renderer runs; there is no second implementation to drift.
 *
 * The only thing this module adds is `tryParseSpecJson`, which is a
 * transport concern (peeling a model's text response down to candidate JSON),
 * not a schema concern.
 */
export {
  isSpec,
  specSchema,
  validateSpec,
  type SpecValidationError,
  type SpecValidationResult,
} from "@mls/spec-renderer/validate";

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
