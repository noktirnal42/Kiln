// The whole relay protocol, with no platform code in it. A "socket" is anything with send(Uint8Array) and close(code, reason).
//
//   Mac    <-> relay: binary frames  [type:1][deviceId:4 big-endian][payload]   (see KilnRemoteKit RelayFrame)
//   device <-> relay: the plain Kiln remote protocol, no prefix
//
// The relay never holds a key and never parses payloads; everything inside is already encrypted end to end.

export const DATA = 1, DEVICE_JOINED = 2, DEVICE_LEFT = 3, CLOSE_DEVICE = 4;
export const MAX_FRAME = 256 * 1024;
export const MAX_DEVICES = 8;

export function frame(type, id, payload = new Uint8Array(0)) {
  const out = new Uint8Array(5 + payload.length);
  out[0] = type;
  new DataView(out.buffer).setUint32(1, id, false);
  out.set(payload, 5);
  return out;
}

export function constantTimeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export class Room {
  constructor(authToken = null) {
    this.authToken = authToken; // set by the first Mac to claim the room
    this.mac = null;
    this.devices = new Map(); // id -> socket
    this.ids = new Map();     // socket -> id
    this.nextId = 1;
  }

  /** Returns null when joined, or {code, reason} to close the socket with. */
  join(role, token, socket) {
    if (role !== "mac" && role !== "device") return { code: 4400, reason: "bad role" };
    if (this.authToken === null) {
      if (role !== "mac") return { code: 4404, reason: "no such room" };
      if (typeof token !== "string" || token.length < 32) return { code: 4401, reason: "bad token" };
      this.authToken = token;
      this.onNewToken?.(token);
    } else if (!constantTimeEqual(token, this.authToken)) {
      return { code: 4401, reason: "unauthorized" };
    }
    if (role === "mac") {
      if (this.mac) {
        // The new Mac has not met these devices, so they reconnect rather than stay attached to a Mac that is gone.
        const old = this.mac;
        this.mac = null;
        old.close(4409, "replaced by a newer Mac connection");
        for (const device of [...this.devices.values()]) device.close(4503, "mac reconnected");
        this.devices.clear();
        this.ids.clear();
      }
      this.mac = socket;
      return null;
    }
    if (!this.mac) return { code: 4503, reason: "mac offline" };
    if (this.devices.size >= MAX_DEVICES) return { code: 4429, reason: "too many devices" };
    const id = this.nextId++;
    this.devices.set(id, socket);
    this.ids.set(socket, id);
    this.mac.send(frame(DEVICE_JOINED, id));
    return null;
  }

  /** A binary message from a socket that has joined. Anything oversize or malformed closes that socket. */
  message(socket, data) {
    if (!(data instanceof Uint8Array)) return; // text frames are ignored
    if (data.length > MAX_FRAME) return socket.close(1009, "frame too large");
    if (socket === this.mac) {
      if (data.length < 5) return;
      const id = new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(1, false);
      const target = this.devices.get(id);
      if (data[0] === DATA) target?.send(data.subarray(5));
      else if (data[0] === CLOSE_DEVICE) target?.close(1000, "closed by Mac");
      return;
    }
    const id = this.ids.get(socket);
    if (id !== undefined) this.mac?.send(frame(DATA, id, data));
  }

  leave(socket) {
    if (socket === this.mac) {
      this.mac = null;
      for (const device of [...this.devices.values()]) device.close(4503, "mac offline");
      this.devices.clear();
      this.ids.clear();
      return;
    }
    const id = this.ids.get(socket);
    if (id === undefined) return;
    this.ids.delete(socket);
    this.devices.delete(id);
    this.mac?.send(frame(DEVICE_LEFT, id));
  }
}
