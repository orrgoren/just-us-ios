// PROPOSED. Do not deploy until Tom verifies 003 and 004.
//
// Deletes date-photos through the Storage API. SQL must not delete
// storage.objects: the live protect_objects_delete trigger raises 42501
// and a direct delete does not remove the file bytes.
//
// The caller is the signed-in member. Couple ids come from
// public.couples_touching_me(), not from the request body. The service
// role is used only for the Storage API. This file is not deployed.

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "method" }, 405);
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !anonKey || !serviceKey) return json({ error: "configuration" }, 500);

  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.toLowerCase().startsWith("bearer ")) return json({ error: "not_authenticated" }, 401);

  let coupleIds: string[];
  try {
    coupleIds = await couplesTouchingCaller(supabaseUrl, anonKey, authorization);
  } catch {
    return json({ error: "unavailable" }, 503);
  }

  try {
    let deleted = 0;
    const seen = new Set<string>();
    for (const id of coupleIds) {
      if (!isUuid(id)) continue;
      for (const prefix of [id.toLowerCase(), id.toUpperCase()]) {
        if (seen.has(prefix)) continue;
        seen.add(prefix);
        deleted += await removePrefix(supabaseUrl, serviceKey, prefix);
      }
    }
    return json({ deleted }, 200);
  } catch {
    return json({ error: "storage" }, 502);
  }
});

async function couplesTouchingCaller(url: string, anonKey: string, authorization: string): Promise<string[]> {
  const response = await fetch(`${url}/rest/v1/rpc/couples_touching_me`, {
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
  return rows.filter((row): row is string => typeof row === "string");
}

async function removePrefix(url: string, serviceKey: string, prefix: string): Promise<number> {
  let removed = 0;
  for (let offset = 0; offset < 10000; offset += 1000) {
    const listed = await fetch(`${url}/storage/v1/object/list/date-photos`, {
      method: "POST",
      headers: storageHeaders(serviceKey),
      body: JSON.stringify({ prefix: `${prefix}/`, limit: 1000, offset }),
    });
    if (listed.status === 404) return removed;
    if (!listed.ok) throw new Error("storage_list");
    const files = await listed.json();
    if (!Array.isArray(files) || files.length === 0) break;
    const prefixes = files
      .filter((file) => file && typeof file.name === "string" && file.name.length > 0 && file.id)
      .map((file) => `${prefix}/${file.name}`);
    if (prefixes.length === 0) break;
    const deleted = await fetch(`${url}/storage/v1/object/date-photos`, {
      method: "DELETE",
      headers: storageHeaders(serviceKey),
      body: JSON.stringify({ prefixes }),
    });
    if (!deleted.ok) throw new Error("storage_delete");
    removed += prefixes.length;
    if (files.length < 1000) break;
  }
  return removed;
}

function storageHeaders(serviceKey: string): HeadersInit {
  return {
    Authorization: `Bearer ${serviceKey}`,
    apikey: serviceKey,
    "Content-Type": "application/json",
  };
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
