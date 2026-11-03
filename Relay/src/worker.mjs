// Cloudflare Worker + Durable Object host for the relay: one object per room, no storage but the room password.
import { Room } from "./room.mjs";

export class RelayRoom {
  constructor(state) {
    this.state = state;
    this.room = null;
  }

  async load() {
    if (this.room) return this.room;
    const token = (await this.state.storage.get("auth")) ?? null;
    this.room = new Room(token);
    this.room.onNewToken = (value) => this.state.storage.put("auth", value);
    return this.room;
  }

  async fetch(request) {
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
    server.addEventListener("close", gone);
    server.addEventListener("error", gone);
    return new Response(null, { status: 101, webSocket: client });
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/v1\/room\/([A-Za-z0-9_-]{16,64})$/);
    if (url.pathname === "/" || url.pathname === "/health") return new Response("kiln-relay ok\n");
    if (!match) return new Response("not found", { status: 404 });
    const id = env.ROOMS.idFromName(match[1]);
    return env.ROOMS.get(id).fetch(request);
  },
};
