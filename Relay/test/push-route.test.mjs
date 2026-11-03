import assert from "node:assert/strict";
import { test } from "node:test";
import { RelayRoom } from "../src/worker.mjs";

const TOKEN = "T".repeat(43);
async function pem() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  return `-----BEGIN PRIVATE KEY-----\n${Buffer.from(der).toString("base64")}\n-----END PRIVATE KEY-----`;
}
async function makeRoom(env) {
  const store = new Map();
  const room = new RelayRoom({ storage: { get: async (k) => store.get(k), put: async (k, v) => store.set(k, v) } }, env);
  const loaded = await room.load();
  loaded.join("mac", TOKEN, { send() {}, close() {} });   // the Mac claims the room and sets its password
  return room;
}
const post = (body, token = TOKEN) => new Request("https://relay.test/v1/push/ROOM", { method: "POST", headers: { Authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify(body) });
const device = { token: "ab".repeat(32), environment: "sandbox", topic: "com.kiln.remote" };

test("only the room's Mac may push, and an unconfigured relay says so", async () => {
  const room = await makeRoom({});
  assert.equal((await room.push(post({ devices: [device] }, "X".repeat(43)))).status, 401);
  const response = await room.push(post({ devices: [device] }));
  assert.equal(response.status, 501);
});

test("a configured relay pushes a short generic alert and reports each device", async () => {
  const room = await makeRoom({ APNS_KEY: await pem(), APNS_KEY_ID: "KEYID", APNS_TEAM_ID: "TEAMID" });
  const seen = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => { seen.push({ url, body: JSON.parse(init.body), topic: init.headers["apns-topic"] }); return new Response("", { status: 200 }); };
  try {
    const response = await room.push(post({ devices: [device], title: "Kiln needs approval", body: "run_command (execute)", approvalID: "A-7" }));
    assert.equal(response.status, 200);
    assert.deepEqual((await response.json()).results, [{ token: device.token, ok: true }]);
    assert.equal(seen.length, 1);
    assert.equal(seen[0].topic, "com.kiln.remote");
    assert.equal(seen[0].body.approvalID, "A-7");
    assert.equal(seen[0].body.aps.alert.body, "run_command (execute)");
  } finally { globalThis.fetch = realFetch; }
});

test("pushes are rate limited per room", async () => {
  const room = await makeRoom({});
  let last;
  for (let i = 0; i < 21; i++) last = await room.push(post({ devices: [] }));
  assert.equal(last.status, 429);
});
