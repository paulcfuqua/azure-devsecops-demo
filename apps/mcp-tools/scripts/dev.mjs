#!/usr/bin/env node
/**
 * `npm run dev` launcher.
 *
 * Why this file exists instead of a one-line `"dev": "MCP_ALLOW_UNAUTHENTICATED=true
 * tsx src/index.ts"` in package.json: that POSIX `VAR=value command` prefix is a
 * shell feature, not an npm feature, and npm's default script-shell on Windows
 * is cmd.exe regardless of the developer's interactive shell — CLAUDE.md
 * targets PowerShell 7 for local orchestration, and cmd.exe does not
 * understand that syntax at all (it fails with "'...' is not recognized as an
 * internal or external command"). Setting the variable from Node itself, here,
 * behaves identically under cmd.exe, PowerShell and bash, and needs no new
 * dependency (e.g. cross-env) in either lockfile.
 *
 * MCP_ALLOW_UNAUTHENTICATED opts the local dev server out of the inbound-auth
 * gate (see ../src/auth-gate.ts) so a laptop boot needs no MCP_AUTH_TOKEN.
 * Only this dev path sets it — the deployed container never does, and fails
 * closed at boot without a token (F2). `??=` only fills in the default when
 * the variable is not already set, so a developer who wants to exercise the
 * enforced gate locally can still override it, e.g.
 * `MCP_ALLOW_UNAUTHENTICATED=false MCP_AUTH_TOKEN=... npm run dev` (bash) or
 * `$env:MCP_ALLOW_UNAUTHENTICATED='false'; $env:MCP_AUTH_TOKEN='...'; npm run dev` (pwsh).
 */
process.env.MCP_ALLOW_UNAUTHENTICATED ??= "true";

const { register } = await import("tsx/esm/api");
register();
await import("../src/index.ts");
