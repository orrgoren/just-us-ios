// Pure helpers for send-push. node --test push.test.mjs covers the flush
// bearer, which queued rows are deleted, the retry cap, due-row order, and
// which APNs responses drop a device token.

import { isServiceCaller } from "../_shared/jwt-role.mjs";

export { isServiceCaller };

// Apple accepts an APNs provider token for an hour. Reuse one for 50
// minutes so a flush does not mint a key for every device.
export const APNS_JWT_TTL_MS = 50 * 60 * 1000;

// A retryable APNs failure keeps the row this many claims, then drops it
// so one broken device cannot sit at the front of the queue forever.
export const MAX_FLUSH_ATTEMPTS = 5;

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

// A send or a hold is final: delete the row. A defer moves not_before on
// the same row. A throw, an APNs error, or a retry stays until the attempt
// cap, and the next row still runs.
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
