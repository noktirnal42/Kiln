// The same relay on plain Node: for tests, and for self-hosting on any machine you control (put it behind TLS).
import http from "node:http";
import { WebSocketServer } from "ws";
import { Room } from "./room.mjs";

export function startRelay({ port = 0, host = "127.0.0.1" } = {}) {
  const rooms = new Map();
  const server = http.createServer((req, res) => { res.end("kiln-relay ok\n"); });
  const wss = new WebSocketServer({ noServer: true, maxPayload: 256 * 1024 });
  server.on("upgrade", (req, socket, head) => {
    const url = new URL(req.url, "http://relay");
    const match = url.pathname.match(/^\/v1\/room\/([A-Za-z0-9_-]{16,64})$/);
    if (!match) { socket.destroy(); return; }
    wss.handleUpgrade(req, socket, head, (ws) => {
      let room = rooms.get(match[1]);
      if (!room) { room = new Room(); rooms.set(match[1], room); }
      const adapter = { send: (data) => ws.send(data), close: (code, reason) => ws.close(code, reason) };
      const token = (req.headers.authorization ?? "").replace(/^Bearer /, "");
      const refusal = room.join(url.searchParams.get("role"), token, adapter);
      if (refusal) { ws.close(refusal.code, refusal.reason); return; }
      ws.on("message", (data, isBinary) => { if (isBinary) room.message(adapter, new Uint8Array(data)); });
      ws.on("close", () => room.leave(adapter));
      ws.on("error", () => room.leave(adapter));
    });
  });
  return new Promise((resolve) => server.listen(port, host, () => resolve({ server, port: server.address().port, close: () => { wss.clients.forEach((c) => c.terminate()); server.close(); } })));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const { port } = await startRelay({ port: Number(process.env.PORT ?? 8787), host: process.env.HOST ?? "0.0.0.0" });
  console.log(`kiln relay listening on :${port}`);
}
