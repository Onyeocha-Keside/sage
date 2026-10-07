import { checkInputTokenLimit } from "../chat/input-token-limit";
import { reserveProviderBudget } from "../access/access-policy";
import type { Env } from "../bindings";
import { ConversationMode, systemPromptForMode } from "../prompts";
import { CLAUDE_MODEL, CLAUDE_EFFORT, MAX_OUTPUT_TOKENS_BY_MODE, MAXIMUM_REQUEST_BODY_BYTES } from "../api-limits";
import { jsonResponse } from "../http/responses";
import { readJsonObject, requestBodyErrorResponse } from "../http/request-body";
import { ChatMessage, validateMessages, sanitizeMessages, withConversationHistoryCached } from "../chat/conversation-validation";

interface ChatRequestBody {
  mode?: unknown;
  messages?: unknown;
}

export async function handleChat(request: Request, env: Env): Promise<Response> {
  if (!env.ANTHROPIC_API_KEY) {
    return jsonResponse(500, { error: "Worker is missing ANTHROPIC_API_KEY" });
  }

  let requestBody: ChatRequestBody;
  try {
    requestBody = await readJsonObject(request, MAXIMUM_REQUEST_BODY_BYTES);
  } catch (error) {
    return requestBodyErrorResponse(error);
  }

  if (requestBody.mode !== undefined && requestBody.mode !== "companion" && requestBody.mode !== "onboarding") {
    return jsonResponse(400, { error: "Unsupported conversation mode" });
  }

  const mode: ConversationMode = requestBody.mode === "onboarding" ? "onboarding" : "companion";

  const messagesValidationError = validateMessages(requestBody.messages);
  if (messagesValidationError) {
    return jsonResponse(400, { error: messagesValidationError });
  }

  const anthropicRequestBody = {
    model: CLAUDE_MODEL,
    max_tokens: MAX_OUTPUT_TOKENS_BY_MODE[mode],
    stream: true,
    // Cache the system prompt so Claude doesn't re-read it on every request.
    system: [{ type: "text", text: systemPromptForMode(mode), cache_control: { type: "ephemeral" } }],
    messages: withConversationHistoryCached(sanitizeMessages(requestBody.messages as ChatMessage[])),
    output_config: { effort: CLAUDE_EFFORT },
    // No provider-controlled fallback: its price would escape our reservation policy.

  };

  const inputFailure = await checkInputTokenLimit(request, env, anthropicRequestBody);
  if (inputFailure) return inputFailure;

  let budgetFailureResponse: Response | null = null;
  const sendToAnthropic = async () => {
    request.signal.throwIfAborted();
    const budgetFailure = await reserveProviderBudget(request, env, "chat");
    if (budgetFailure) { budgetFailureResponse = budgetFailure; return budgetFailure; }
    return fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": env.ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "server-side-fallback-2026-07-01",
        "content-type": "application/json",
      },
      body: JSON.stringify(anthropicRequestBody),
      signal: AbortSignal.any([request.signal, AbortSignal.timeout(120_000)]),
    });
  };

  // A dropped connection (the fetch itself throwing, not an HTTP error)
  // is worth one quick retry before giving up on the user's question.
  let anthropicResponse: Response;
  try {
    anthropicResponse = await sendToAnthropic();
  } catch (firstAttemptError) {
    if (request.signal.aborted) throw firstAttemptError;
    console.error("[/chat] Anthropic connection failed, retrying once");
    anthropicResponse = await sendToAnthropic();
  }

  if (budgetFailureResponse) return budgetFailureResponse;

  if (!anthropicResponse.ok) {
    await anthropicResponse.body?.cancel();
    console.error(`[/chat] Anthropic error ${anthropicResponse.status}`);
    return jsonResponse(anthropicResponse.status, {
      error: `Claude request failed (${anthropicResponse.status})`,
    });
  }

  return new Response(anthropicResponse.body, {
    status: 200,
    headers: {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}
