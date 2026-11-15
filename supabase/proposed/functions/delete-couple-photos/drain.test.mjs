import assert from "node:assert/strict";
import test from "node:test";
import { ackAccepted, drainPrefix, eligibleIds, jwtRole, settleEach, tooMany } from "./drain.mjs";

const closed = "11111111-1111-4111-8111-111111111111";
const living = "22222222-2222-4222-8222-222222222222";

test("more than 50 couple ids is rejected", () => {
  const ids = Array.from({ length: 51 }, (_, index) => `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`);
  assert.equal(tooMany(ids), true);
  assert.equal(tooMany(ids.slice(0, 50)), false);
  assert.equal(tooMany([]), false);
});

function jwt(claims) {
  const header = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");
  const payload = Buffer.from(JSON.stringify(claims)).toString("base64url");
  return { token: `${header}.${payload}.sig`, payload };
}

test("jwtRole reads the role from a base64url service_role JWT", () => {
  const dash = jwt({ role: "service_role", ref: "+2y?L>F=/<i\"" });
  const under = jwt({ role: "service_role", ref: "x=b+K?+(0Y/F" });
  assert.match(dash.payload, /-/);
  assert.match(under.payload, /_/);
  assert.equal(jwtRole(dash.token), "service_role");
  assert.equal(jwtRole(under.token), "service_role");
  assert.equal(jwtRole(jwt({}).token), "");
});

test("jwtRole does not treat a user JWT or a secret key as the sweep", () => {
  assert.equal(jwtRole(jwt({ role: "authenticated" }).token), "authenticated");
  assert.equal(jwtRole(jwt({ role: 1 }).token), "");
  assert.equal(jwtRole("sb_secret_example"), "");
  assert.equal(jwtRole("not.a.jwt"), "");
  assert.equal(jwtRole(""), "");
});

test("a confirm call counts only when the response succeeded", () => {
  assert.equal(ackAccepted(204), true);
  assert.equal(ackAccepted(200), true);
  assert.equal(ackAccepted(401), false);
  assert.equal(ackAccepted(500), false);
});

test("a living couple is not eligible, even if the caller sends its id", () => {
  const chosen = eligibleIds(
    [closed, living, closed.toUpperCase(), "not-a-uuid", living.toUpperCase()],
    [living],
  );
  assert.deepEqual(chosen, [closed]);
});

test("an unknown id is eligible only because that couple row is gone", () => {
  const gone = "33333333-3333-4333-8333-333333333333";
  assert.deepEqual(eligibleIds([gone], []), [gone]);
  assert.deepEqual(eligibleIds([gone], [gone]), []);
});

test("one failed couple does not stop the sweep from confirming the others", async () => {
  const drained = [];
  const confirmed = [];
  const outcome = await settleEach(["alpha", "stuck", "later"], {
    drain: async (id) => {
      drained.push(id);
      if (id === "stuck") throw new Error("storage");
      return id === "alpha" ? 2 : 1;
    },
    confirm: async (id) => {
      confirmed.push(id);
    },
  });
  assert.deepEqual(drained, ["alpha", "stuck", "later"]);
  assert.deepEqual(confirmed, ["alpha", "later"]);
  assert.deepEqual(outcome.failed, ["stuck"]);
  assert.equal(outcome.deleted, 3);
});

test("a failed confirm leaves that couple and still settles the next one", async () => {
  const confirmed = [];
  const outcome = await settleEach(["first", "second"], {
    drain: async () => 1,
    confirm: async (id) => {
      if (id === "first") throw new Error("ack");
      confirmed.push(id);
    },
  });
  assert.deepEqual(confirmed, ["second"]);
  assert.deepEqual(outcome.failed, ["first"]);
  assert.deepEqual(outcome.confirmed, ["second"]);
  assert.equal(outcome.deleted, 2);
});

test("a folder entry is not deleted and does not keep the loop running", async () => {
  let calls = 0;
  const removed = await drainPrefix(
    closed,
    async () => {
      calls += 1;
      return [{ name: "nested" }];
    },
    async () => {
      throw new Error("should not delete");
    },
  );
  assert.equal(removed, 0);
  assert.equal(calls, 2);
});

test("draining always re-reads the first page, including a file uploaded mid-delete", async () => {
  const names = Array.from({ length: 1001 }, (_, index) => `n${index}.jpg`);
  let raced = false;
  const listedOffsets = [];
  const removed = await drainPrefix(
    closed,
    async () => {
      listedOffsets.push(0);
      const page = names.slice(0, 1000).map((name) => ({ id: name, name }));
      return page;
    },
    async (paths) => {
      for (const path of paths) {
        const name = path.slice(closed.length + 1);
        const index = names.indexOf(name);
        if (index >= 0) names.splice(index, 1);
      }
      if (!raced) {
        raced = true;
        names.push("uploaded-during-close.jpg");
      }
    },
  );
  assert.equal(removed, 1002);
  assert.deepEqual(names, []);
  assert.ok(listedOffsets.length >= 3);
  assert.ok(listedOffsets.every((offset) => offset === 0));
});
