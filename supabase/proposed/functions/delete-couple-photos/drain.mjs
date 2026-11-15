// Pure helpers for delete-couple-photos. The edge function imports these.
// node --test drain.test.mjs covers which ids may be deleted and the
// list loop. The loop always reads offset 0 so a delete cannot skip the
// files that shift into the first page.

export const maxCoupleIds = 50;

export function tooMany(ids) {
  return Array.isArray(ids) && ids.length > maxCoupleIds;
}

export function isUuid(value) {
  return typeof value === "string"
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

// A candidate is eligible only when it is a uuid and that couple row is
// already gone. A couple the caller merely touched, or one that still
// exists, is left alone.
export function eligibleIds(candidates, existingIds) {
  const existing = new Set([...existingIds].map((id) => String(id).toLowerCase()));
  const chosen = [];
  const seen = new Set();
  for (const candidate of candidates) {
    if (!isUuid(candidate)) continue;
    const id = candidate.toLowerCase();
    if (seen.has(id) || existing.has(id)) continue;
    seen.add(id);
    chosen.push(id);
  }
  return chosen;
}

export function objectPaths(prefix, files) {
  if (!Array.isArray(files)) return [];
  return files
    .filter((file) => file && file.id && typeof file.name === "string" && file.name.length > 0)
    .map((file) => `${prefix}/${file.name}`);
}

// list(prefix) must return the first page only (offset 0). remove(paths)
// deletes those objects. Two empty reads in a row cover a file that is
// uploaded after the couple row is gone and lands between passes.
export function ackAccepted(status) {
  return status >= 200 && status < 300;
}

export { isServiceCaller, jwtRole } from "../_shared/jwt-role.mjs";

// One couple at a time. A drain or confirm failure is recorded and the
// next id still runs, so one stuck folder cannot pin the whole sweep.
export async function settleEach(ids, work) {
  let deleted = 0;
  const confirmed = [];
  const failed = [];
  for (const id of ids) {
    try {
      deleted += await work.drain(id);
      await work.confirm(id);
      confirmed.push(id);
    } catch {
      failed.push(id);
    }
  }
  return { deleted, confirmed, failed };
}

export async function drainPrefix(prefix, list, remove) {
  let removed = 0;
  let emptyReads = 0;
  for (let guard = 0; emptyReads < 2 && guard < 40; guard += 1) {
    const files = await list(prefix);
    const paths = objectPaths(prefix, files);
    if (paths.length === 0) {
      emptyReads += 1;
      continue;
    }
    await remove(paths);
    removed += paths.length;
    emptyReads = 0;
  }
  return removed;
}
