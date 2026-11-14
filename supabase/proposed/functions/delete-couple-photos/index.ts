// PROPOSED. Do not deploy until 003 is applied. Deploy this function
// before the TestFlight build that calls it.
//
// The app calls leave_couple or delete_my_account first. Those return the
// couple ids they closed. This function then deletes date-photos for those
// ids, and for ids recorded in closed_couples, only when the couple row is
// already gone. A couple that still exists is skipped. SQL must not delete
// storage.objects: protect_objects_delete raises 42501 and does not remove
// the file bytes.
//
// The service role is used for the existence check and the Storage API.
// This file is not deployed.

import { drainPrefix, eligibleIds, isUuid } from "./drain.mjs";

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "method" }, 405);
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !anonKey || !serviceKey) return json({ error: "configuration" }, 500);

  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.toLowerCase().startsWith("bearer ")) return json({ error: "not_authenticated" }, 401);

  let requested: string[] = [];
  try {
    const parsed = await request.json();
    const ids = parsed && typeof parsed === "object" ? parsed.coupleIds : null;
    if (Array.isArray(ids)) requested = ids.filter((id) => typeof id === "string");
  } catch {
    requested = [];
  }

  let recorded: string[] = [];
  try {
    recorded = await closedCoupleIds(supabaseUrl, anonKey, authorization);
  } catch {
    return json({ error: "unavailable" }, 503);
  }

  let existing: string[] = [];
  try {
    existing = await existingCouples(supabaseUrl, serviceKey, [...requested, ...recorded]);
  } catch {
    return json({ error: "unavailable" }, 503);
  }

  const ids = eligibleIds([...requested, ...recorded], existing);
  try {
    let deleted = 0;
    for (const id of ids) {
      const prefixes = [...new Set([id, id.toUpperCase()])];
      for (const prefix of prefixes) {
        deleted += await drainPrefix(
          prefix,
          (value) => listPrefix(supabaseUrl, serviceKey, value),
          (paths) => deletePaths(supabaseUrl, serviceKey, paths),
        );
      }
    }
    if (ids.length > 0) await ack(supabaseUrl, anonKey, authorization, ids);
    return json({ deleted, couples: ids.length }, 200);
  } catch {
    return json({ error: "storage" }, 502);
  }
});

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
  const rows = await response.json();
  if (!Array.isArray(rows)) throw new Error("rpc");
  return rows.filter((row): row is string => typeof row === "string" && isUuid(row));
}

async function existingCouples(url: string, serviceKey: string, candidates: string[]): Promise<string[]> {
  const ids = [...new Set(candidates.filter(isUuid).map((id) => id.toLowerCase()))];
  if (ids.length === 0) return [];
  const filter = ids.join(",");
  const response = await fetch(
    `${url}/rest/v1/couples?id=in.(${filter})&select=id`,
    { headers: { Authorization: `Bearer ${serviceKey}`, apikey: serviceKey } },
  );
  if (!response.ok) throw new Error("couples");
  const rows = await response.json();
  if (!Array.isArray(rows)) throw new Error("couples");
  return rows
    .map((row) => (row && typeof row.id === "string" ? row.id : ""))
    .filter(isUuid);
}

async function listPrefix(url: string, serviceKey: string, prefix: string) {
  const response = await fetch(`${url}/storage/v1/object/list/date-photos`, {
    method: "POST",
    headers: storageHeaders(serviceKey),
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
    headers: storageHeaders(serviceKey),
    body: JSON.stringify({ prefixes: paths }),
  });
  if (!response.ok) throw new Error("storage_delete");
}

async function ack(url: string, anonKey: string, authorization: string, ids: string[]) {
  await fetch(`${url}/rest/v1/rpc/ack_closed_couples`, {
    method: "POST",
    headers: {
      Authorization: authorization,
      apikey: anonKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ p_ids: ids }),
  });
}

function storageHeaders(serviceKey: string): HeadersInit {
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
