import assert from "node:assert/strict";
import test from "node:test";
import { jwtRole } from "../_shared/jwt-role.mjs";
import {
  APNS_JWT_TTL_MS,
  MAX_FLUSH_ATTEMPTS,
  dropDeviceToken,
  flushDue,
  freshApnsToken,
  isServiceCaller,
  orderedDue,
  providerTokenRejected,
  retryableApns,
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

test("a quiet-hours defer moves the same row", async () => {
  const removed = [];
  const moved = [];
  await flushDue([{ id: "quiet", attempts: 1 }], {
    deliver: async () => ({ decision: "defer", not_before: "2026-11-16T06:00:00Z" }),
    remove: async (row) => {
      removed.push(row.id);
    },
    reschedule: async (row, notBefore) => {
      moved.push([row.id, notBefore]);
    },
  });
  assert.deepEqual(removed, []);
  assert.deepEqual(moved, [["quiet", "2026-11-16T06:00:00Z"]]);
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

test("an APNs token is reused for 50 minutes", () => {
  assert.equal(APNS_JWT_TTL_MS, 50 * 60 * 1000);
  const mintedAt = Date.parse("2026-11-15T00:00:00Z");
  const cached = { token: "provider-jwt", mintedAt };
  assert.equal(freshApnsToken(cached, mintedAt + APNS_JWT_TTL_MS - 1), "provider-jwt");
  assert.equal(freshApnsToken(cached, mintedAt + APNS_JWT_TTL_MS), null);
  assert.equal(freshApnsToken(null, mintedAt), null);
  assert.equal(freshApnsToken({ token: "", mintedAt }, mintedAt), null);
});
