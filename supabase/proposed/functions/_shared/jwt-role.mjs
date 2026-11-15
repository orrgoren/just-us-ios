// Shared by delete-couple-photos and send-push. verify_jwt is on for both,
// so the gateway has already checked the signature. The payload role then
// tells a legacy service_role JWT from a user JWT. The function env may
// hold the newer sb_secret key, which is not a JWT and does not equal the
// legacy key stored in the justus_service_role vault secret.

export function jwtRole(token) {
  if (typeof token !== "string") return "";
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
  return typeof token === "string" && token.length > 0 && (token === serviceKey || jwtRole(token) === "service_role");
}

function base64UrlDecode(value) {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  return atob(padded);
}
