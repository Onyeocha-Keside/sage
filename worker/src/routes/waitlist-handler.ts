import type { Env } from "../bindings";
import { checkRateLimit } from "../security/request-guards";
import { readJsonObject, requestBodyErrorResponse } from "../http/request-body";

// Websites allowed to post waitlist signups. "null" is a page opened
// straight from disk (file://), which is handy while previewing locally.
const WAITLIST_ALLOWED_ORIGINS = [
  "https://sage.kesideonyeocha.com",
  "https://kesideonyeocha.com",
  "https://www.kesideonyeocha.com",
  "null",
];
const WAITLIST_ALLOWED_ORIGIN_PATTERNS = [/^http:\/\/localhost(:\d+)?$/, /^https:\/\/([a-z0-9-]+\.)?sage-landing-4zo\.pages\.dev$/];
const WAITLIST_PLATFORMS = ["mac", "windows"];

function waitlistCorsHeaders(request: Request): Record<string, string> {
  const requestOrigin = request.headers.get("origin") ?? "";
  const isAllowedOrigin =
    WAITLIST_ALLOWED_ORIGINS.includes(requestOrigin) ||
    WAITLIST_ALLOWED_ORIGIN_PATTERNS.some((originPattern) => originPattern.test(requestOrigin));
  if (!isAllowedOrigin) return {};
  return {
    "access-control-allow-origin": requestOrigin,
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-allow-headers": "content-type",
    "access-control-max-age": "86400",
    vary: "origin",
  };
}

export async function handleWaitlist(request: Request, env: Env): Promise<Response> {
  const corsHeaders = waitlistCorsHeaders(request);
  const respond = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json", ...corsHeaders },
    });

  // Browsers ask permission (a "preflight") before posting JSON across sites.
  if (request.method === "OPTIONS") {
    return new Response(null, { status: corsHeaders["access-control-allow-origin"] ? 204 : 403, headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return respond(405, { error: "Method not allowed" });
  }
  if (!corsHeaders["access-control-allow-origin"]) {
    return respond(403, { error: "Signups are only accepted from the Sage website" });
  }
  if (!env.WAITLIST) {
    return respond(500, { error: "Waitlist storage isn't configured" });
  }

  const rateLimitFailure = await checkRateLimit(request, env);
  if (rateLimitFailure) {
    return respond(rateLimitFailure.status, { error: rateLimitFailure.status === 429
      ? "Too many signups from here, try again in a minute"
      : "Signups are temporarily unavailable, try again shortly" });
  }

  let signup: { email?: unknown; platform?: unknown; website?: unknown };
  try {
    signup = await readJsonObject(request, 16 * 1024);
  } catch (error) {
    return requestBodyErrorResponse(error, corsHeaders);
  }

  // The hidden "website" field is only ever filled in by bots. Pretend it
  // worked so they don't learn to skip it.
  if (typeof signup.website === "string" && signup.website.trim() !== "") {
    return respond(200, { ok: true });
  }

  const email = typeof signup.email === "string" ? signup.email.trim().toLowerCase() : "";
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return respond(400, { error: "Please enter a valid email address" });
  }
  const platform = typeof signup.platform === "string" && WAITLIST_PLATFORMS.includes(signup.platform)
    ? signup.platform
    : "mac";

  // One entry per email. Signing up twice just updates the platform.
  const signupKey = `signup:${email}`;
  const existingSignup = await env.WAITLIST.get(signupKey);
  const firstSignedUpAt = existingSignup ? JSON.parse(existingSignup).signedUpAt : new Date().toISOString();
  await env.WAITLIST.put(signupKey, JSON.stringify({
    email,
    platform,
    signedUpAt: firstSignedUpAt,
    updatedAt: new Date().toISOString(),
    origin: request.headers.get("origin"),
  }));

  return respond(200, { ok: true });
}
