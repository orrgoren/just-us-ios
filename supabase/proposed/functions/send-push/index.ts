// PROPOSED ONLY. Do not deploy until Orr approves.
// Quiet hours match PushPolicy. The daily cap, six-hour dedupe, and invite
// nudges at 24h and 72h still have to be enforced here, from the database,
// before this function is allowed to send.
// Secrets, set on the function and never committed:
//   APNS_KEY_ID=S6M487B43U
//   APNS_TEAM_ID=694YR89B4S
//   APNS_BUNDLE_ID=com.orrgoren.justus
//   APNS_KEY_P8=<PEM from GitHub secret APNS_KEY_P8>
//   APNS_USE_SANDBOX=true only for a development-entitlement build

const QUIET_START = 22;
const QUIET_END = 8;

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return json({ error: "method" }, 405);
  }
  const body = await request.json();
  const kind = String(body.kind ?? "");
  const partnerName = String(body.partnerName ?? "");
  const token = String(body.token ?? "");
  const hour = Number(body.localHour ?? 12);
  if (!token || !kind) return json({ error: "missing" }, 400);
  if (hour >= QUIET_START || hour < QUIET_END) {
    return json({ decision: "defer" }, 202);
  }
  const text = message(kind, partnerName, Number(body.nudgeIndex ?? 1));
  if (forbidden(text)) return json({ error: "secret" }, 400);
  await send(token, text);
  return json({ decision: "send" }, 200);
});

function message(kind: string, name: string, nudge: number): string {
  if (kind === "planReady") return "Your date is ready to reveal.";
  if (kind === "partnerMood") return `${name} picked a mood for your night.`;
  if (kind === "inviteAccepted") return `${name} is in. This night is officially both of yours.`;
  if (kind === "weeklyReminder") return `Tonight is yours, ${name}.`;
  if (nudge >= 2) return `We'll leave the invite here for ${name}. No more reminders.`;
  return `Your invite for ${name} is open whenever you both want it.`;
}

function forbidden(text: string): boolean {
  const lower = text.toLowerCase();
  return ["outfit", "at home", "out tonight"].some((secret) => lower.includes(secret));
}

async function send(token: string, text: string): Promise<void> {
  const jwt = await apnsJwt();
  const sandbox = Deno.env.get("APNS_USE_SANDBOX") === "true";
  const host = sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const topic = Deno.env.get("APNS_BUNDLE_ID") ?? "com.orrgoren.justus";
  const response = await fetch(`https://${host}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": topic,
      "apns-push-type": "alert",
    },
    body: JSON.stringify({
      aps: { alert: { title: "Just Us", body: text }, sound: "default" },
      type: kind,
    }),
  });
  if (!response.ok) {
    throw new Error(`apns ${response.status}`);
  }
}

async function apnsJwt(): Promise<string> {
  const keyId = Deno.env.get("APNS_KEY_ID") ?? "";
  const teamId = Deno.env.get("APNS_TEAM_ID") ?? "";
  const pem = Deno.env.get("APNS_KEY_P8") ?? "";
  const bytes = pemToBytes(pem);
  const key = await crypto.subtle.importKey(
    "pkcs8",
    bytes,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const header = b64(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = b64(JSON.stringify({ iss: teamId, iat: Math.floor(Date.now() / 1000) }));
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  return `${header}.${claims}.${b64(signature)}`;
}

function pemToBytes(pem: string): ArrayBuffer {
  const body = pem.replace(/-----BEGIN PRIVATE KEY-----/, "").replace(/-----END PRIVATE KEY-----/, "").replace(/\s+/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes.buffer;
}

function b64(value: string | ArrayBuffer): string {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : new Uint8Array(value);
  let text = "";
  for (const byte of bytes) text += String.fromCharCode(byte);
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function json(payload: unknown, status: number): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}
