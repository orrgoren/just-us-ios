// Shared by delete-couple-photos and send-push. verify_jwt is pinned on in
// supabase/config.toml, so the gateway checks the signature before this
// runs. The payload role then tells a legacy service_role JWT from a user
// JWT. The function env may hold the newer sb_secret key, which is not a
// JWT and does not equal the legacy key in the justus_service_role vault
// secret. A token whose alg is none, or missing, is rejected here as well,
// so a forged payload does not become a sweep or a flush if that pin is off.

const COMPARE_WIDTH = 2048;

export function jwtRole(token) {
  if (typeof token !== "string") return "";
  const alg = jwtAlg(token).toLowerCase();
  if (!alg || alg === "none") return "";
  const payload = token.split(".")[1];
  if (!payload) return "";
  try {
    const claims = JSON.parse(base64UrlDecode(payload));
    return typeof claims.role === "string" ? claims.role : "";
  } catch {
    return "";
  }
}

export function isServiceCaller(token, serviceKey) {
  if (typeof token !== "string" || token.length === 0) return false;
  if (typeof serviceKey === "string" && constantTimeEqual(token, serviceKey)) return true;
  return jwtRole(token) === "service_role";
}

function jwtAlg(token) {
  const encoded = token.split(".")[0];
  if (!encoded || token.split(".").length < 3) return "";
  try {
    const header = JSON.parse(base64UrlDecode(encoded));
    return typeof header.alg === "string" ? header.alg : "";
  } catch {
    return "";
  }
}

function constantTimeEqual(left, right) {
  const a = new TextEncoder().encode(left);
  const b = new TextEncoder().encode(right);
  let diff = a.length === b.length ? 0 : 1;
  for (let index = 0; index < COMPARE_WIDTH; index += 1) {
    const leftByte = index < a.length ? a[index] : 0;
    const rightByte = index < b.length ? b[index] : 0;
    diff |= leftByte ^ rightByte;
  }
  if (a.length > COMPARE_WIDTH || b.length > COMPARE_WIDTH) diff |= 1;
  return diff === 0;
}

function base64UrlDecode(value) {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  return atob(padded);
}
