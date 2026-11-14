// PROPOSED REPLACEMENT. Do not deploy until Tom applies
// supabase/proposed/002_push_deliveries.sql and verifies this function.
//
// send-push v1 is already deployed with verify_jwt on. verify_jwt accepts the
// anon key, and v1 also reads `kind` inside send() where it is not in scope,
// so it throws before APNs. This file is the fix. It is not deployed.
//
// The body is only { "kind" }. Device tokens, display names, the local hour,
// and the nudge index are never taken from the client. The recipient's tokens
// are loaded with the service role after the caller's JWT is confirmed to be
// a user. Quiet hours, the daily cap, the six-hour dedupe, and the invite
// nudge windows match JustUs/Domain/PushPolicy.swift.
//
// Secrets stay on the function and are never committed:
//   APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID, APNS_KEY_P8
//   APNS_USE_SANDBOX=true only for a development-entitlement build
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY are injected.

const QUIET_START = 22;
const QUIET_END = 8;
const DEDUPE_MS = 6 * 60 * 60 * 1000;
const INVITE_TTL_HOURS = 7 * 24;
const KINDS = ["partnerMood", "planReady", "inviteAccepted", "weeklyReminder", "inviteNudge"] as const;
type Kind = (typeof KINDS)[number];

const CLIENT_FIELDS = ["token", "partnerName", "localHour", "nudgeIndex", "devices"];

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "method" }, 405);

  let body: Record<string, unknown>;
  try {
    const parsed = await request.json();
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return json({ error: "body" }, 400);
    body = parsed as Record<string, unknown>;
  } catch {
    return json({ error: "body" }, 400);
  }
  if (CLIENT_FIELDS.some((field) => field in body)) return json({ error: "client_fields" }, 400);

  const kind = body.kind;
  if (typeof kind !== "string" || !KINDS.includes(kind as Kind)) return json({ error: "kind" }, 400);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !anonKey || !serviceKey) return json({ error: "configuration" }, 500);

  const callerId = await authenticatedUserId(request, supabaseUrl, anonKey);
  if (!callerId) return json({ error: "not_authenticated" }, 401);

  try {
    const decision = await deliver(kind as Kind, callerId, supabaseUrl, serviceKey);
    return json(decision.body, decision.status);
  } catch (error) {
    const message = error instanceof Error ? error.message : "";
    if (message === "push_log_missing") return json({ error: "push_log_missing" }, 503);
    return json({ error: "unavailable" }, 500);
  }
});

async function deliver(
  kind: Kind,
  callerId: string,
  supabaseUrl: string,
  serviceKey: string,
): Promise<{ status: number; body: Record<string, unknown> }> {
  const db = new Db(supabaseUrl, serviceKey);
  const callerRows = await db.select<{ couple_id: string; display_name: string }[]>(
    `couple_members?user_id=eq.${callerId}&select=couple_id,display_name&limit=1`,
  );
  const caller = callerRows[0];
  if (!caller || !isUuid(caller.couple_id)) return { status: 200, body: { decision: "suppress", reason: "no_couple" } };

  const partnerRows = await db.select<{ user_id: string; display_name: string }[]>(
    `couple_members?couple_id=eq.${caller.couple_id}&user_id=neq.${callerId}&select=user_id,display_name&limit=1`,
  );
  const partner = partnerRows[0] ?? null;
  const coupleRows = await db.select<{ timezone: string; invitee_display_name: string }[]>(
    `couples?id=eq.${caller.couple_id}&select=timezone,invitee_display_name&limit=1`,
  );
  const couple = coupleRows[0];
  if (!couple) return { status: 200, body: { decision: "suppress", reason: "no_couple" } };

  // Mood, reveal, invite-accepted, and the weekly reminder go to the other
  // member. An invite nudge is the opposite: the invitee has no account yet,
  // so the reminder goes to the caller's own registered devices. The token
  // list still comes from device_tokens, never from the request.
  const recipientId = kind === "inviteNudge" ? callerId : partner?.user_id;
  if (!recipientId) return { status: 200, body: { decision: "suppress", reason: "no_partner" } };
  if (kind === "inviteNudge" && partner) return { status: 200, body: { decision: "suppress", reason: "couple_full" } };

  const preferenceRows = await db.select<Record<string, boolean>[]>(
    `notification_preferences?user_id=eq.${recipientId}&select=partner_mood,plan_ready,invite_accepted,weekly_reminder&limit=1`,
  );
  const preferences = preferenceRows[0] ?? {
    partner_mood: true,
    plan_ready: true,
    invite_accepted: true,
    weekly_reminder: true,
  };
  if (!allows(kind, preferences)) return { status: 200, body: { decision: "suppress", reason: "preference" } };

  let zoned: { hour: number; day: string };
  try {
    zoned = localParts(new Date(), couple.timezone);
  } catch {
    return { status: 200, body: { decision: "suppress", reason: "invalid_timezone" } };
  }
  if (zoned.hour >= QUIET_START || zoned.hour < QUIET_END) {
    return { status: 202, body: { decision: "defer", reason: "quiet_hours" } };
  }

  const since = new Date(Date.now() - 8 * 24 * 60 * 60 * 1000).toISOString();
  // Transactional reveals are not part of the cap or the dedupe, and a burst of
  // them must not push the rows that are out of this window.
  const history = await db.select<{ kind: Kind; transactional: boolean; sent_at: string }[]>(
    `push_deliveries?recipient_user_id=eq.${recipientId}&transactional=eq.false&sent_at=gte.${encodeURIComponent(since)}&select=kind,transactional,sent_at&order=sent_at.desc&limit=50`,
  );

  const inviteAge = kind === "inviteNudge" ? await inviteAgeHours(db, caller.couple_id) : null;
  const policy = decide(kind, history, inviteAge, couple.timezone);
  if (policy !== "send") return { status: 200, body: { decision: "suppress", reason: policy } };

  const name = kind === "inviteNudge" ? couple.invitee_display_name : caller.display_name;
  const nudgeIndex = history.filter((row) => row.kind === "inviteNudge").length + 1;
  const text = message(kind, name, nudgeIndex);
  if (forbidden(text)) return { status: 200, body: { decision: "suppress", reason: "secret" } };

  const tokenRows = await db.select<{ token: string }[]>(
    `device_tokens?user_id=eq.${recipientId}&select=token`,
  );
  const tokens = tokenRows.map((row) => row.token).filter((token) => token.length > 0);
  if (tokens.length === 0) return { status: 200, body: { decision: "suppress", reason: "no_device" } };

  const transactional = kind === "planReady";
  const logged = await db.insert("push_deliveries", {
    recipient_user_id: recipientId,
    kind,
    transactional,
  });
  let sent = 0;
  try {
    for (const token of tokens) {
      if (await send(token, text, kind)) sent += 1;
    }
  } catch (error) {
    if (sent === 0) await db.remove("push_deliveries", `id=eq.${logged.id}`);
    throw error;
  }
  if (sent === 0) {
    await db.remove("push_deliveries", `id=eq.${logged.id}`);
    return { status: 502, body: { error: "apns" } };
  }
  return { status: 200, body: { decision: "send", devices: sent } };
}

function allows(kind: Kind, preferences: Record<string, boolean>): boolean {
  if (kind === "partnerMood") return preferences.partner_mood !== false;
  if (kind === "planReady") return preferences.plan_ready !== false;
  if (kind === "inviteAccepted") return preferences.invite_accepted !== false;
  return preferences.weekly_reminder !== false;
}

function decide(
  kind: Kind,
  history: { kind: Kind; transactional: boolean; sent_at: string }[],
  inviteAge: number | null,
  timeZone: string,
): "send" | string {
  const now = Date.now();
  if (kind === "partnerMood" || kind === "inviteAccepted") {
    const recent = history.some((row) => row.kind === kind && now - Date.parse(row.sent_at) < DEDUPE_MS);
    if (recent) return "deduped_6h";
  }
  if (kind === "inviteNudge") {
    if (inviteAge === null) return "no_invite";
    const inFirst = inviteAge >= 23.5 && inviteAge <= 24.5;
    const inSecond = inviteAge >= 71.5 && inviteAge <= 72.5;
    if (!inFirst && !inSecond) return "outside_nudge_window";
    const nudges = history.filter((row) => row.kind === "inviteNudge" && Date.parse(row.sent_at) > 0);
    if (nudges.some((row) => inviteAge >= 72 && now - Date.parse(row.sent_at) > 60 * 60 * 1000)) {
      return "nudges_finished";
    }
    if (nudges.length >= 2) return "nudges_finished";
  }
  if (kind !== "planReady") {
    const today = localParts(new Date(), timeZone).day;
    const already = history.some((row) => !row.transactional && localParts(new Date(row.sent_at), timeZone).day === today);
    if (already) return "daily_non_transactional";
  }
  return "send";
}

async function inviteAgeHours(db: Db, coupleId: string): Promise<number | null> {
  const now = new Date();
  const rows = await db.select<{ expires_at: string }[]>(
    `couple_invites?couple_id=eq.${coupleId}&redeemed_at=is.null&revoked_at=is.null&expires_at=gt.${encodeURIComponent(now.toISOString())}&select=expires_at&order=expires_at.desc&limit=1`,
  );
  const expires = rows[0]?.expires_at;
  if (!expires) return null;
  // The iOS app stores expires_at as seven days after the invite is created.
  // couple_invites has no created_at, so the age is the remainder of that window.
  return INVITE_TTL_HOURS - (Date.parse(expires) - now.getTime()) / (60 * 60 * 1000);
}

function message(kind: Kind, name: string, nudge: number): string {
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

function localParts(now: Date, timeZone: string): { hour: number; day: string } {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
  }).formatToParts(now);
  const pick = (type: string) => parts.find((part) => part.type === type)?.value ?? "";
  let hour = Number(pick("hour"));
  if (hour === 24) hour = 0;
  return { hour, day: `${pick("year")}-${pick("month")}-${pick("day")}` };
}

class Db {
  constructor(private readonly url: string, private readonly serviceKey: string) {}

  async select<T>(path: string): Promise<T> {
    const response = await this.request(path, { method: "GET" });
    if (response.status === 404) throw new Error("push_log_missing");
    if (!response.ok) throw new Error("db");
    return await response.json() as T;
  }

  async insert(table: string, row: Record<string, unknown>): Promise<{ id: string }> {
    const response = await this.request(table, {
      method: "POST",
      headers: { prefer: "return=representation" },
      body: JSON.stringify(row),
    });
    if (response.status === 404) throw new Error("push_log_missing");
    if (!response.ok) throw new Error("db");
    const rows = await response.json() as { id: string }[];
    const id = rows[0]?.id;
    if (!id) throw new Error("db");
    return { id };
  }

  async remove(table: string, filter: string): Promise<void> {
    const response = await this.request(`${table}?${filter}`, { method: "DELETE" });
    if (!response.ok) throw new Error("db");
  }

  private request(path: string, init: RequestInit): Promise<Response> {
    const headers = new Headers(init.headers);
    headers.set("apikey", this.serviceKey);
    headers.set("authorization", `Bearer ${this.serviceKey}`);
    headers.set("content-type", "application/json");
    return fetch(`${this.url}/rest/v1/${path}`, { ...init, headers });
  }
}

async function authenticatedUserId(request: Request, supabaseUrl: string, anonKey: string): Promise<string | null> {
  const header = request.headers.get("authorization") ?? "";
  const token = header.replace(/^Bearer\s+/i, "").trim();
  if (!token || token === anonKey) return null;
  const response = await fetch(`${supabaseUrl}/auth/v1/user`, {
    headers: { authorization: `Bearer ${token}`, apikey: anonKey },
  });
  if (!response.ok) return null;
  const body = await response.json() as { id?: unknown };
  return typeof body.id === "string" && isUuid(body.id) ? body.id : null;
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

async function send(token: string, text: string, kind: Kind): Promise<boolean> {
  const jwt = await apnsJwt();
  const sandbox = Deno.env.get("APNS_USE_SANDBOX") === "true";
  const host = sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
  const topic = Deno.env.get("APNS_BUNDLE_ID") ?? "com.orrgoren.justus";
  const response = await fetch(`https://${host}/3/device/${encodeURIComponent(token)}`, {
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
  return response.ok;
}

async function apnsJwt(): Promise<string> {
  const keyId = Deno.env.get("APNS_KEY_ID") ?? "";
  const teamId = Deno.env.get("APNS_TEAM_ID") ?? "";
  const pem = Deno.env.get("APNS_KEY_P8") ?? "";
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToBytes(pem),
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
