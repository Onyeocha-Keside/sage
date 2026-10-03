/**
 * Sage API Worker
 *
 * The Mac app never talks to Anthropic or ElevenLabs directly. It talks to
 * this Worker, which holds the real API keys as Cloudflare secrets.
 *
 * This Worker is deliberately NOT an open proxy:
 *   - Every request must carry the app key (x-sage-app-key header).
 *   - The model, token limits, and system prompts are fixed here, so a
 *     leaked app key can only be used to talk to "Sage", nothing else.
 *   - Each IP address is rate limited.
 *
 * Routes:
 *   GET  /health  → quick check that the Worker is up and configured
 *   POST /chat    → Claude (streaming SSE), body: { mode, messages }
 *   POST /tts     → ElevenLabs text-to-speech, body: { text }
 *   POST /waitlist → landing-page signup, body: { email, platform }
 *                    (public, no app key; limited to the website's origins)
 */

import { ConversationMode, systemPromptForMode } from "./prompts";

interface RateLimitBinding {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

interface KeyValueBinding {
  get(key: string): Promise<string | null>;
  put(key: string, value: string): Promise<void>;
}

interface Env {
  ANTHROPIC_API_KEY: string;
  SAGE_APP_KEY: string;
  ELEVENLABS_API_KEY?: string;
  ELEVENLABS_VOICE_ID?: string;
  RATE_LIMITER?: RateLimitBinding;
  WAITLIST?: KeyValueBinding;
}

// The model Sage uses. Sonnet 5.5 is fast, sharp at reading screenshots,
// and cheaper per token than older Sonnets.
const CLAUDE_MODEL = "claude-sonnet-5-5";

// Low effort keeps thinking short so Sage starts talking quickly.
const CLAUDE_EFFORT = "low";

// Thinking counts toward max_tokens, so leave headroom above the spoken reply.
const MAX_OUTPUT_TOKENS_BY_MODE: Record<ConversationMode, number> = {
  companion: 2048,
  onboarding: 512,
};

const MAXIMUM_REQUEST_BODY_BYTES = 15 * 1024 * 1024;
const MAXIMUM_MESSAGES_PER_REQUEST = 41; // 20 past exchanges + the new question
const MAXIMUM_IMAGES_PER_REQUEST = 4;
const MAXIMUM_TTS_CHARACTERS = 1000;
const ELEVENLABS_MODEL = "eleven_flash_v2_5";

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

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    try {
      // The waitlist is called from the public website, so it skips the app
      // key and handles its own CORS and validation.
      if (url.pathname === "/waitlist") {
        return await handleWaitlist(request, env);
      }

      if (request.method === "GET" && url.pathname === "/health") {
        return jsonResponse(200, {
          ok: true,
          claudeConfigured: Boolean(env.ANTHROPIC_API_KEY),
          appKeyConfigured: Boolean(env.SAGE_APP_KEY),
          elevenLabsConfigured: Boolean(env.ELEVENLABS_API_KEY && env.ELEVENLABS_VOICE_ID),
        });
      }

      if (request.method !== "POST") {
        return jsonResponse(405, { error: "Method not allowed" });
      }

      if (url.pathname !== "/chat" && url.pathname !== "/tts") {
        return jsonResponse(404, { error: "Not found" });
      }

      const authenticationFailure = await checkAppKey(request, env);
      if (authenticationFailure) return authenticationFailure;

      const rateLimitFailure = await checkRateLimit(request, env);
      if (rateLimitFailure) return rateLimitFailure;

      const declaredContentLength = Number(request.headers.get("content-length") ?? "0");
      if (declaredContentLength > MAXIMUM_REQUEST_BODY_BYTES) {
        return jsonResponse(413, { error: "Request too large" });
      }

      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }
      return await handleTextToSpeech(request, env);
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      // Include the error text so the app's log shows what actually broke.
      // It never contains secrets; it's things like "Network connection lost".
      return jsonResponse(500, { error: "Internal error", detail: String(error) });
    }
  },
};

// MARK: - Guards

async function checkAppKey(request: Request, env: Env): Promise<Response | null> {
  if (!env.SAGE_APP_KEY) {
    console.error("SAGE_APP_KEY secret is not set");
    return jsonResponse(500, { error: "Worker is missing SAGE_APP_KEY" });
  }

  const providedAppKey = request.headers.get("x-sage-app-key") ?? "";
  const isAppKeyValid = await constantTimeEquals(providedAppKey, env.SAGE_APP_KEY);
  if (!isAppKeyValid) {
    return jsonResponse(401, { error: "Invalid app key" });
  }
  return null;
}

async function checkRateLimit(request: Request, env: Env): Promise<Response | null> {
  // The rate limiter binding is optional so `wrangler dev` works even
  // when it isn't available locally.
  if (!env.RATE_LIMITER) return null;

  const callerIPAddress = request.headers.get("cf-connecting-ip") ?? "unknown";
  try {
    const rateLimitResult = await env.RATE_LIMITER.limit({ key: callerIPAddress });
    if (!rateLimitResult.success) {
      return jsonResponse(429, { error: "Too many requests, slow down a little" });
    }
  } catch (rateLimiterError) {
    // The rate limiter occasionally throws a transient "internal error"
    // (seen in `wrangler dev`). Don't fail the user's question over it.
    console.error("[rate limit] limiter unavailable, allowing request:", rateLimiterError);
  }
  return null;
}

/** Compares two strings without leaking how many leading characters matched. */
async function constantTimeEquals(providedValue: string, expectedValue: string): Promise<boolean> {
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

// MARK: - /chat

interface ChatRequestBody {
  mode?: unknown;
  messages?: unknown;
}

async function handleChat(request: Request, env: Env): Promise<Response> {
  if (!env.ANTHROPIC_API_KEY) {
    return jsonResponse(500, { error: "Worker is missing ANTHROPIC_API_KEY" });
  }

  let requestBody: ChatRequestBody;
  try {
    requestBody = await request.json();
  } catch {
    return jsonResponse(400, { error: "Body must be JSON" });
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
    messages: withConversationHistoryCached(requestBody.messages as ChatMessage[]),
    output_config: { effort: CLAUDE_EFFORT },
    // If a safety classifier declines, Anthropic retries on its recommended
    // fallback model server-side instead of returning a refusal.
    fallbacks: "default",
  };

  const sendToAnthropic = () =>
    fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": env.ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "server-side-fallback-2026-07-01",
        "content-type": "application/json",
      },
      body: JSON.stringify(anthropicRequestBody),
    });

  // A dropped connection (the fetch itself throwing, not an HTTP error)
  // is worth one quick retry before giving up on the user's question.
  let anthropicResponse: Response;
  try {
    anthropicResponse = await sendToAnthropic();
  } catch (firstAttemptError) {
    console.error("[/chat] Anthropic connection failed, retrying once:", firstAttemptError);
    anthropicResponse = await sendToAnthropic();
  }

  if (!anthropicResponse.ok) {
    const anthropicErrorBody = await anthropicResponse.text();
    console.error(`[/chat] Anthropic error ${anthropicResponse.status}: ${anthropicErrorBody}`);
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

type ChatContentBlock = Record<string, unknown>;
interface ChatMessage {
  role: string;
  content: string | ChatContentBlock[];
}

/**
 * Marks the end of the earlier conversation as cacheable. Follow-along sends
 * the same history again on every step with only a new question at the end,
 * so caching everything before that question makes each step start faster.
 * The newest question (with its screenshots) is never the same twice, so it
 * stays outside the cache.
 */
function withConversationHistoryCached(messages: ChatMessage[]): ChatMessage[] {
  if (messages.length < 3) return messages;

  const lastHistoryIndex = messages.length - 2;
  const lastHistoryMessage = messages[lastHistoryIndex];
  const lastHistoryBlocks: ChatContentBlock[] =
    typeof lastHistoryMessage.content === "string"
      ? [{ type: "text", text: lastHistoryMessage.content }]
      : lastHistoryMessage.content.map((contentBlock) => ({ ...contentBlock }));
  lastHistoryBlocks[lastHistoryBlocks.length - 1] = {
    ...lastHistoryBlocks[lastHistoryBlocks.length - 1],
    cache_control: { type: "ephemeral" },
  };

  const messagesWithCacheMarker = [...messages];
  messagesWithCacheMarker[lastHistoryIndex] = { ...lastHistoryMessage, content: lastHistoryBlocks };
  return messagesWithCacheMarker;
}

/**
 * Checks the conversation shape so the Worker only forwards well-formed
 * Sage conversations: alternating user/assistant turns ending with the user,
 * containing only text and JPEG/PNG images.
 */
function validateMessages(messages: unknown): string | null {
  if (!Array.isArray(messages) || messages.length === 0) {
    return "messages must be a non-empty array";
  }
  if (messages.length > MAXIMUM_MESSAGES_PER_REQUEST) {
    return `at most ${MAXIMUM_MESSAGES_PER_REQUEST} messages are allowed`;
  }

  let totalImageCount = 0;

  for (let messageIndex = 0; messageIndex < messages.length; messageIndex++) {
    const message = messages[messageIndex] as { role?: unknown; content?: unknown };
    const expectedRole = messageIndex % 2 === 0 ? "user" : "assistant";
    if (message?.role !== expectedRole) {
      return `messages[${messageIndex}].role must be "${expectedRole}"`;
    }

    if (typeof message.content === "string") continue;

    if (!Array.isArray(message.content)) {
      return `messages[${messageIndex}].content must be a string or an array`;
    }

    for (const contentBlock of message.content as Array<Record<string, unknown>>) {
      if (contentBlock?.type === "text" && typeof contentBlock.text === "string") continue;

      const imageSource = contentBlock?.source as Record<string, unknown> | undefined;
      const isAllowedImage =
        contentBlock?.type === "image" &&
        imageSource?.type === "base64" &&
        (imageSource.media_type === "image/jpeg" || imageSource.media_type === "image/png") &&
        typeof imageSource.data === "string";

      if (!isAllowedImage) {
        return `messages[${messageIndex}] contains an unsupported content block`;
      }
      totalImageCount += 1;
    }
  }

  if (messages.length % 2 === 0) {
    return "the last message must come from the user";
  }
  if (totalImageCount > MAXIMUM_IMAGES_PER_REQUEST) {
    return `at most ${MAXIMUM_IMAGES_PER_REQUEST} images are allowed`;
  }
  return null;
}

// MARK: - /tts

async function handleTextToSpeech(request: Request, env: Env): Promise<Response> {
  if (!env.ELEVENLABS_API_KEY || !env.ELEVENLABS_VOICE_ID) {
    return jsonResponse(503, { error: "ElevenLabs is not configured on the Worker" });
  }

  let requestBody: { text?: unknown };
  try {
    requestBody = await request.json();
  } catch {
    return jsonResponse(400, { error: "Body must be JSON" });
  }

  const textToSpeak = typeof requestBody.text === "string" ? requestBody.text.trim() : "";
  if (!textToSpeak) {
    return jsonResponse(400, { error: "text is required" });
  }
  if (textToSpeak.length > MAXIMUM_TTS_CHARACTERS) {
    return jsonResponse(400, { error: `text must be at most ${MAXIMUM_TTS_CHARACTERS} characters` });
  }

  const elevenLabsResponse = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${env.ELEVENLABS_VOICE_ID}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body: JSON.stringify({
        text: textToSpeak,
        model_id: ELEVENLABS_MODEL,
        voice_settings: { stability: 0.5, similarity_boost: 0.75 },
      }),
    }
  );

  if (!elevenLabsResponse.ok) {
    const elevenLabsErrorBody = await elevenLabsResponse.text();
    console.error(`[/tts] ElevenLabs error ${elevenLabsResponse.status}: ${elevenLabsErrorBody}`);
    return jsonResponse(elevenLabsResponse.status, {
      error: `ElevenLabs request failed (${elevenLabsResponse.status})`,
    });
  }

  return new Response(elevenLabsResponse.body, {
    status: 200,
    headers: { "content-type": "audio/mpeg" },
  });
}

// MARK: - /waitlist

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

async function handleWaitlist(request: Request, env: Env): Promise<Response> {
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
    return respond(429, { error: "Too many signups from here, try again in a minute" });
  }

  let signup: { email?: unknown; platform?: unknown; website?: unknown };
  try {
    signup = await request.json();
  } catch {
    return respond(400, { error: "Body must be JSON" });
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

// MARK: - Helpers

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
