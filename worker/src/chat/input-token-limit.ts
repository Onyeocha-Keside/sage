import type { Env } from "../bindings";
import { jsonResponse } from "../http/responses";
import { CLAUDE_MODEL } from "../api-limits";

export const MAXIMUM_INPUT_TOKENS = 100_000;

/** The free count endpoint bounds image and text input before paid inference.
 * Counting is an estimate, so keep headroom in the fixed per-attempt reservation.
 */
export async function checkInputTokenLimit(request: Request, env: Env, payload: { system: unknown; messages: unknown }): Promise<Response | null> {
  const response = await fetch("https://api.anthropic.com/v1/messages/count_tokens", {
    method: "POST",
    headers: { "x-api-key": env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model: CLAUDE_MODEL, system: payload.system, messages: payload.messages }),
    signal: AbortSignal.any([request.signal, AbortSignal.timeout(15_000)]),
  });
  if (!response.ok) {
    await response.body?.cancel();
    return jsonResponse(503, { error: "Input size checking is unavailable" });
  }
  const result = await response.json() as { input_tokens?: unknown };
  if (typeof result?.input_tokens !== "number" || !Number.isSafeInteger(result.input_tokens) || result.input_tokens < 0) {
    return jsonResponse(503, { error: "Input size checking is unavailable" });
  }
  if (result.input_tokens > MAXIMUM_INPUT_TOKENS) return jsonResponse(413, { error: "Conversation exceeds Sage's input allowance; start a shorter conversation" });
  return null;
}
