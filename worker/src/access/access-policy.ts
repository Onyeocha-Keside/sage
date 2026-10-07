import type { Env } from "../bindings";
import { jsonResponse } from "../http/responses";
import { constantTimeEquals } from "../security/request-guards";
import { readJsonObject, requestBodyErrorResponse } from "../http/request-body";

export async function tokenHash(token: string): Promise<string> {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)));
  return Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
}

export async function ledgerRequest(env: Env, operation: string, body: Record<string, unknown>): Promise<Response> {
  if (!env.ACCESS_LEDGER) return jsonResponse(503, { error: "Account service is unavailable" });
  try {
    return await env.ACCESS_LEDGER.get(env.ACCESS_LEDGER.idFromName("sage-global-access-v1")).fetch(
      new Request(`https://ledger.internal/${operation}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) })
    );
  } catch {
    return jsonResponse(503, { error: "Account service is unavailable" });
  }
}

function bearerToken(request: Request): string | null {
  const authorization = request.headers.get("authorization") ?? "";
  const match = /^Bearer (sage_[a-f0-9]{64})$/.exec(authorization);
  return match?.[1] ?? null;
}

export async function checkIndividualAccess(request: Request, env: Env): Promise<Response | null> {
  const token = bearerToken(request);
  if (!token) return jsonResponse(401, { error: "Enter your individual Sage access token" });
  const response = await ledgerRequest(env, "authorize", { tokenHash: await tokenHash(token) });
  if (!response.ok) return response;
  return null;
}

export async function reserveProviderBudget(request: Request, env: Env, provider: "chat" | "tts"): Promise<Response | null> {
  const token = bearerToken(request);
  if (!token) return jsonResponse(401, { error: "Missing access token" });
  const charge = Number(provider === "chat" ? env.CHAT_RESERVATION_MICRO_USD : env.TTS_RESERVATION_MICRO_USD);
  // Floors include current provider prices plus headroom. Review them whenever
  // model, max_tokens, caching policy, input cap, or voice pricing changes.
  const minimumCharge = provider === "chat" ? 350_000 : 100_000;
  if (!Number.isSafeInteger(charge) || charge < minimumCharge) {
    return jsonResponse(503, { error: "Budget reservation policy is unsafe or unavailable" });
  }
  const response = await ledgerRequest(env, "reserve", {
    tokenHash: await tokenHash(token), charge,
    globalMonthlyLimit: Number(env.GLOBAL_MONTHLY_BUDGET_MICRO_USD),
    globalDailyLimit: Number(env.GLOBAL_DAILY_BUDGET_MICRO_USD),
  });
  return response.ok ? null : response;
}

/** Admin credentials never ship in the Mac app; no public token issuance. */
export async function handleAccountAdmin(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") return jsonResponse(405, { error: "Method not allowed" });
  if (!env.SAGE_ADMIN_KEY) return jsonResponse(503, { error: "Account administration is unavailable" });
  if (!await constantTimeEquals(request.headers.get("x-sage-admin-key") ?? "", env.SAGE_ADMIN_KEY)) return jsonResponse(401, { error: "Unauthorized" });
  let body: Record<string, unknown>;
  try { body = await readJsonObject(request, 4096); }
  catch (error) { return requestBodyErrorResponse(error); }
  const path = new URL(request.url).pathname;
  if (path === "/admin/accounts/revoke") return ledgerRequest(env, "revoke", { accountID: body.accountID });
  if (path !== "/admin/accounts/provision") return jsonResponse(404, { error: "Unknown admin operation" });
  const randomBytes = crypto.getRandomValues(new Uint8Array(32));
  const token = "sage_" + Array.from(randomBytes, byte => byte.toString(16).padStart(2, "0")).join("");
  const response = await ledgerRequest(env, "provision", { accountID: body.accountID, monthlyLimit: body.monthlyLimitMicroUSD, tokenHash: await tokenHash(token) });
  if (!response.ok) return response;
  return jsonResponse(200, { accountID: body.accountID, accessToken: token }, { "cache-control": "no-store" });
}
