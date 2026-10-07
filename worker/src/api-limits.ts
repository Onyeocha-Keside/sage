import type { ConversationMode } from "./prompts";

// The model Sage uses. Sonnet 5.5 is fast, sharp at reading screenshots,
// and cheaper per token than older Sonnets.
export const CLAUDE_MODEL = "claude-sonnet-5-5";

// Low effort keeps thinking short so Sage starts talking quickly.
export const CLAUDE_EFFORT = "low";

// Thinking counts toward max_tokens, so leave headroom above the spoken reply.
export const MAX_OUTPUT_TOKENS_BY_MODE: Record<ConversationMode, number> = {
  companion: 2048,
  onboarding: 512,
};

export const MAXIMUM_REQUEST_BODY_BYTES = 15 * 1024 * 1024;
export const MAXIMUM_MESSAGES_PER_REQUEST = 41; // 20 past exchanges + the new question
export const MAXIMUM_IMAGES_PER_REQUEST = 4;
export const MAXIMUM_TTS_CHARACTERS = 1000;
export const ELEVENLABS_MODEL = "eleven_flash_v2_5";
