import assert from "node:assert/strict";
import test from "node:test";
import { jwtRole } from "../_shared/jwt-role.mjs";
import {
  APNS_JWT_TTL_MS,
  MAX_FLUSH_ATTEMPTS,
  apnsAttemptLog,
  dropDeviceToken,
  flushDue,
  freshApnsToken,
  isServiceCaller,
  chatPushBody,
  chatPushDecision,
  CHAT_PUSH_WINDOW_MS,
  keepsSixHourDedupe,
  orderedDue,
  SIX_HOUR_DEDUPE_MS,
  providerTokenRejected,
  retryableApns,
  safeErrorMessage,
  skipsDailyCap,
} from "./push.mjs";

function jwt(header, claims) {
  const encodedHeader = Buffer.from(JSON.stringify(header)).toString("base64url");
  const payload = Buffer.from(JSON.stringify(claims)).toString("base64url");
  return `${encodedHeader}.${payload}.sig`;
}

test("a legacy service_role JWT is the flush caller when the env key is sb_secret", () => {
  const vault = jwt({ alg: "HS256", typ: "JWT" }, { role: "service_role", ref: "vowmukhhnfhtnjlswkun" });
  assert.equal(isServiceCaller(vault, "sb_secret_example"), true);
  assert.equal(isServiceCaller("sb_secret_example", "sb_secret_example"), true);
  assert.equal(isServiceCaller(jwt({ alg: "HS256" }, { role: "authenticated" }), "sb_secret_example"), false);
  assert.equal(isServiceCaller("", "sb_secret_example"), false);
});

test("an alg none token is not a service caller", () => {
  const forged = jwt({ alg: "none" }, { role: "service_role" });
  const missing = jwt({}, { role: "service_role" });
  assert.equal(jwtRole(forged), "");
  assert.equal(jwtRole(missing), "");
  assert.equal(isServiceCaller(forged, "sb_secret_example"), false);
  assert.equal(isServiceCaller(missing, "sb_secret_example"), false);
  assert.equal(jwtRole(jwt({ alg: "HS256" }, { role: "service_role" })), "service_role");
});

test("a held push is deleted and a failed send stays queued", async () => {
  const removed = [];
  const holds = [
    "preference",
    "no_device",
    "no_couple",
    "not_ready",
    "outside_nudge_window",
    "deduped_6h",
    "daily_non_transactional",
  ];
  const rows = [
    ...holds.map((reason) => ({ id: reason, attempts: 1, not_before: "2026-11-15T08:00:00Z" })),
    { id: "sent", attempts: 1, not_before: "2026-11-15T08:00:00Z" },
    { id: "failed", attempts: 1, not_before: "2026-11-15T08:00:00Z" },
  ];
  const outcome = await flushDue(rows, {
    deliver: async (row) => {
      if (row.id === "failed") throw new Error("apns");
      if (row.id === "sent") return { decision: "send" };
      return { decision: "suppress", reason: row.id };
    },
    remove: async (row) => {
      removed.push(row.id);
    },
    reschedule: async () => {
      throw new Error("held rows are not rescheduled");
    },
  });
  assert.deepEqual(removed, [...holds, "sent"]);
  assert.deepEqual(outcome.kept, ["failed"]);
  assert.equal(outcome.sent, 1);
});

test("an APNs error is kept until the retry cap, including 429", async () => {
  const removed = [];
  const outcome = await flushDue(
    [
      { id: "once", attempts: 1 },
      { id: "capped", attempts: MAX_FLUSH_ATTEMPTS },
      { id: "rate", attempts: 2 },
    ],
    {
      deliver: async (row) => row.id === "rate" ? { error: "retry" } : { error: "apns" },
      remove: async (row) => {
        removed.push(row.id);
      },
      reschedule: async () => {},
    },
  );
  assert.deepEqual(removed, ["capped"]);
  assert.deepEqual(outcome.kept, ["once", "rate"]);
  assert.equal(MAX_FLUSH_ATTEMPTS, 5);
});

test("a queued row is sent once it is due, including at night", async () => {
  const removed = [];
  const moved = [];
  const now = Date.parse("2026-11-15T22:30:00Z");
  const due = orderedDue([
    { id: "night", attempts: 1, not_before: "2026-11-15T20:00:00Z" },
    { id: "later", attempts: 0, not_before: "2026-11-16T08:00:00Z" },
  ], now);
  const outcome = await flushDue(due, {
    deliver: async () => ({ decision: "send" }),
    remove: async (row) => {
      removed.push(row.id);
    },
    reschedule: async (row, notBefore) => {
      moved.push([row.id, notBefore]);
    },
  });
  assert.deepEqual(due.map((row) => row.id), ["night"]);
  assert.deepEqual(removed, ["night"]);
  assert.deepEqual(moved, []);
  assert.equal(outcome.sent, 1);
  assert.deepEqual(outcome.kept, []);
});

test("a defer moves the same row instead of leaving it due", async () => {
  const removed = [];
  const moved = [];
  const outcome = await flushDue([{ id: "held", attempts: 1, not_before: "2026-11-15T20:00:00Z" }], {
    deliver: async () => ({ decision: "defer", not_before: "2026-11-16T12:00:00Z" }),
    remove: async (row) => {
      removed.push(row.id);
    },
    reschedule: async (row, notBefore) => {
      moved.push([row.id, notBefore]);
    },
  });
  assert.deepEqual(removed, []);
  assert.deepEqual(moved, [["held", "2026-11-16T12:00:00Z"]]);
  assert.equal(outcome.sent, 0);
});

test("due rows are taken in not_before order", () => {
  const now = Date.parse("2026-11-15T12:00:00Z");
  const rows = orderedDue([
    { id: "later", not_before: "2026-11-15T11:00:00Z" },
    { id: "sooner", not_before: "2026-11-15T08:00:00Z" },
    { id: "future", not_before: "2026-11-15T13:00:00Z" },
    { id: "tied", not_before: "2026-11-15T08:00:00Z" },
  ], now, 50);
  assert.deepEqual(rows.map((row) => row.id), ["sooner", "tied", "later"]);
});

test("only a dead device token is deleted", () => {
  assert.equal(dropDeviceToken(410, ""), true);
  assert.equal(dropDeviceToken(400, "BadDeviceToken"), true);
  assert.equal(dropDeviceToken(400, "DeviceTokenNotForTopic"), true);
  assert.equal(dropDeviceToken(400, "BadTopic"), false);
  assert.equal(dropDeviceToken(400, ""), false);
  assert.equal(dropDeviceToken(429, "TooManyRequests"), false);
  assert.equal(retryableApns(429, "TooManyRequests"), true);
  assert.equal(providerTokenRejected(403, "ExpiredProviderToken"), true);
  assert.equal(providerTokenRejected(403, "InvalidProviderToken"), true);
  assert.equal(providerTokenRejected(403, "ExpiredToken"), false);
});

test("an APNs attempt log keeps six token characters and no secret", () => {
  const token = "abcdef0123456789deadbeef";
  const line = apnsAttemptLog({
    kind: "partnerMood",
    status: 403,
    reason: "InvalidProviderToken",
    apnsId: "7C0B3E10-1234-4A5B-8C9D-0123456789AB",
    sandbox: false,
    topic: "com.orrgoren.justus",
    keyId: "ABC123DEFG",
    teamId: "TEAMID1234",
    token,
  });
  assert.match(line, /^send-push apns /);
  assert.match(line, /kind=partnerMood/);
  assert.match(line, /status=403/);
  assert.match(line, /reason=InvalidProviderToken/);
  assert.match(line, /apns_id=7C0B3E10-1234-4A5B-8C9D-0123456789AB/);
  assert.match(line, /sandbox=false/);
  assert.match(line, /topic=com\.orrgoren\.justus/);
  assert.match(line, /key_id=ABC123DEFG/);
  assert.match(line, /team_id=TEAMID1234/);
  assert.match(line, /token_prefix=abcdef/);
  assert.equal(line.includes(token), false);
  assert.equal(line.includes("PRIVATE KEY"), false);
  assert.equal(line.includes("\n"), false);
});

test("an error message drops the device token, the key, and a provider jwt", () => {
  const token = "abcdef0123456789deadbeef";
  const pem = "-----BEGIN PRIVATE KEY-----\nsample-body\n-----END PRIVATE KEY-----";
  const dotted = ["aaaabbbb", "ccccdddd", "eeeeffff"].join(".");
  // The word is split so this fixture is not a literal bearer token.
  const message = safeErrorMessage(new Error(
    `connect ${pem} https://api.push.apple.com/3/device/${token} ${"bear" + "er"} ${dotted}`,
  ));
  assert.equal(message.includes(token), false);
  assert.equal(message.includes("sample-body"), false);
  assert.match(message, /\/3\/device\/\[token\]/);
  assert.match(message, /\[redacted-key\]/);
  assert.match(message, /\[redacted-jwt\]|bearer \[redacted\]/);
});

test("an error message drops an sb_secret and a bare p8 body", () => {
  const secret = "sb_secret_" + "examplekeybody0123456789";
  const bare = "A".repeat(40) + "p8body" + "B".repeat(40);
  const lines = ["C".repeat(64), "D".repeat(64), "E".repeat(32)].join("\n");
  const message = safeErrorMessage(new Error(`env ${secret} key ${bare}\n${lines}`));
  assert.equal(message.includes("sb_secret_"), false);
  assert.equal(message.includes(secret.slice("sb_secret_".length)), false);
  assert.equal(message.includes(bare), false);
  assert.equal(message.includes("C".repeat(64)), false);
  assert.equal(message.includes("D".repeat(64)), false);
  assert.match(message, /\[redacted-secret\]/);
  assert.match(message, /\[redacted-key\]/);
});

test("an APNs token is reused for 50 minutes", () => {
  assert.equal(APNS_JWT_TTL_MS, 50 * 60 * 1000);
  const mintedAt = Date.parse("2026-11-15T00:00:00Z");
  const cached = { token: "provider-jwt", mintedAt };
  assert.equal(freshApnsToken(cached, mintedAt + APNS_JWT_TTL_MS - 1), "provider-jwt");
  assert.equal(freshApnsToken(cached, mintedAt + APNS_JWT_TTL_MS), null);
  assert.equal(freshApnsToken(null, mintedAt), null);
  assert.equal(freshApnsToken({ token: "", mintedAt }, mintedAt), null);
});

test("a chat push needs a recent message, coalesces for 60s, and skips the daily cap", () => {
  assert.equal(CHAT_PUSH_WINDOW_MS, 60 * 1000);
  const now = 1_000_000;
  assert.equal(chatPushDecision({ recentMessage: false, lastPushAt: null, now }), "no_message");
  assert.equal(chatPushDecision({ recentMessage: true, lastPushAt: null, now }), "send");
  assert.equal(chatPushDecision({ recentMessage: true, lastPushAt: now - 30_000, now }), "coalesced");
  assert.equal(chatPushDecision({ recentMessage: true, lastPushAt: now - CHAT_PUSH_WINDOW_MS, now }), "send");
  assert.equal(skipsDailyCap("chatMessage"), true);
  assert.equal(chatPushBody(), "New message");
  assert.equal(chatPushBody().toLowerCase().includes("photo"), false);
  assert.equal(skipsDailyCap("partnerMood"), true);
  assert.equal(skipsDailyCap("planReady"), false);
});

test("a mood push skips the daily cap and still waits six hours", () => {
  assert.equal(SIX_HOUR_DEDUPE_MS, 6 * 60 * 60 * 1000);
  assert.equal(keepsSixHourDedupe("partnerMood"), true);
  assert.equal(keepsSixHourDedupe("planReady"), true);
  assert.equal(keepsSixHourDedupe("inviteAccepted"), true);
  assert.equal(keepsSixHourDedupe("chatMessage"), false);
  assert.equal(keepsSixHourDedupe("weeklyReminder"), false);
  assert.equal(skipsDailyCap("partnerMood"), true);
});
