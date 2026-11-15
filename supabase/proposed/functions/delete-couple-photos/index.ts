// DEPLOYED on 2026-11-15. Do not redeploy an older copy. The pg_cron
// sweep in 003 calls this function with {"sweep":true} and the legacy
// service_role JWT from the justus_service_role vault secret.
// SUPABASE_SERVICE_ROLE_KEY may be the newer sb_secret key, which is not
// that JWT. verify_jwt is on, so the gateway checks the signature before
// this code reads the payload role.
//
// A signed-in caller sends the couple ids leave_couple just returned. The
// function also reads closed_couple_ids for that caller. Account deletion
// does not call this function: the user row is already gone, so
// /auth/v1/user rejects the JWT. The sweep covers that path.
// A sweep reads closed_couples_pending and can run after the login is gone.
// Either path deletes date-photos only when public.photo_delete_allowed
// says the couple row is already gone. That function is
// app_private.photo_delete_allowed. More than 50 ids is rejected.
//
// After that couple's objects are gone, its confirm call has to succeed.
// A user confirm is ack_closed_couples. A sweep confirm is ack_swept_couples.
// Each id is drained and confirmed on its own. A failed one stays for the
// next sweep and does not block the rest of the batch.
// SQL must not delete storage.objects: protect_objects_delete raises
// 42501 and does not remove the file bytes.

import { ackAccepted, drainPrefix, eligibleIds, isServiceCaller, isUuid, maxCoupleIds, settleEach, tooMany } from "./drain.mjs";

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "method" }, 405);
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !anonKey || !serviceKey) return json({ error: "configuration" }, 500);

  const authorization = request.headers.get("authorization") ?? "";
  const token = bearer(authorization);
  if (!token) return json({ error: "not_authenticated" }, 401);
  // The env key and the vault JWT differ. The role check covers the JWT
  // the scheduled sweep sends. The gateway already verified its signature.
  const sweep = isServiceCaller(token, serviceKey);

  let requested: string[] = [];
  let sweepBody = false;
  try {
    const parsed = await request.json();
    sweepBody = Boolean(parsed && typeof parsed === "object" && parsed.sweep === true);
    const ids = parsed && typeof parsed === "object" ? parsed.coupleIds : null;
    if (Array.isArray(ids)) requested = ids.filter((id) => typeof id === "string");
  } catch {
    requested = [];
  }
  if (tooMany(requested)) return json({ error: "too_many" }, 400);
  if (sweep && !sweepBody) return json({ error: "sweep" }, 400);
  if (!sweep && sweepBody) return json({ error: "forbidden" }, 403);

  if (!sweep) {
    const user = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: { Authorization: authorization, apikey: anonKey },
    });
    if (!user.ok) return json({ error: "not_authenticated" }, 401);
  }

  let recorded: string[] = [];
  try {
    recorded = sweep
      ? await pendingIds(supabaseUrl, serviceKey)
      : await closedCoupleIds(supabaseUrl, anonKey, authorization);
  } catch {
    return json({ error: "unavailable" }, 503);
  }
  const candidates = cappedIds(requested, recorded);
  let denied: string[] = [];
  try {
    denied = await deniedIds(supabaseUrl, serviceKey, candidates);
  } catch {
    return json({ error: "unavailable" }, 503);
  }

  const ids = eligibleIds(candidates, denied);
  const outcome = await settleEach(ids, {
    drain: (id) => drainCouple(supabaseUrl, serviceKey, id),
    confirm: (id) => sweep
      ? ackSwept(supabaseUrl, serviceKey, [id])
      : ackClosed(supabaseUrl, anonKey, authorization, [id]),
  });
  if (outcome.failed.length > 0) {
    return json({ error: "storage", deleted: outcome.deleted, couples: outcome.confirmed.length }, 502);
  }
  return json({ deleted: outcome.deleted, couples: outcome.confirmed.length }, 200);
});

async function drainCouple(url: string, serviceKey: string, id: string): Promise<number> {
  let deleted = 0;
  const prefixes = [...new Set([id, id.toUpperCase()])];
  for (const prefix of prefixes) {
    deleted += await drainPrefix(
      prefix,
      (value) => listPrefix(url, serviceKey, value),
      (paths) => deletePaths(url, serviceKey, paths),
    );
  }
  return deleted;
}

function cappedIds(requested: string[], recorded: string[]): string[] {
  const chosen: string[] = [];
  const seen = new Set<string>();
  for (const id of [...requested, ...recorded]) {
    if (!isUuid(id)) continue;
    const key = id.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    chosen.push(id);
    if (chosen.length >= maxCoupleIds) break;
  }
  return chosen;
}

function bearer(authorization: string): string {
  const match = /^bearer\s+(\S+)/i.exec(authorization.trim());
  return match ? match[1] : "";
}

async function closedCoupleIds(url: string, anonKey: string, authorization: string): Promise<string[]> {
  const response = await fetch(`${url}/rest/v1/rpc/closed_couple_ids`, {
    method: "POST",
    headers: {
      Authorization: authorization,
      apikey: anonKey,
      "Content-Type": "application/json",
    },
    body: "{}",
  });
  if (!response.ok) throw new Error("rpc");
  return uuidRows(await response.json());
}

async function pendingIds(url: string, serviceKey: string): Promise<string[]> {
  const response = await fetch(`${url}/rest/v1/rpc/closed_couples_pending`, {
    method: "POST",
    headers: serviceHeaders(serviceKey),
    body: JSON.stringify({ p_limit: maxCoupleIds }),
  });
  if (!response.ok) throw new Error("pending");
  return uuidRows(await response.json());
}

async function deniedIds(url: string, serviceKey: string, candidates: string[]): Promise<string[]> {
  const unique = [...new Set(candidates.filter(isUuid).map((id) => id.toLowerCase()))];
  const denied: string[] = [];
  for (const id of unique) {
    const response = await fetch(`${url}/rest/v1/rpc/photo_delete_allowed`, {
      method: "POST",
      headers: serviceHeaders(serviceKey),
      body: JSON.stringify({ p_couple: id }),
    });
    if (!response.ok) throw new Error("allowed");
    if (await response.json() !== true) denied.push(id);
  }
  return denied;
}

function uuidRows(rows: unknown): string[] {
  if (!Array.isArray(rows)) throw new Error("rpc");
  return rows.filter((row): row is string => typeof row === "string" && isUuid(row));
}

async function listPrefix(url: string, serviceKey: string, prefix: string) {
  const response = await fetch(`${url}/storage/v1/object/list/date-photos`, {
    method: "POST",
    headers: serviceHeaders(serviceKey),
    body: JSON.stringify({ prefix: `${prefix}/`, limit: 1000, offset: 0 }),
  });
  if (response.status === 404) return [];
  if (!response.ok) throw new Error("storage_list");
  return response.json();
}

async function deletePaths(url: string, serviceKey: string, paths: string[]) {
  if (paths.length === 0) return;
  const response = await fetch(`${url}/storage/v1/object/date-photos`, {
    method: "DELETE",
    headers: serviceHeaders(serviceKey),
    body: JSON.stringify({ prefixes: paths }),
  });
  if (!response.ok) throw new Error("storage_delete");
}

async function ackClosed(url: string, anonKey: string, authorization: string, ids: string[]) {
  const response = await fetch(`${url}/rest/v1/rpc/ack_closed_couples`, {
    method: "POST",
    headers: {
      Authorization: authorization,
      apikey: anonKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ p_ids: ids }),
  });
  if (!ackAccepted(response.status)) throw new Error("ack");
}

async function ackSwept(url: string, serviceKey: string, ids: string[]) {
  const response = await fetch(`${url}/rest/v1/rpc/ack_swept_couples`, {
    method: "POST",
    headers: serviceHeaders(serviceKey),
    body: JSON.stringify({ p_ids: ids }),
  });
  if (!ackAccepted(response.status)) throw new Error("ack");
}

function serviceHeaders(serviceKey: string): HeadersInit {
  return {
    Authorization: `Bearer ${serviceKey}`,
    apikey: serviceKey,
    "Content-Type": "application/json",
  };
}

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
