// Apple Push Notification service from a Worker: a signed token, a request per device, results the Mac can act on.
// The relay holds the push key as a secret and never stores device tokens: the Mac supplies them with each request.

const b64url = (bytes) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const textBytes = (text) => new TextEncoder().encode(text);

export function pemToDer(pem) {
  const body = pem.replace(/-----BEGIN [^-]+-----/, "").replace(/-----END [^-]+-----/, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

/** ES256 provider token (Apple: a new one at most once every 20 minutes, valid for an hour). */
export async function makeProviderToken({ keyPem, keyId, teamId, now = Math.floor(Date.now() / 1000) }) {
  const key = await crypto.subtle.importKey("pkcs8", pemToDer(keyPem), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = b64url(textBytes(JSON.stringify({ alg: "ES256", kid: keyId })));
  const claims = b64url(textBytes(JSON.stringify({ iss: teamId, iat: now })));
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, textBytes(`${header}.${claims}`));
  return `${header}.${claims}.${b64url(signature)}`;
}

export function isHexToken(token) { return typeof token === "string" && /^[0-9a-fA-F]{32,200}$/.test(token); }

/** The request for one device. Only a short, generic alert goes through Apple; details stay on the Mac. */
export function buildRequest({ device, providerToken, alert }) {
  const host = device.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  const payload = {
    aps: { alert: { title: alert.title, body: alert.body }, sound: "default", category: alert.category ?? "KILN_APPROVAL", "interruption-level": "time-sensitive", "thread-id": "kiln-approvals" },
    approvalID: alert.approvalID,
  };
  return {
    url: `https://${host}/3/device/${device.token}`,
    init: {
      method: "POST",
      headers: {
        authorization: `bearer ${providerToken}`,
        "apns-topic": device.topic,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": String(Math.floor(Date.now() / 1000) + 300),
        "content-type": "application/json",
      },
      body: JSON.stringify(payload),
    },
  };
}

/** One result per device: ok, or the reason (so the Mac can drop tokens Apple says are dead). */
export async function sendPush({ env, devices, alert, fetchImpl = fetch, now }) {
  if (!env.APNS_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) return { configured: false, results: [] };
  const providerToken = await makeProviderToken({ keyPem: env.APNS_KEY, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID, now });
  const results = [];
  for (const device of devices.slice(0, 10)) {
    if (!isHexToken(device.token) || typeof device.topic !== "string" || !device.topic) { results.push({ token: device.token, ok: false, reason: "BadDeviceToken" }); continue; }
    const { url, init } = buildRequest({ device, providerToken, alert });
    try {
      const response = await fetchImpl(url, init);
      if (response.ok) { results.push({ token: device.token, ok: true }); continue; }
      let reason = String(response.status);
      try { reason = (await response.json()).reason ?? reason; } catch {}
      results.push({ token: device.token, ok: false, status: response.status, reason });
    } catch (error) {
      results.push({ token: device.token, ok: false, reason: `fetch failed: ${error.message}` });
    }
  }
  return { configured: true, results };
}
