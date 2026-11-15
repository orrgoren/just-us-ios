import assert from "node:assert/strict";
import test from "node:test";
import { APNS_JWT_TTL_MS, flushDue, freshApnsToken, isServiceCaller } from "./push.mjs";

function jwt(claims) {
  const header = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");
  const payload = Buffer.from(JSON.stringify(claims)).toString("base64url");
  return `${header}.${payload}.sig`;
}

test("a legacy service_role JWT is the flush caller when the env key is sb_secret", () => {
  const vault = jwt({ role: "service_role", ref: "vowmukhhnfhtnjlswkun" });
  assert.equal(isServiceCaller(vault, "sb_secret_example"), true);
  assert.equal(isServiceCaller("sb_secret_example", "sb_secret_example"), true);
  assert.equal(isServiceCaller(jwt({ role: "authenticated" }), "sb_secret_example"), false);
  assert.equal(isServiceCaller("", "sb_secret_example"), false);
});

test("a failed send stays queued and the next row still sends", async () => {
  const calls = [];
  const outcome = await flushDue([{ id: "failed" }, { id: "ok" }], {
    deliver: async (row) => {
      calls.push(`deliver:${row.id}`);
      if (row.id === "failed") throw new Error("apns");
      return { decision: "send" };
    },
    remove: async (row) => {
      calls.push(`remove:${row.id}`);
    },
  });
  assert.deepEqual(calls, ["deliver:failed", "deliver:ok", "remove:ok"]);
  assert.deepEqual(outcome.kept, ["failed"]);
  assert.equal(outcome.sent, 1);
});

test("an apns error or a suppress does not drop the queued push", async () => {
  const removed = [];
  const outcome = await flushDue([{ id: "apns" }, { id: "quiet" }], {
    deliver: async (row) => row.id === "apns" ? { error: "apns" } : { decision: "suppress", reason: "preference" },
    remove: async (row) => {
      removed.push(row.id);
    },
  });
  assert.deepEqual(removed, []);
  assert.deepEqual(outcome.kept, ["apns", "quiet"]);
  assert.equal(outcome.sent, 0);
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
