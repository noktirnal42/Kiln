// Cloudflare Worker + Durable Object host for the relay: one object per room, no storage but the room password.
import { sendPush } from "./apns.mjs";
import { Room, constantTimeEqual } from "./room.mjs";

export class RelayRoom {
  constructor(state, env) {
    this.state = state;
    this.env = env;
    this.room = null;
    this.pushTimes = [];
  }

  /** POST /v1/push/<room>: the Mac asks for an approval alert to be pushed to the phones it names. */
  async push(request) {
    const room = await this.load();
    const token = (request.headers.get("Authorization") ?? "").replace(/^Bearer /, "");
    if (room.authToken === null || !constantTimeEqual(token, room.authToken)) return Response.json({ error: "unauthorized" }, { status: 401 });
    const now = Date.now();
    this.pushTimes = this.pushTimes.filter((t) => now - t < 60_000);
    if (this.pushTimes.length >= 20) return Response.json({ error: "too many pushes" }, { status: 429 });
    this.pushTimes.push(now);
    let body;
    try { body = await request.json(); } catch { return Response.json({ error: "bad json" }, { status: 400 }); }
    const devices = Array.isArray(body.devices) ? body.devices : [];
    const alert = { title: String(body.title ?? "Kiln needs approval").slice(0, 80), body: String(body.body ?? "").slice(0, 160), approvalID: String(body.approvalID ?? "").slice(0, 64), category: "KILN_APPROVAL" };
    const outcome = await sendPush({ env: this.env, devices, alert });
    if (!outcome.configured) return Response.json({ error: "push not configured on this relay" }, { status: 501 });
    return Response.json({ results: outcome.results });
  }

  async load() {
    if (this.room) return this.room;
    const token = (await this.state.storage.get("auth")) ?? null;
    this.room = new Room(token);
    this.room.onNewToken = (value) => this.state.storage.put("auth", value);
    return this.room;
  }

  async fetch(request) {
    if (request.method === "POST" && new URL(request.url).pathname.startsWith("/v1/push/")) return this.push(request);
    if (request.headers.get("Upgrade") !== "websocket") return new Response("WebSocket only", { status: 426 });
    const url = new URL(request.url);
    const role = url.searchParams.get("role");
    const token = (request.headers.get("Authorization") ?? "").replace(/^Bearer /, "");
    const room = await this.load();
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    server.accept();
    server.binaryType = "arraybuffer";
    const socket = { send: (data) => server.send(data), close: (code, reason) => { try { server.close(code, reason); } catch {} } };
    const refusal = room.join(role, token, socket);
    if (refusal) {
      socket.close(refusal.code, refusal.reason);
      return new Response(null, { status: 101, webSocket: client });
    }
    server.addEventListener("message", (event) => {
      if (typeof event.data === "string") return;
      room.message(socket, new Uint8Array(event.data));
    });
    const gone = () => room.leave(socket);
    // Answer the client's close so its side finishes promptly instead of waiting out a timeout.
    server.addEventListener("close", (event) => {
      gone();
      const code = event.code && ![1005, 1006, 1015].includes(event.code) ? event.code : 1000;
      try { server.close(code, event.reason); } catch {}
    });
    server.addEventListener("error", gone);
    return new Response(null, { status: 101, webSocket: client });
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/v1\/(?:room|push)\/([A-Za-z0-9_-]{16,64})$/);
    if (url.pathname === "/" || url.pathname === "/health") return new Response("kiln-relay ok\n");
    if (!match) return new Response("not found", { status: 404 });
    const id = env.ROOMS.idFromName(match[1]);
    return env.ROOMS.get(id).fetch(request);
  },
};
