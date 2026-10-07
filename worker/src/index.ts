import { checkIndividualAccess, handleAccountAdmin } from "./access/access-policy";
export { AccessLedger } from "./access/access-ledger";
import type { Env } from "./bindings";
import { jsonResponse } from "./http/responses";
import { checkRateLimit } from "./security/request-guards";
import { handleChat } from "./routes/chat-handler";
import { handleTextToSpeech } from "./routes/speech-handler";
import { handleWaitlist } from "./routes/waitlist-handler";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    try {
      if (url.pathname.startsWith("/admin/accounts/")) {
        const limited = await checkRateLimit(request, env);
        return limited ?? await handleAccountAdmin(request, env);
      }

      // The waitlist is called from the public website, so it skips bearer
      // authentication and handles its own CORS and validation.
      if (url.pathname === "/waitlist") {
        return await handleWaitlist(request, env);
      }

      if (request.method === "GET" && url.pathname === "/health") {
        return jsonResponse(200, {
          ok: true,
          claudeConfigured: Boolean(env.ANTHROPIC_API_KEY),
          accountsConfigured: Boolean(env.ACCESS_LEDGER),
          elevenLabsConfigured: Boolean(env.ELEVENLABS_API_KEY && env.ELEVENLABS_VOICE_ID),
        });
      }

      if (request.method !== "POST") {
        return jsonResponse(405, { error: "Method not allowed" });
      }

      if (url.pathname !== "/chat" && url.pathname !== "/tts") {
        return jsonResponse(404, { error: "Not found" });
      }

      const rateLimitFailure = await checkRateLimit(request, env);
      if (rateLimitFailure) return rateLimitFailure;

      const authenticationFailure = await checkIndividualAccess(request, env);
      if (authenticationFailure) return authenticationFailure;

      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }
      return await handleTextToSpeech(request, env);
    } catch (error) {
      console.error(`[${url.pathname}] Request failed`);
      if (error instanceof Error && error.name === "TimeoutError") {
        return jsonResponse(504, { error: "Provider request timed out" });
      }
      return jsonResponse(500, { error: "Internal error" });
    }
  },
};
