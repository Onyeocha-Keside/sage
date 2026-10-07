import { MAXIMUM_MESSAGES_PER_REQUEST, MAXIMUM_IMAGES_PER_REQUEST } from "../api-limits";

export type ChatContentBlock = Record<string, unknown>;
export interface ChatMessage {
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
export function withConversationHistoryCached(messages: ChatMessage[]): ChatMessage[] {
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
export function validateMessages(messages: unknown): string | null {
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

    if (typeof message.content === "string") {
      if (!message.content.trim()) return `messages[${messageIndex}].content must not be empty`;
      continue;
    }

    if (!Array.isArray(message.content)) {
      return `messages[${messageIndex}].content must be a string or an array`;
    }

    if (message.content.length === 0) return `messages[${messageIndex}].content must not be empty`;

    for (const contentBlock of message.content as Array<Record<string, unknown>>) {
      if (contentBlock?.type === "text" && typeof contentBlock.text === "string" && contentBlock.text.trim()) continue;

      const imageSource = contentBlock?.source as Record<string, unknown> | undefined;
      const isAllowedImage =
        contentBlock?.type === "image" &&
        imageSource?.type === "base64" &&
        (imageSource.media_type === "image/jpeg" || imageSource.media_type === "image/png") &&
        typeof imageSource.data === "string" &&
        imageSource.data.length > 0 &&
        imageSource.data.length % 4 === 0 &&
        /^[A-Za-z0-9+/]+={0,2}$/.test(imageSource.data) &&
        expectedRole === "user";

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


/** Allow only the fields Sage actually uses; client-supplied provider options never pass through. */
export function sanitizeMessages(messages: ChatMessage[]): ChatMessage[] {
  return messages.map((message) => ({
    role: message.role,
    content: typeof message.content === "string" ? message.content : message.content.map((block) => {
      if (block.type === "text") return { type: "text", text: block.text };
      const source = block.source as Record<string, unknown>;
      return { type: "image", source: { type: "base64", media_type: source.media_type, data: source.data } };
    }),
  }));
}
