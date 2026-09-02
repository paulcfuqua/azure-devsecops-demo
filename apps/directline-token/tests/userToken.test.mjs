import { test } from "node:test";
import assert from "node:assert/strict";
import { SignJWT, generateKeyPair, exportJWK, createLocalJWKSet } from "jose";

import { verifyUserToken, UserTokenError } from "../src/userToken.mjs";

// A REAL KEY PAIR AND REAL SIGNATURES, not a stubbed verifier. The whole value of
// this module is that it rejects tokens it should reject, and a test that mocks
// jwtVerify would assert only that the mock was called - it would pass just as
// happily over a function that returned true unconditionally.
const TENANT = "11111111-2222-3333-4444-555555555555";
const AUDIENCE = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
const ISSUER = `https://login.microsoftonline.com/${TENANT}/v2.0`;

const { publicKey, privateKey } = await generateKeyPair("RS256");
const jwks = createLocalJWKSet({ keys: [{ ...(await exportJWK(publicKey)), alg: "RS256", kid: "test-key" }] });

// A second, UNRELATED key: a token signed with this is well-formed and correctly
// shaped, and must still be refused. This is the case an issuer/audience-only
// check silently passes.
const other = await generateKeyPair("RS256");

function token({ signer = privateKey, issuer = ISSUER, audience = AUDIENCE, expiresIn = "5m", notBefore } = {}) {
  let jwt = new SignJWT({ oid: "user-object-id" })
    .setProtectedHeader({ alg: "RS256", kid: "test-key" })
    .setIssuedAt()
    .setIssuer(issuer)
    .setAudience(audience)
    .setExpirationTime(expiresIn);
  if (notBefore) jwt = jwt.setNotBefore(notBefore);
  return jwt.sign(signer);
}

const base = { tenantId: TENANT, audience: AUDIENCE, jwks };

test("accepts a correctly signed token and returns its payload", async () => {
  const payload = await verifyUserToken({ ...base, authorization: `Bearer ${await token()}` });
  assert.equal(payload.oid, "user-object-id");
});

test("accepts the v1.0 issuer form as well as v2.0", async () => {
  // Entra uses both depending on the app's configured token version, and Easy
  // Auth decides which the app receives. Pinning one silently rejects every
  // token from an app configured for the other.
  const jwt = await token({ issuer: `https://sts.windows.net/${TENANT}/` });
  const payload = await verifyUserToken({ ...base, authorization: `Bearer ${jwt}` });
  assert.equal(payload.oid, "user-object-id");
});

test("refuses a token signed by a different key", async () => {
  const jwt = await token({ signer: other.privateKey });
  await assert.rejects(
    () => verifyUserToken({ ...base, authorization: `Bearer ${jwt}` }),
    (e) => e instanceof UserTokenError && e.status === 401,
  );
});

test("refuses a token minted for a different audience", async () => {
  // A signature from the right tenant proves only that SOME Entra app issued the
  // token. A token for a different application is not permission to use this one.
  const jwt = await token({ audience: "99999999-9999-9999-9999-999999999999" });
  await assert.rejects(
    () => verifyUserToken({ ...base, authorization: `Bearer ${jwt}` }),
    (e) => e instanceof UserTokenError && e.status === 401,
  );
});

test("refuses a token from a different tenant", async () => {
  const jwt = await token({ issuer: "https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0" });
  await assert.rejects(
    () => verifyUserToken({ ...base, authorization: `Bearer ${jwt}` }),
    (e) => e instanceof UserTokenError && e.status === 401,
  );
});

test("refuses an expired token", async () => {
  const jwt = await token({ expiresIn: "-10m" });
  await assert.rejects(
    () => verifyUserToken({ ...base, authorization: `Bearer ${jwt}` }),
    (e) => e instanceof UserTokenError && e.status === 401,
  );
});

test("refuses a token that is not yet valid", async () => {
  const jwt = await token({ notBefore: "10m" });
  await assert.rejects(
    () => verifyUserToken({ ...base, authorization: `Bearer ${jwt}` }),
    (e) => e instanceof UserTokenError && e.status === 401,
  );
});

test("refuses a missing Authorization header", async () => {
  await assert.rejects(
    () => verifyUserToken({ ...base, authorization: undefined }),
    (e) => e instanceof UserTokenError && e.status === 401,
  );
});

test("refuses an Authorization header that is not a Bearer token", async () => {
  await assert.rejects(
    () => verifyUserToken({ ...base, authorization: "Basic dXNlcjpwYXNz" }),
    (e) => e instanceof UserTokenError && e.status === 401,
  );
});

test("refuses garbage in place of a JWT", async () => {
  await assert.rejects(
    () => verifyUserToken({ ...base, authorization: "Bearer not.a.jwt" }),
    (e) => e instanceof UserTokenError && e.status === 401,
  );
});

test("FAILS CLOSED with 500 when the tenant is not configured", async () => {
  // Absent configuration must never degrade to anonymous. 500, not 401: this is
  // the deployment being wrong, not the caller.
  const jwt = await token();
  await assert.rejects(
    () => verifyUserToken({ audience: AUDIENCE, jwks, authorization: `Bearer ${jwt}` }),
    (e) => e instanceof UserTokenError && e.status === 500,
  );
});

test("FAILS CLOSED with 500 when the audience is not configured", async () => {
  // Without an expected audience the check would accept any token from the
  // tenant, including one minted for an entirely different application.
  const jwt = await token();
  await assert.rejects(
    () => verifyUserToken({ tenantId: TENANT, jwks, authorization: `Bearer ${jwt}` }),
    (e) => e instanceof UserTokenError && e.status === 500,
  );
});
