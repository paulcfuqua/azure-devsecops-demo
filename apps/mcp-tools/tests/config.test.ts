/**
 * `loadConfig`'s AWS lakehouse settings (Task 6).
 *
 * The lesson is F125's: an absent GitHub variable is the empty string, not an
 * error, so a config that treats "" as configured produces a backend that
 * fails at first query instead of at startup. Partial configuration must
 * throw naming every missing variable, never silently disable the tool.
 */
import { describe, it, expect } from "vitest";
import { loadConfig } from "../src/config.js";

// Every case below also exercises the inbound-auth gate (F2: enforced in
// EVERY backend mode, not just cloud), which is orthogonal to what this file
// tests. MCP_ALLOW_UNAUTHENTICATED opts out of it so these assertions are
// about AWS config resolution, not auth.
const open = { MCP_ALLOW_UNAUTHENTICATED: "true" };

const awsVars = {
  MLS_AWS_ROLE_ARN: "arn:aws:iam::1:role/r",
  MLS_AWS_AUDIENCE: "api://a",
  MLS_AWS_REGION: "us-east-1",
  MLS_GLUE_DATABASE: "launch",
  MLS_ATHENA_WORKGROUP: "wg",
  MLS_ATHENA_OUTPUT: "s3://r/",
};

const full = { ...open, ...awsVars };

describe("aws config", () => {
  it("is present when all six are set", () => {
    const config = loadConfig(full as never);
    expect(config.aws?.roleArn).toBe("arn:aws:iam::1:role/r");
    expect(config.aws).toEqual({
      roleArn: "arn:aws:iam::1:role/r",
      audience: "api://a",
      region: "us-east-1",
      database: "launch",
      workgroup: "wg",
      outputLocation: "s3://r/",
    });
  });

  it("is absent when none are set", () => {
    expect(loadConfig(open as never).aws).toBeUndefined();
  });

  it.each(Object.keys(awsVars))("treats an EMPTY %s as unconfigured, not as configured", (k) => {
    expect(() => loadConfig({ ...full, [k]: "" } as never)).toThrow(/MLS_AWS|MLS_GLUE|MLS_ATHENA/);
  });

  it("names exactly the missing variables and none of the present ones", () => {
    expect(() =>
      loadConfig({ ...full, MLS_AWS_REGION: "", MLS_ATHENA_WORKGROUP: "" } as never),
    ).toThrow(/MLS_AWS_REGION[\s\S]*MLS_ATHENA_WORKGROUP|MLS_ATHENA_WORKGROUP[\s\S]*MLS_AWS_REGION/);
  });

  it("is resolved independently of MLS_TOOL_BACKENDS (present in local mode too)", () => {
    expect(loadConfig({ ...full, MLS_TOOL_BACKENDS: "local" } as never).aws).toBeDefined();
  });

  it("does not require AWS configuration for local or cloud mode to work", () => {
    expect(() => loadConfig(open as never)).not.toThrow();
    expect(loadConfig(open as never).backendMode).toBe("local");
  });
});
