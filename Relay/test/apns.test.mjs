import assert from "node:assert/strict";
import { test } from "node:test";
import { buildRequest, isHexToken, makeProviderToken, sendPush } from "../src/apns.mjs";

async function makeKey() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${Buffer.from(der).toString("base64").match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----`;
  return { pem, publicKey: pair.publicKey };
}

test("the provider token is a valid ES256 JWT with the key id and team", async () => {
  const { pem, publicKey } = await makeKey();
  const token = await makeProviderToken({ keyPem: pem, keyId: "ABC123DEFG", teamId: "LH8KLB9N4F", now: 1_700_000_000 });
  const [h, c, s] = token.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(h, "base64url")), { alg: "ES256", kid: "ABC123DEFG" });
  assert.deepEqual(JSON.parse(Buffer.from(c, "base64url")), { iss: "LH8KLB9N4F", iat: 1_700_000_000 });
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, Buffer.from(s, "base64url"), new TextEncoder().encode(`${h}.${c}`));
  assert.equal(ok, true);
});

test("requests go to the right Apple host with a generic alert and the approval id", () => {
  const alert = { title: "Kiln needs approval", body: "run_command (execute)", approvalID: "A-1" };
  const dev = { token: "ab".repeat(32), environment: "sandbox", topic: "com.kiln.remote" };
  const sandbox = buildRequest({ device: dev, providerToken: "JWT", alert });
  assert.equal(sandbox.url, `https://api.sandbox.push.apple.com/3/device/${dev.token}`);
  assert.equal(sandbox.init.headers["apns-topic"], "com.kiln.remote");
  assert.equal(sandbox.init.headers["apns-push-type"], "alert");
  const body = JSON.parse(sandbox.init.body);
  assert.equal(body.aps.category, "KILN_APPROVAL");
  assert.equal(body.approvalID, "A-1");
  assert.equal(buildRequest({ device: { ...dev, environment: "production" }, providerToken: "JWT", alert }).url.startsWith("https://api.push.apple.com/"), true);
});

test("an unconfigured relay says so, bad tokens are refused locally, and Apple's reasons come back per device", async () => {
  const alert = { title: "t", body: "b", approvalID: "A" };
  assert.deepEqual(await sendPush({ env: {}, devices: [], alert }), { configured: false, results: [] });
  const { pem } = await makeKey();
  const env = { APNS_KEY: pem, APNS_KEY_ID: "K", APNS_TEAM_ID: "T" };
  const good = "cd".repeat(32), dead = "ef".repeat(32);
  const calls = [];
  const fetchImpl = async (url) => { calls.push(url); return url.includes(dead) ? new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 }) : new Response("", { status: 200 }); };
  const { configured, results } = await sendPush({ env, alert, fetchImpl, devices: [
    { token: good, environment: "sandbox", topic: "com.kiln.remote" },
    { token: dead, environment: "sandbox", topic: "com.kiln.remote" },
    { token: "not hex!", environment: "sandbox", topic: "com.kiln.remote" },
  ] });
  assert.equal(configured, true);
  assert.deepEqual(results.map((r) => [r.ok, r.reason ?? ""]), [[true, ""], [false, "Unregistered"], [false, "BadDeviceToken"]]);
  assert.equal(calls.length, 2, "the malformed token never reaches Apple");
  assert.equal(isHexToken("ab".repeat(32)), true);
});
