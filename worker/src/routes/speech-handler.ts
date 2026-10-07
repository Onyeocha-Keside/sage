import { reserveProviderBudget } from "../access/access-policy";
import type { Env } from "../bindings";
import { MAXIMUM_TTS_CHARACTERS, ELEVENLABS_MODEL } from "../api-limits";
import { jsonResponse } from "../http/responses";
import { readJsonObject, requestBodyErrorResponse } from "../http/request-body";

export async function handleTextToSpeech(request: Request, env: Env): Promise<Response> {
  if (!env.ELEVENLABS_API_KEY || !env.ELEVENLABS_VOICE_ID) {
    return jsonResponse(503, { error: "ElevenLabs is not configured on the Worker" });
  }

  let requestBody: { text?: unknown };
  try {
    requestBody = await readJsonObject(request, 16 * 1024);
  } catch (error) {
    return requestBodyErrorResponse(error);
  }

  const textToSpeak = typeof requestBody.text === "string" ? requestBody.text.trim() : "";
  if (!textToSpeak) {
    return jsonResponse(400, { error: "text is required" });
  }
  if (textToSpeak.length > MAXIMUM_TTS_CHARACTERS) {
    return jsonResponse(400, { error: `text must be at most ${MAXIMUM_TTS_CHARACTERS} characters` });
  }

  request.signal.throwIfAborted();
  const budgetFailure = await reserveProviderBudget(request, env, "tts");
  if (budgetFailure) return budgetFailure;

  const elevenLabsResponse = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${env.ELEVENLABS_VOICE_ID}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      signal: AbortSignal.any([request.signal, AbortSignal.timeout(40_000)]),
      body: JSON.stringify({
        text: textToSpeak,
        model_id: ELEVENLABS_MODEL,
        voice_settings: { stability: 0.5, similarity_boost: 0.75 },
      }),
    }
  );

  if (!elevenLabsResponse.ok) {
    await elevenLabsResponse.body?.cancel();
    console.error(`[/tts] ElevenLabs error ${elevenLabsResponse.status}`);
    return jsonResponse(elevenLabsResponse.status, {
      error: `ElevenLabs request failed (${elevenLabsResponse.status})`,
    });
  }

  return new Response(elevenLabsResponse.body, {
    status: 200,
    headers: { "content-type": "audio/mpeg" },
  });
}
