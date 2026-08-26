// Run with `node --test tests/` from apps/directline-token.
//
// Covers F3: the origin guard in src/functions/directline-token.mjs used to
// fail open two independent ways -- a request with no Origin header skipped
// the check entirely, and an unset DIRECTLINE_ALLOWED_ORIGINS skipped it *and*
// dropped the minted token's own origin binding. Both must now fail closed.

import assert from "node:assert/strict";
import { after, afterEach, before, beforeEach, describe, it } from "node:test";
import { directLineToken as handler } from "../src/functions/directline-token.mjs";

const ORIGINAL_ALLOWED_ORIGINS = process.env.DIRECTLINE_ALLOWED_ORIGINS;
const ORIGINAL_SECRET = process.env.DIRECTLINE_SECRET;
const ORIGINAL_FETCH = globalThis.fetch;

function makeRequest({ method = "POST", headers = {} } = {}) {
  const byLowerName = new Map(
    Object.entries(headers).map(([name, value]) => [name.toLowerCase(), value]),
  );
  return {
    method,
    headers: { get: (name) => byLowerName.get(name.toLowerCase()) ?? null },
  };
}

function makeContext() {
  return {
    warnings: [],
    errors: [],
    warn(message) {
      this.warnings.push(message);
    },
    error(message) {
      this.errors.push(message);
    },
  };
}

function stubSuccessfulFetch() {
  globalThis.fetch = async () => ({
    ok: true,
    status: 200,
    json: async () => ({ token: "t", expires_in: 1800, conversationId: "conv-1" }),
  });
}

describe("directLineToken origin guard", () => {
  let ctx;

  before(() => {
    // A secret must be present for any test that can reach the token
    // exchange; none of these tests care about its value.
    process.env.DIRECTLINE_SECRET = "test-secret";
  });

  beforeEach(() => {
    ctx = makeContext();
    // Default to a configured allow-list so each test opts into the
    // unconfigured case explicitly rather than depending on run order.
    process.env.DIRECTLINE_ALLOWED_ORIGINS = "https://ct.example";
  });

  afterEach(() => {
    globalThis.fetch = ORIGINAL_FETCH;
  });

  after(() => {
    if (ORIGINAL_ALLOWED_ORIGINS === undefined) {
      delete process.env.DIRECTLINE_ALLOWED_ORIGINS;
    } else {
      process.env.DIRECTLINE_ALLOWED_ORIGINS = ORIGINAL_ALLOWED_ORIGINS;
    }
    if (ORIGINAL_SECRET === undefined) {
      delete process.env.DIRECTLINE_SECRET;
    } else {
      process.env.DIRECTLINE_SECRET = ORIGINAL_SECRET;
    }
  });

  it("refuses a request with no Origin header", async () => {
    const res = await handler(makeRequest({ headers: {} }), ctx);
    assert.equal(res.status, 403);
  });

  it("refuses to mint when no allow-list is configured", async () => {
    delete process.env.DIRECTLINE_ALLOWED_ORIGINS;
    const res = await handler(
      makeRequest({ headers: { origin: "https://anything" } }),
      ctx,
    );
    assert.equal(res.status, 500);
    assert.match(res.jsonBody.error, /not configured/i);
  });

  it("still mints for a configured origin", async () => {
    process.env.DIRECTLINE_ALLOWED_ORIGINS = "https://ct.example";
    stubSuccessfulFetch();
    const res = await handler(
      makeRequest({ headers: { origin: "https://ct.example" } }),
      ctx,
    );
    assert.equal(res.status, 200);
  });

  it("still refuses a non-allow-listed origin when the allow-list is configured", async () => {
    const res = await handler(
      makeRequest({ headers: { origin: "https://evil.example" } }),
      ctx,
    );
    assert.equal(res.status, 403);
  });
});
