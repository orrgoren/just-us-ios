import assert from "node:assert/strict";
import test from "node:test";
import { drainPrefix, eligibleIds } from "./drain.mjs";

const closed = "11111111-1111-4111-8111-111111111111";
const living = "22222222-2222-4222-8222-222222222222";

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
