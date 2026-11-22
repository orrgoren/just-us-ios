// Pure helpers for send-push. node --test push.test.mjs covers the flush
// bearer, which queued rows are deleted, the retry cap, due-row order,
// which APNs responses drop a device token, and the chatMessage gate.

import { isServiceCaller } from "../_shared/jwt-role.mjs";

export { isServiceCaller };

// Apple accepts an APNs provider token for an hour. Reuse one for 50
// minutes so a flush does not mint a key for every device.
export const APNS_JWT_TTL_MS = 50 * 60 * 1000;

// A retryable APNs failure keeps the row this many claims, then drops it
// so one broken device cannot sit at the front of the queue forever.
export const MAX_FLUSH_ATTEMPTS = 5;

// One chat notification per recipient in this window. The daily cap does not apply.
// The live check is inside claim_push_delivery, in the same transaction as the insert.
export const CHAT_PUSH_WINDOW_MS = 60 * 1000;

// Mood, a ready plan, and an accepted invite each wait this long before
// another alert of the same kind. Chat does not use this window.
export const SIX_HOUR_DEDUPE_MS = 6 * 60 * 60 * 1000;

export function keepsSixHourDedupe(kind) {
  return kind === "partnerMood" || kind === "inviteAccepted" || kind === "planReady";
}

// Chat and mood skip the once-a-day cap. Mood still keeps the six-hour wait.
export function skipsDailyCap(kind) {
  return kind === "chatMessage" || kind === "partnerMood";
}

// The server stores only en or he. Anything else, including a missing row, is English.
export function recipientLanguage(value) {
  return value === "he" ? "he" : "en";
}

// Chat and photo alerts share this body. It does not quote the chat or say that a photo was sent.
export function chatPushBody(lang) {
  return recipientLanguage(lang) === "he" ? "הודעה חדשה" : "New message";
}

// Title stays the product name. The body is the receiver's language.
export function pushAlert(kind, name, nudge, lang) {
  const he = recipientLanguage(lang) === "he";
  const who = String(name ?? "");
  let body;
  if (kind === "chatMessage") body = chatPushBody(lang);
  else if (kind === "planReady") body = he ? "הדייט מוכן לחשיפה." : "Your date is ready to reveal.";
  else if (kind === "partnerMood") body = he ? `מצב רוח חדש מאת ${who} לערב שלכם.` : `${who} picked a mood for your night.`;
  else if (kind === "inviteAccepted") body = he ? `${who} בפנים. הערב הזה רשמית של שניכם.` : `${who} is in. This night is officially both of yours.`;
  else if (kind === "weeklyReminder") body = he ? `הערב שלכם, ${who}.` : `Tonight is yours, ${who}.`;
  else if (nudge >= 2) body = he ? `נשאיר את ההזמנה כאן בשביל ${who}. בלי עוד תזכורות.` : `We'll leave the invite here for ${who}. No more reminders.`;
  else body = he ? `ההזמנה עבור ${who} פתוחה, מתי שתרצו.` : `Your invite for ${who} is open whenever you both want it.`;
  return { title: "Just Us", body };
}

export function chatPushDecision({ recentMessage, lastPushAt, now }) {
  if (!recentMessage) return "no_message";
  if (typeof lastPushAt === "number" && Number.isFinite(lastPushAt) && now - lastPushAt < CHAT_PUSH_WINDOW_MS) {
    return "coalesced";
  }
  return "send";
}

export function freshApnsToken(cached, now) {
  if (!cached || typeof cached.token !== "string" || cached.token.length === 0) return null;
  if (typeof cached.mintedAt !== "number") return null;
  if (now - cached.mintedAt >= APNS_JWT_TTL_MS) return null;
  return cached.token;
}

export function dropDeviceToken(status, reason) {
  if (status === 410) return true;
  if (status !== 400) return false;
  return reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic";
}

export function providerTokenRejected(status, reason) {
  return status === 403 && (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken");
}

export function retryableApns(status, reason) {
  if (status === 429) return true;
  return providerTokenRejected(status, reason);
}

// One log line per APNs attempt. The device token is only its first six
// characters. The provider JWT and the .p8 never belong in this line.
export function apnsAttemptLog(attempt) {
  const token = String(attempt.token ?? "");
  const prefix = token.slice(0, 6).replace(/[\r\n\s]/g, "");
  const fields = [
    ["kind", attempt.kind],
    ["status", attempt.status],
    ["reason", attempt.reason || "-"],
    ["apns_id", attempt.apnsId || "-"],
    ["sandbox", attempt.sandbox === true],
    ["topic", attempt.topic],
    ["key_id", attempt.keyId],
    ["team_id", attempt.teamId],
    ["token_prefix", prefix],
  ];
  const body = fields.map(([key, value]) => `${key}=${logValue(value)}`).join(" ");
  return `send-push apns ${body}`;
}

export function safeErrorMessage(error) {
  const message = error instanceof Error ? error.message : String(error ?? "");
  return message
    .replace(/-----BEGIN [^-]+-----[\s\S]*?-----END [^-]+-----/g, "[redacted-key]")
    .replace(/\/3\/device\/[^/?\s]+/gi, "/3/device/[token]")
    .replace(/\bsb_secret_[A-Za-z0-9_-]+/g, "[redacted-secret]")
    .replace(/\b[0-9a-f]{32,}\b/gi, "[token]")
    .replace(/\b[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g, "[redacted-jwt]")
    .replace(/bearer\s+\S+/gi, "bearer [redacted]")
    .replace(/(?:[A-Za-z0-9+/]{16,}[ \t]*\r?\n[ \t]*){2,}[A-Za-z0-9+/]{16,}={0,2}/g, "[redacted-key]")
    .replace(/\b[A-Za-z0-9+/]{64,}={0,2}\b/g, "[redacted-key]");
}

function logValue(value) {
  return String(value ?? "").replace(/[\r\n]/g, " ").replace(/\s+/g, "_").slice(0, 120);
}

export function orderedDue(rows, now = Number.POSITIVE_INFINITY, limit = 50) {
  const due = Number.isFinite(now)
    ? rows.filter((row) => Date.parse(row.not_before) <= now)
    : [...rows];
  due.sort((left, right) => {
    const time = Date.parse(left.not_before) - Date.parse(right.not_before);
    if (time !== 0) return time;
    return String(left.id).localeCompare(String(right.id));
  });
  return due.slice(0, limit);
}

// A send or a hold is final: delete the row. A due row is sent even when
// the local time is between 22:00 and 08:00. A throw, an APNs error, or a
// retry stays until the attempt cap, and the next row still runs. A defer,
// if a caller returns one, still moves not_before on that same row.
export async function flushDue(rows, work) {
  let sent = 0;
  const removed = [];
  const kept = [];
  for (const row of rows) {
    let decision = null;
    try {
      decision = await work.deliver(row);
    } catch {
      await retainOrDrop(row, work, kept, removed);
      continue;
    }
    try {
      if (decision?.decision === "send") sent += 1;
      if (decision?.decision === "defer") {
        await work.reschedule(row, decision.not_before);
        continue;
      }
      if (decision?.error === "apns" || decision?.error === "retry") {
        await retainOrDrop(row, work, kept, removed);
        continue;
      }
      if (decision?.decision === "send" || decision?.decision === "suppress") {
        await work.remove(row);
        removed.push(row.id);
        continue;
      }
      await retainOrDrop(row, work, kept, removed);
    } catch {
      if (decision?.decision === "send" || decision?.decision === "suppress") {
        try {
          await work.remove(row);
          removed.push(row.id);
        } catch {
          kept.push(row.id);
        }
      } else {
        kept.push(row.id);
      }
    }
  }
  return { sent, kept, removed };
}

async function retainOrDrop(row, work, kept, removed) {
  const attempts = Number(row.attempts) || 0;
  if (attempts >= MAX_FLUSH_ATTEMPTS) {
    await work.remove(row);
    removed.push(row.id);
    return;
  }
  kept.push(row.id);
}
