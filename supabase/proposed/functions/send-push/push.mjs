// Pure helpers for send-push. node --test push.test.mjs covers the flush
// bearer, when a queued row may be deleted, and how long an APNs token lasts.

import { isServiceCaller } from "../_shared/jwt-role.mjs";

export { isServiceCaller };

// Apple accepts an APNs provider token for an hour. Reuse one for 50
// minutes so a flush does not mint a key for every device.
export const APNS_JWT_TTL_MS = 50 * 60 * 1000;

export function freshApnsToken(cached, now) {
  if (!cached || typeof cached.token !== "string" || cached.token.length === 0) return null;
  if (typeof cached.mintedAt !== "number") return null;
  if (now - cached.mintedAt >= APNS_JWT_TTL_MS) return null;
  return cached.token;
}

// Delete a queued row only after the send succeeded. A throw or any other
// decision leaves the row, and the next row still runs.
export async function flushDue(rows, work) {
  let sent = 0;
  const kept = [];
  for (const row of rows) {
    try {
      const decision = await work.deliver(row);
      if (decision?.decision !== "send") {
        kept.push(row.id);
        continue;
      }
      await work.remove(row);
      sent += 1;
    } catch {
      kept.push(row.id);
    }
  }
  return { sent, kept };
}
