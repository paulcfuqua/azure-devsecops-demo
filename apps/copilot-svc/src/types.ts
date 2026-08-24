/**
 * Shared types for the copilot service.
 *
 * The service's output contract is the @mls/spec-renderer JSON component spec —
 * the model NEVER returns UI code; it returns a spec that is validated against
 * spec.schema.json before this service returns it to any client.
 */
import type { SpecValidationError } from "@mls/spec-renderer";

/** One entry in the tool-call trace returned with every answer (audit trail for V8.2). */
export interface ToolTraceEntry {
  /** Tool name the model asked for (may be a disallowed name — then rejected=true). */
  name: string;
  /** The input the model supplied for the call. */
  input: unknown;
  /** True when the call was refused because the name is not on the 5-tool allowlist. */
  rejected: boolean;
  /** True when the adapter ran and returned an error result (is_error tool_result). */
  isError: boolean;
  /** Wall-clock duration of the adapter execution in milliseconds (0 when rejected). */
  durationMs: number;
}

/** Successful /ask response body. */
export interface AskSuccess {
  /** Renderer JSON component spec — validated against spec.schema.json before return. */
  spec: unknown;
  /** Every SQL statement executed via query_lakehouse_sql during the loop, in order. */
  sql?: string[];
  toolTrace: ToolTraceEntry[];
}

/** Structured error returned when the model cannot produce a valid spec (after one repair round). */
export interface AskError {
  error: "invalid_spec" | "llm_error" | "bad_request";
  message: string;
  validationErrors?: SpecValidationError[];
  sql?: string[];
  toolTrace?: ToolTraceEntry[];
}

export type AskResult =
  | ({ ok: true } & AskSuccess)
  | ({ ok: false } & AskError);
