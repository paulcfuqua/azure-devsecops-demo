// Run with `node --test tests/` from apps/directline-token — no dependencies
// required, because the module under test has none. (@azure/functions is only
// needed by the binding shim in src/functions/, which is not imported here.)

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  DIRECT_LINE_DEFAULT_BASE,
  exchangeSecretForToken,
  mintUserId,
  TokenExchangeError,
} from "../src/tokenExchange.mjs";

const SECRET = "super-secret-direct-line-key";
const randomUUID = () => "11111111-2222-3333-4444-555555555555";

function stubFetch(payload, { ok = true, status = 200 } = {}) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url, init });
    return {
      ok,
      status,
      json: async () => payload,
    };
  };
  impl.calls = calls;
  return impl;
}

describe("exchangeSecretForToken", () => {
  it("posts the secret as a bearer token to the documented generate endpoint", async () => {
    const fetchImpl = stubFetch({
      token: "a-short-lived-token",
      expires_in: 1800,
      conversationId: "conv-1",
    });

    await exchangeSecretForToken({ secret: SECRET, randomUUID, fetchImpl });

    assert.equal(fetchImpl.calls.length, 1);
    const [call] = fetchImpl.calls;
    assert.equal(
      call.url,
      `${DIRECT_LINE_DEFAULT_BASE}/v3/directline/tokens/generate`,
    );
    assert.equal(call.init.method, "POST");
    assert.equal(call.init.headers.authorization, `Bearer ${SECRET}`);
  });

  it("mints a dl_-prefixed user id and embeds it in the request", async () => {
    const fetchImpl = stubFetch({ token: "t" });
    const result = await exchangeSecretForToken({ secret: SECRET, randomUUID, fetchImpl });

    assert.match(result.userId, /^dl_[0-9a-f]{32}$/);
    const body = JSON.parse(fetchImpl.calls[0].init.body);
    assert.equal(body.user.id, result.userId);
  });

  it("passes trustedOrigins through when configured, and omits it when not", async () => {
    const withOrigins = stubFetch({ token: "t" });
    await exchangeSecretForToken({
      secret: SECRET,
      randomUUID,
      fetchImpl: withOrigins,
      trustedOrigins: ["https://control-tower.example"],
    });
    assert.deepEqual(JSON.parse(withOrigins.calls[0].init.body).trustedOrigins, [
      "https://control-tower.example",
    ]);

    const without = stubFetch({ token: "t" });
    await exchangeSecretForToken({ secret: SECRET, randomUUID, fetchImpl: without });
    assert.equal("trustedOrigins" in JSON.parse(without.calls[0].init.body), false);
  });

  it("returns only token, expires_in, conversationId and userId", async () => {
    const fetchImpl = stubFetch({
      token: "t",
      expires_in: 1800,
      conversationId: "conv-1",
      // A hostile or changed upstream must not be able to widen this response.
      secret: SECRET,
      streamUrl: "wss://example",
    });
    const result = await exchangeSecretForToken({ secret: SECRET, randomUUID, fetchImpl });

    assert.deepEqual(Object.keys(result).sort(), [
      "conversationId",
      "expires_in",
      "token",
      "userId",
    ]);
    assert.equal(JSON.stringify(result).includes(SECRET), false);
  });

  it("fails with 500 when no secret is configured", async () => {
    await assert.rejects(
      () => exchangeSecretForToken({ secret: "", randomUUID, fetchImpl: stubFetch({}) }),
      (error) => error instanceof TokenExchangeError && error.status === 500,
    );
  });

  it("reports an upstream refusal as 502 without echoing upstream detail", async () => {
    const fetchImpl = stubFetch({ error: SECRET }, { ok: false, status: 401 });
    await assert.rejects(
      () => exchangeSecretForToken({ secret: SECRET, randomUUID, fetchImpl }),
      (error) => {
        assert.equal(error.status, 502);
        assert.equal(error.message.includes(SECRET), false);
        return true;
      },
    );
  });

  it("honours a regional Direct Line host", async () => {
    const fetchImpl = stubFetch({ token: "t" });
    await exchangeSecretForToken({
      secret: SECRET,
      randomUUID,
      fetchImpl,
      baseUrl: "https://europe.directline.botframework.com/",
    });
    assert.equal(
      fetchImpl.calls[0].url,
      "https://europe.directline.botframework.com/v3/directline/tokens/generate",
    );
  });
});

describe("mintUserId", () => {
  it("always produces the dl_ prefix Direct Line requires", () => {
    assert.match(mintUserId(randomUUID), /^dl_/);
  });
});
