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

// Seven, not six. MLS_AWS_CLIENT_ID joined the required set at Task 9 and is as
// load-bearing as the role ARN: the container carries two user-assigned managed
// identities and the AWS trust policy's `sub` is pinned to one of them, so a
// token minted from the other is refused by STS with a message that blames the
// trust policy. Required — not optional-with-a-fallback — so that a missing one
// is a boot error naming the variable rather than an AccessDenied in AWS.
// The id itself is the allowlisted synthetic placeholder; no live identity is
// involved and none could be, since nothing here acquires a token.
const awsVars = {
  MLS_AWS_ROLE_ARN: "arn:aws:iam::1:role/r",
  MLS_AWS_AUDIENCE: "api://a",
  MLS_AWS_REGION: "us-east-1",
  MLS_GLUE_DATABASE: "launch",
  MLS_ATHENA_WORKGROUP: "wg",
  MLS_ATHENA_OUTPUT: "s3://r/",
  MLS_AWS_CLIENT_ID: "11111111-1111-1111-1111-111111111111",
};

const full = { ...open, ...awsVars };

describe("aws config", () => {
  it("is present when all seven are set", () => {
    const config = loadConfig(full as never);
    expect(config.aws?.roleArn).toBe("arn:aws:iam::1:role/r");
    expect(config.aws).toEqual({
      roleArn: "arn:aws:iam::1:role/r",
      audience: "api://a",
      region: "us-east-1",
      database: "launch",
      workgroup: "wg",
      outputLocation: "s3://r/",
      clientId: "11111111-1111-1111-1111-111111111111",
    });
  });

  // The one that would otherwise be silent. Six of seven set is exactly what a
  // template that threaded the demo variables but forgot to derive the identity
  // would produce, and it must not resolve to "configured".
  it("treats the six demo variables WITHOUT the derived client id as fatal, naming it", () => {
    const { MLS_AWS_CLIENT_ID: _omitted, ...sixOnly } = awsVars;
    expect(() => loadConfig({ ...open, ...sixOnly } as never)).toThrow(/MLS_AWS_CLIENT_ID/);
  });

  it("is absent when none are set", () => {
    expect(loadConfig(open as never).aws).toBeUndefined();
  });

  it.each(Object.keys(awsVars))("treats an EMPTY %s as unconfigured, not as configured", (k) => {
    expect(() => loadConfig({ ...full, [k]: "" } as never)).toThrow(
      new RegExp(`- ${k}:`),
    );
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
