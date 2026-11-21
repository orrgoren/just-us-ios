// Live send-push is v8. The earlier v6 source was 5013075 (the same content
// as 7872d1e). a12f1d1 is v3 and is the rollback source.
// 002, 006, and 007 are already applied. Do not re-apply them.
//
// The body is only { "kind" }. Device tokens, display names, the local hour,
// and the nudge index are never taken from the client. The recipient's tokens
// are loaded with the service role after the caller's JWT is confirmed to be
// a user. The daily cap, the six-hour dedupe, and the invite nudge windows
// match JustUs/Domain/PushPolicy.swift. partnerMood skips the daily cap
// and still waits six hours. A push is not held for
// 22:00–08:00. chatMessage skips the daily cap and the six-hour dedupe. It
// is sent only when the caller inserted a chat_messages row in the last 60
// seconds.
// The one-per-recipient window is checked and claimed together inside
// claim_push_delivery, under its advisory lock.
//
// A flush is { "kind": "flush" } from the justus-push-flush cron. The bearer
// is the legacy service_role JWT in the justus_service_role vault secret.
// SUPABASE_SERVICE_ROLE_KEY may be the newer sb_secret key, so a string
// compare is not enough. verify_jwt is pinned on in supabase/config.toml,
// and the payload role is what identifies the cron. A queued row is deleted
// on any final decision, sent or held. It stays only when the send throws
// or APNs asks for a retry, and only until the attempt cap. Rows already
// waiting in push_outbox are sent once not_before is due. They are not
// moved to the morning. The APNs provider token is reused for 50 minutes
// and dropped on 403.
//
// Secrets stay on the function and are never committed:
//   APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID, APNS_KEY_P8
//   APNS_USE_SANDBOX=true only for a development-entitlement build
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY are injected.

import { isServiceCaller } from "../_shared/jwt-role.mjs";
import { apnsAttemptLog, CHAT_PUSH_WINDOW_MS, dropDeviceToken, flushDue, freshApnsToken, keepsSixHourDedupe, orderedDue, providerTokenRejected, retryableApns, safeErrorMessage, SIX_HOUR_DEDUPE_MS, skipsDailyCap } from "./push.mjs";

const INVITE_TTL_HOURS = 7 * 24;
const KINDS = ["partnerMood", "planReady", "inviteAccepted", "weeklyReminder", "inviteNudge", "chatMessage"] as const;
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
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !anonKey || !serviceKey) return json({ error: "configuration" }, 500);

  const header = request.headers.get("authorization") ?? "";
  const bearer = header.replace(/^Bearer\s+/i, "").trim();
  if (isServiceCaller(bearer, serviceKey) && kind === "flush") {
    try {
      const flushed = await flushOutbox(supabaseUrl, serviceKey);
      return json(flushed, 200);
    } catch (error) {
      console.log(`send-push flush error ${safeErrorMessage(error)}`);
      const message = error instanceof Error ? error.message : "";
      if (message === "push_log_missing") return json({ error: "push_log_missing" }, 503);
      return json({ error: "unavailable" }, 500);
    }
  }

  if (typeof kind !== "string" || !KINDS.includes(kind as Kind)) return json({ error: "kind" }, 400);

  const callerId = await authenticatedUserId(request, supabaseUrl, anonKey);
  if (!callerId) return json({ error: "not_authenticated" }, 401);

  try {
    const decision = await deliver(kind as Kind, callerId, supabaseUrl, serviceKey);
    return json(decision.body, decision.status);
  } catch (error) {
    console.log(`send-push error ${safeErrorMessage(error)}`);
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

  // The client names the event. The rows decide whether it happened.
  if (kind === "planReady") {
    const nights = await db.select<{ id: string }[]>(
      `dates?couple_id=eq.${caller.couple_id}&planner_user_id=eq.${callerId}&status=eq.scheduled&revealed_at=is.null&select=id&limit=1`,
    );
    const nightId = nights[0]?.id;
    if (!nightId) return { status: 200, body: { decision: "suppress", reason: "not_ready" } };
    const plans = await db.select<{ date_id: string }[]>(
      `private_date_plans?date_id=eq.${nightId}&select=date_id&limit=1`,
    );
    if (!plans[0]) return { status: 200, body: { decision: "suppress", reason: "not_ready" } };
  }
  if (kind === "partnerMood") {
    const votes = await db.select<{ date_id: string }[]>(
      `mood_votes?user_id=eq.${callerId}&select=date_id&limit=1`,
    );
    if (!votes[0]) return { status: 200, body: { decision: "suppress", reason: "no_mood" } };
  }
  if (kind === "inviteAccepted" && !partner) {
    return { status: 200, body: { decision: "suppress", reason: "no_partner" } };
  }

  // Weekly reminder is to the caller, about their partner. Other events go
  // to the partner and name the caller. An invite nudge has no invitee
  // account, so it uses the caller's own devices.
  let recipientId = partner?.user_id ?? "";
  let name = caller.display_name;
  if (kind === "inviteNudge") {
    if (partner) return { status: 200, body: { decision: "suppress", reason: "couple_full" } };
    recipientId = callerId;
    name = couple.invitee_display_name;
  } else if (kind === "weeklyReminder") {
    recipientId = callerId;
    name = partner?.display_name || couple.invitee_display_name;
  } else if (!partner) {
    return { status: 200, body: { decision: "suppress", reason: "no_partner" } };
  }

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

  if (kind === "chatMessage") {
    const since = new Date(Date.now() - CHAT_PUSH_WINDOW_MS).toISOString();
    const notes = await db.select<{ id: string }[]>(
      `chat_messages?couple_id=eq.${caller.couple_id}&sender_user_id=eq.${callerId}&created_at=gte.${encodeURIComponent(since)}&select=id&limit=1`,
    );
    if (!notes[0]) return { status: 200, body: { decision: "suppress", reason: "no_message" } };
  }

  try {
    localParts(new Date(), couple.timezone);
  } catch {
    return { status: 200, body: { decision: "suppress", reason: "invalid_timezone" } };
  }
  const since = new Date(Date.now() - 8 * 24 * 60 * 60 * 1000).toISOString();
  // planReady uses the same daily cap and six-hour dedupe as the other kinds.
  const history = await db.select<{ kind: Kind; transactional: boolean; sent_at: string }[]>(
    `push_deliveries?recipient_user_id=eq.${recipientId}&transactional=eq.false&sent_at=gte.${encodeURIComponent(since)}&select=kind,transactional,sent_at&order=sent_at.desc&limit=50`,
  );

  const inviteAge = kind === "inviteNudge" ? await inviteAgeHours(db, caller.couple_id) : null;
  const policy = decide(kind, history, inviteAge, couple.timezone);
  if (policy !== "send") return { status: 200, body: { decision: "suppress", reason: policy } };

  const nudgeIndex = history.filter((row) => row.kind === "inviteNudge").length + 1;
  const text = message(kind, name, nudgeIndex);
  if (forbidden(text)) return { status: 200, body: { decision: "suppress", reason: "secret" } };

  const tokens = await loadTokens(db, recipientId);
  if (tokens.length === 0) return { status: 200, body: { decision: "suppress", reason: "no_device" } };

  const claimed = await db.claim(recipientId, kind, couple.timezone);
  if (!claimed.ok) return { status: 200, body: { decision: "suppress", reason: claimed.reason } };

  // Membership can end after the claim and before APNs. Check again here.
  const still = await db.select<{ user_id: string }[]>(
    `couple_members?user_id=eq.${callerId}&couple_id=eq.${caller.couple_id}&select=user_id&limit=1`,
  );
  if (!still[0]) {
    await db.remove("push_deliveries", `id=eq.${claimed.id}`);
    return { status: 200, body: { decision: "suppress", reason: "no_couple" } };
  }

  const jwt = await apnsJwt();
  let sent = 0;
  let retry = false;
  try {
    for (const device of tokens) {
      const sandbox = device.environment
        ? device.environment === "sandbox"
        : Deno.env.get("APNS_USE_SANDBOX") === "true";
      const result = await send(device.token, text, kind, jwt, sandbox);
      if (providerTokenRejected(result.status, result.reason)) {
        apnsCached = null;
        retry = true;
        break;
      }
      if (retryableApns(result.status, result.reason)) {
        retry = true;
        break;
      }
      if (dropDeviceToken(result.status, result.reason)) {
        await db.remove("device_tokens", `user_id=eq.${recipientId}&token=eq.${encodeURIComponent(device.token)}`);
        continue;
      }
      if (result.status >= 200 && result.status < 300) sent += 1;
      else retry = true;
    }
  } catch (error) {
    if (sent === 0) {
      await db.remove("push_deliveries", `id=eq.${claimed.id}`);
      throw error;
    }
    console.log(`send-push apns error ${safeErrorMessage(error)}`);
    // A later device threw after one send. Deleting the row is final, so
    // the next flush cannot deliver the same alert again.
    return { status: 200, body: { decision: "send", devices: sent } };
  }
  if (sent === 0) {
    await db.remove("push_deliveries", `id=eq.${claimed.id}`);
    return { status: retry ? 503 : 502, body: { error: retry ? "retry" : "apns" } };
  }
  return { status: 200, body: { decision: "send", devices: sent } };
}

function allows(kind: Kind, preferences: Record<string, boolean>): boolean {
  if (kind === "chatMessage") return true;
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
  if (keepsSixHourDedupe(kind)) {
    const recent = history.some((row) => row.kind === kind && now - Date.parse(row.sent_at) < SIX_HOUR_DEDUPE_MS);
    if (recent) return "deduped_6h";
  }
  if (skipsDailyCap(kind)) return "send";
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
  const today = localParts(new Date(), timeZone).day;
  const already = history.some((row) => !row.transactional && localParts(new Date(row.sent_at), timeZone).day === today);
  if (already) return "daily_non_transactional";
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
  if (kind === "chatMessage") return `${name} sent a message.`;
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

function localParts(now: Date, timeZone: string): { day: string } {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(now);
  const pick = (type: string) => parts.find((part) => part.type === type)?.value ?? "";
  return { day: `${pick("year")}-${pick("month")}-${pick("day")}` };
}

class Db {
  constructor(private readonly url: string, private readonly serviceKey: string) {}

  async select<T>(path: string): Promise<T> {
    const response = await this.request(path, { method: "GET" });
    if (response.status === 404) throw new Error("push_log_missing");
    if (!response.ok) throw new Error("db");
    return await response.json() as T;
  }

  async remove(table: string, filter: string): Promise<void> {
    const response = await this.request(`${table}?${filter}`, { method: "DELETE" });
    if (!response.ok) throw new Error("db");
  }

  async update(table: string, filter: string, row: Record<string, unknown>): Promise<void> {
    const response = await this.request(`${table}?${filter}`, { method: "PATCH", body: JSON.stringify(row) });
    if (!response.ok) throw new Error("db");
  }

  async claimDue(limit: number): Promise<{ id: string; caller_user_id: string; kind: Kind; attempts: number; not_before: string }[]> {
    const response = await this.request("rpc/claim_due_outbox", {
      method: "POST",
      body: JSON.stringify({ p_limit: limit }),
    });
    if (response.status === 404) throw new Error("push_log_missing");
    if (!response.ok) throw new Error("db");
    return await response.json() as { id: string; caller_user_id: string; kind: Kind; attempts: number; not_before: string }[];
  }

  async claim(recipient: string, kind: Kind, timezone: string): Promise<{ ok: true; id: string } | { ok: false; reason: string }> {
    const response = await this.request("rpc/claim_push_delivery", {
      method: "POST",
      body: JSON.stringify({ p_recipient: recipient, p_kind: kind, p_timezone: timezone }),
    });
    if (response.status === 404) throw new Error("push_log_missing");
    if (!response.ok) {
      const body = await response.text();
      if (body.includes("deduped_6h")) return { ok: false, reason: "deduped_6h" };
      if (body.includes("daily_non_transactional")) return { ok: false, reason: "daily_non_transactional" };
      if (body.includes("coalesced")) return { ok: false, reason: "coalesced" };
      throw new Error("db");
    }
    const id = await response.json() as string;
    if (!id) throw new Error("db");
    return { ok: true, id };
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

async function loadTokens(db: Db, recipientId: string): Promise<{ token: string; environment: string | null }[]> {
  try {
    const rows = await db.select<{ token: string; environment: string | null }[]>(
      `device_tokens?user_id=eq.${recipientId}&select=token,environment`,
    );
    return rows.filter((row) => row.token.length > 0);
  } catch (error) {
    if (error instanceof Error && error.message === "push_log_missing") throw error;
    const rows = await db.select<{ token: string }[]>(
      `device_tokens?user_id=eq.${recipientId}&select=token`,
    );
    return rows.filter((row) => row.token.length > 0).map((row) => ({ token: row.token, environment: null }));
  }
}

async function flushOutbox(supabaseUrl: string, serviceKey: string): Promise<Record<string, unknown>> {
  const db = new Db(supabaseUrl, serviceKey);
  const due = orderedDue(await db.claimDue(50));
  const outcome = await flushDue(due, {
    deliver: async (row) => {
      const decision = await deliver(row.kind, row.caller_user_id, supabaseUrl, serviceKey);
      return decision.body;
    },
    remove: (row) => db.remove("push_outbox", `id=eq.${row.id}`),
    reschedule: (row, notBefore) => db.update("push_outbox", `id=eq.${row.id}`, { not_before: notBefore }),
  });
  return { decision: "flush", sent: outcome.sent, kept: outcome.kept.length };
}

async function send(
  token: string,
  text: string,
  kind: Kind,
  jwt: string,
  sandbox: boolean,
): Promise<{ status: number; reason: string }> {
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
  let reason = "";
  try {
    const body = await response.json() as { reason?: unknown };
    if (typeof body?.reason === "string") reason = body.reason;
  } catch {
    reason = "";
  }
  console.log(apnsAttemptLog({
    kind,
    status: response.status,
    reason,
    apnsId: response.headers.get("apns-id") ?? "",
    sandbox,
    topic,
    keyId: Deno.env.get("APNS_KEY_ID") ?? "",
    teamId: Deno.env.get("APNS_TEAM_ID") ?? "",
    token,
  }));
  return { status: response.status, reason };
}

let apnsCached: { token: string; mintedAt: number } | null = null;

async function apnsJwt(): Promise<string> {
  const now = Date.now();
  const cached = freshApnsToken(apnsCached, now);
  if (cached) return cached;
  const token = await mintApnsJwt();
  apnsCached = { token, mintedAt: now };
  return token;
}

async function mintApnsJwt(): Promise<string> {
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
