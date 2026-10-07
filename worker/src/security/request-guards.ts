import type { Env } from "../bindings";
import { jsonResponse } from "../http/responses";

export async function checkRateLimit(request: Request, env: Env): Promise<Response | null> {
  // Local development may omit the binding. A public API must not silently
  // become unlimited when its billing guard is missing or unavailable.
  if (!env.RATE_LIMITER) {
    const hostname = new URL(request.url).hostname;
    if (["localhost", "127.0.0.1", "[::1]"].includes(hostname)) return null;
    return jsonResponse(503, { error: "Request limiting is unavailable" });
  }

  const callerIPAddress = request.headers.get("cf-connecting-ip") ?? "unknown";
  try {
    const rateLimitResult = await env.RATE_LIMITER.limit({ key: callerIPAddress });
    if (!rateLimitResult.success) {
      return jsonResponse(429, { error: "Too many requests, slow down a little" });
    }
  } catch (rateLimiterError) {
    console.error("[rate limit] limiter unavailable");
    return jsonResponse(503, { error: "Request limiting is unavailable" });
  }
  return null;
}

/** Compares two strings without leaking how many leading characters matched. */
export async function constantTimeEquals(providedValue: string, expectedValue: string): Promise<boolean> {
  const textEncoder = new TextEncoder();
  // Hash both sides first so the comparison always runs on equal-length input.
  const [providedDigest, expectedDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", textEncoder.encode(providedValue)),
    crypto.subtle.digest("SHA-256", textEncoder.encode(expectedValue)),
  ]);
  const providedBytes = new Uint8Array(providedDigest);
  const expectedBytes = new Uint8Array(expectedDigest);
  let accumulatedDifference = 0;
  for (let byteIndex = 0; byteIndex < expectedBytes.length; byteIndex++) {
    accumulatedDifference |= providedBytes[byteIndex] ^ expectedBytes[byteIndex];
  }
  return accumulatedDifference === 0;
}
