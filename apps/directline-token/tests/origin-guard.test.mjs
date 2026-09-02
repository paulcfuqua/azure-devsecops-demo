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

  it("an allowed origin ALONE no longer mints - it reaches the user-token guard", async () => {
    // CHANGED DELIBERATELY, and the old assertion was the whole problem. This
    // used to assert 200: an allow-listed Origin was sufficient to mint a Direct
    // Line token. An `Origin` header is a string any direct caller can send, so
    // that made the endpoint an open faucet to everything except a browser on
    // another site - demonstrated with one `curl -H "Origin: <control tower>"`.
    //
    // A correct origin now gets a caller PAST the origin guard and no further:
    // the request is refused 401 by the user-token guard until it carries a
    // verified Entra token. That the status is 401 rather than 403 is the proof
    // the origin guard passed it through.
    process.env.DIRECTLINE_ALLOWED_ORIGINS = "https://ct.example";
    process.env.DIRECTLINE_USER_TENANT_ID = "11111111-2222-3333-4444-555555555555";
    process.env.DIRECTLINE_USER_AUDIENCE = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    stubSuccessfulFetch();
    const res = await handler(
      makeRequest({ headers: { origin: "https://ct.example" } }),
      ctx,
    );
    assert.equal(res.status, 401);
  });

  it("FAILS CLOSED with 500 when the user-token settings are missing", async () => {
    // Absent configuration must never degrade to the old anonymous behaviour.
    // 500, not 401: the deployment is wrong, not the caller - the same shape as
    // the allow-list guard above, which also refuses rather than minting unbound.
    process.env.DIRECTLINE_ALLOWED_ORIGINS = "https://ct.example";
    delete process.env.DIRECTLINE_USER_TENANT_ID;
    delete process.env.DIRECTLINE_USER_AUDIENCE;
    stubSuccessfulFetch();
    const res = await handler(
      makeRequest({ headers: { origin: "https://ct.example" } }),
      ctx,
    );
    assert.equal(res.status, 500);
  });

  it("advertises the Authorization header on the preflight, or the browser cannot send one", async () => {
    // The page forwards its Easy Auth token as `Authorization`. A CORS preflight
    // that does not list that header makes the browser drop it, and every request
    // would arrive unauthenticated - the control working perfectly and the app
    // never able to satisfy it.
    process.env.DIRECTLINE_ALLOWED_ORIGINS = "https://ct.example";
    const res = await handler(
      makeRequest({ method: "OPTIONS", headers: { origin: "https://ct.example" } }),
      ctx,
    );
    assert.equal(res.status, 204);
    assert.match(res.headers["access-control-allow-headers"], /authorization/i);
  });

  it("still refuses a non-allow-listed origin when the allow-list is configured", async () => {
    const res = await handler(
      makeRequest({ headers: { origin: "https://evil.example" } }),
      ctx,
    );
    assert.equal(res.status, 403);
  });
});
