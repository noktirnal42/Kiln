import assert from "node:assert/strict";
import { test } from "node:test";
import WebSocket from "ws";
import { startRelay } from "../src/node-server.mjs";
import { CLOSE_DEVICE, DATA, DEVICE_JOINED, DEVICE_LEFT, frame } from "../src/room.mjs";

const ROOM = "AAAAAAAAAAAAAAAAAAAAAA";
const TOKEN = "T".repeat(43);

function connect(port, role, token = TOKEN, room = ROOM) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/v1/room/${room}?role=${role}`, { headers: { Authorization: `Bearer ${token}` } });
  const inbox = [], waiters = [];
  let closed = null;
  ws.on("message", (data) => { const bytes = new Uint8Array(data); const w = waiters.shift(); w ? w(bytes) : inbox.push(bytes); });
  ws.on("close", (code, reason) => { closed = { code, reason: reason.toString() }; waiters.splice(0).forEach((w) => w(null)); });
  return {
    ws,
    opened: new Promise((resolve, reject) => { ws.on("open", resolve); ws.on("error", reject); }),
    next: () => new Promise((resolve) => { const m = inbox.shift(); m ? resolve(m) : waiters.push(resolve); }),
    closedWith: () => new Promise((resolve) => { closed ? resolve(closed) : ws.on("close", (code, reason) => resolve({ code, reason: reason.toString() })); }),
  };
}

test("a device's bytes reach the Mac tagged with its id, and replies go back to only that device", async () => {
  const relay = await startRelay();
  try {
    const mac = connect(relay.port, "mac"); await mac.opened;
    const a = connect(relay.port, "device"); await a.opened;
    const b = connect(relay.port, "device"); await b.opened;
    const joinedA = await mac.next(), joinedB = await mac.next();
    assert.equal(joinedA[0], DEVICE_JOINED); assert.equal(joinedB[0], DEVICE_JOINED);
    const idA = new DataView(joinedA.buffer, joinedA.byteOffset).getUint32(1), idB = new DataView(joinedB.buffer, joinedB.byteOffset).getUint32(1);
    assert.notEqual(idA, idB);
    a.ws.send(new Uint8Array([1, 2, 3]));
    const got = await mac.next();
    assert.deepEqual([...got], [DATA, ...frame(DATA, idA).subarray(1, 5), 1, 2, 3]);
    mac.ws.send(frame(DATA, idB, new Uint8Array([9, 9])));
    assert.deepEqual([...(await b.next())], [9, 9]);
    a.ws.close();
    assert.equal((await mac.next())[0], DEVICE_LEFT);
    mac.ws.send(frame(CLOSE_DEVICE, idB));
    assert.equal((await b.closedWith()).code, 1000);
  } finally { relay.close(); }
});

test("the first Mac sets the room password; others need it", async () => {
  const relay = await startRelay();
  try {
    const mac = connect(relay.port, "mac"); await mac.opened;
    const intruder = connect(relay.port, "device", "X".repeat(43));
    await intruder.opened.catch(() => {});
    assert.equal((await intruder.closedWith()).code, 4401);
    const hijack = connect(relay.port, "mac", "Y".repeat(43));
    await hijack.opened.catch(() => {});
    assert.equal((await hijack.closedWith()).code, 4401);
  } finally { relay.close(); }
});

test("a device with no Mac online, or in an unknown room, is told so", async () => {
  const relay = await startRelay();
  try {
    const stranger = connect(relay.port, "device", TOKEN, "BBBBBBBBBBBBBBBBBBBBBB"); await stranger.opened.catch(() => {});
    assert.equal((await stranger.closedWith()).code, 4404);
    const mac = connect(relay.port, "mac"); await mac.opened; mac.ws.close();
    await new Promise((r) => setTimeout(r, 100));
    const device = connect(relay.port, "device"); await device.opened.catch(() => {});
    assert.equal((await device.closedWith()).code, 4503);
  } finally { relay.close(); }
});

test("when the Mac drops, its devices are closed so they reconnect; a newer Mac replaces an older one", async () => {
  const relay = await startRelay();
  try {
    const mac = connect(relay.port, "mac"); await mac.opened;
    const device = connect(relay.port, "device"); await device.opened; await mac.next();
    const newer = connect(relay.port, "mac"); await newer.opened;
    assert.equal((await mac.closedWith()).code, 4409);
    assert.equal((await device.closedWith()).code, 4503);
  } finally { relay.close(); }
});
