// End-to-end probe: acts as a paired device (phone or watch) through the relay, speaking the real encrypted protocol.
//   node tools/probe.mjs [--relay wss://host] [--hold seconds] [--send "text"]
// Reads the pairing key from Kiln's own file on this Mac; the key is never printed. Use it to check that the relay, the Mac and
// the encrypted channel work together, and how long a link stays up.
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import { WebSocket } from "ws";

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith("--") ? [...acc, [a.slice(2), all[i + 1]?.startsWith("--") ? true : all[i + 1] ?? true]] : acc), []));
const pairing = JSON.parse(fs.readFileSync(`${os.homedir()}/Library/Application Support/Kiln/remote-pairing.json`, "utf8"));
const key = Buffer.from(pairing.key, "base64");
const relay = (args.relay ?? process.env.KILN_RELAY ?? "wss://kiln-relay.swiftmentor.workers.dev").replace(/\/$/, "");
const hold = Number(args.hold ?? 0);
const b64url = (b) => Buffer.from(b).toString("base64url");
const hmac = (label) => crypto.createHmac("sha256", key).update(label).digest();
const room = b64url(hmac("kiln-relay room v1").subarray(0, 16));
const token = b64url(hmac("kiln-relay auth v1"));

const log = (...a) => console.log(new Date().toISOString().slice(11, 23), ...a);
const clientNonce = crypto.randomBytes(16);
let send, recv, sendN = 0n, recvN = 0n, serverNonce = null;

function derive(label) {
  return Buffer.from(crypto.hkdfSync("sha256", key, Buffer.concat([clientNonce, serverNonce]), label, 32));
}
function seal(plain) {
  const header = Buffer.alloc(8); header.writeBigUInt64LE(sendN);
  const nonce = Buffer.concat([Buffer.alloc(4), header]);
  const c = crypto.createCipheriv("chacha20-poly1305", send, nonce, { authTagLength: 16 });
  c.setAAD(header);
  const ct = Buffer.concat([c.update(plain), c.final()]);
  sendN++;
  return Buffer.concat([header, ct, c.getAuthTag()]);
}
function open(frame) {
  const header = frame.subarray(0, 8);
  if (header.readBigUInt64LE() !== recvN) throw new Error("out of order frame");
  const body = frame.subarray(8);
  const d = crypto.createDecipheriv("chacha20-poly1305", recv, Buffer.concat([Buffer.alloc(4), header]), { authTagLength: 16 });
  d.setAAD(header); d.setAuthTag(body.subarray(body.length - 16));
  const out = Buffer.concat([d.update(body.subarray(0, body.length - 16)), d.final()]);
  recvN++;
  return out;
}

const ws = new WebSocket(`${relay}/v1/room/${room}?role=device`, { headers: { Authorization: `Bearer ${token}` }, handshakeTimeout: 15000 });
const started = Date.now();
let events = 0;
ws.on("open", () => { log("relay: open"); ws.send(clientNonce); });
ws.on("close", (code, reason) => { log(`relay: closed ${code} ${reason} after ${((Date.now() - started) / 1000).toFixed(1)}s, ${events} events`); process.exit(code === 1000 ? 0 : 2); });
ws.on("error", (e) => { log("relay: error", e.message); process.exit(3); });
ws.on("message", (data, isBinary) => {
  if (!isBinary) return;
  const buf = Buffer.from(data);
  if (!serverNonce) {
    serverNonce = buf;
    send = derive("kiln-remote device->mac"); recv = derive("kiln-remote mac->device");
    log("handshake: server nonce received, sending hello");
    ws.send(seal(Buffer.from(JSON.stringify({ hello: { deviceName: "probe", protocolVersion: 1 } }))));
    return;
  }
  let event;
  try { event = JSON.parse(open(buf).toString()); } catch (e) { log("DECRYPT/DECODE FAILED:", e.message); return; }
  events++;
  const type = Object.keys(event)[0];
  const body = event[type];
  const summary = type === "delta" ? JSON.stringify(body).slice(0, 60) : type === "conversations" ? `${(body._0 ?? body).length} conversations` : type === "message" ? `${(body._0 ?? body).role}: ${((body._0 ?? body).text ?? "").slice(0, 60)}` : JSON.stringify(body)?.slice(0, 100);
  log("event:", type, summary ?? "");
  if (type === "welcome" && args.send) {
    log("sending message:", args.send);
    ws.send(seal(Buffer.from(JSON.stringify({ send: { text: args.send, spoken: false } }))));
  }
});
if (hold > 0) {
  setInterval(() => { try { ws.send(seal(Buffer.from(JSON.stringify({ ping: {} })))); log("ping sent"); } catch {} }, 30000);
  setTimeout(() => { log("hold finished; closing"); ws.close(1000); }, hold * 1000);
} else {
  setTimeout(() => { log("done"); ws.close(1000); }, 6000);
}
