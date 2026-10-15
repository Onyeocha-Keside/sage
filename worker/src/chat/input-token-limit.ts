import { jsonResponse } from "../http/responses";

export const MAXIMUM_INPUT_TOKENS = 100_000;

// Overhead allowances for role markers, block wrappers and the request frame.
const TOKENS_PER_MESSAGE_OVERHEAD = 16;
const TOKENS_PER_BLOCK_OVERHEAD = 16;
const TOKENS_PER_REQUEST_OVERHEAD = 256;
// JPEG headers (with EXIF) can push the frame header back; Sage's own JPEGs keep it near the start.
const IMAGE_HEADER_BASE64_PREFIX_LENGTH = 128 * 1024;

/**
 * Bounds the input size locally instead of asking Anthropic's count endpoint,
 * which cost a full extra round trip before every reply.
 *
 * The estimate never undercounts:
 * - text: Claude's tokenizer is byte-level, so a token always covers at least
 *   one UTF-8 byte and the byte count is an upper bound on text tokens.
 * - images: Anthropic bills about width × height / 750 tokens (or one token
 *   per 28 px patch) and only ever shrinks oversized images. The bound below
 *   is above both formulas, read from the image's own header dimensions.
 *   An image whose dimensions can't be read is rejected.
 * The fixed per-attempt budget reservation is sized for MAXIMUM_INPUT_TOKENS,
 * so overestimating keeps the spending guarantee.
 */
export function checkInputTokenLimit(payload: { system: unknown; messages: unknown }): Response | null {
  const estimate = estimateMaximumInputTokens(payload);
  if (estimate === null) return jsonResponse(400, { error: "An image's size couldn't be read" });
  if (estimate > MAXIMUM_INPUT_TOKENS) return jsonResponse(413, { error: "Conversation exceeds Sage's input allowance; start a shorter conversation" });
  return null;
}

/** Returns an upper bound on input tokens, or null if an image can't be measured. */
export function estimateMaximumInputTokens(payload: { system: unknown; messages: unknown }): number | null {
  const textEncoder = new TextEncoder();
  let estimate = TOKENS_PER_REQUEST_OVERHEAD;

  for (const systemBlock of asArray(payload.system)) {
    estimate += TOKENS_PER_BLOCK_OVERHEAD + textEncoder.encode(String((systemBlock as { text?: unknown }).text ?? "")).length;
  }

  for (const message of asArray(payload.messages) as Array<{ content?: unknown }>) {
    estimate += TOKENS_PER_MESSAGE_OVERHEAD;
    if (typeof message.content === "string") {
      estimate += textEncoder.encode(message.content).length;
      continue;
    }
    for (const block of asArray(message.content) as Array<Record<string, unknown>>) {
      estimate += TOKENS_PER_BLOCK_OVERHEAD;
      if (block.type === "text") {
        estimate += textEncoder.encode(String(block.text ?? "")).length;
      } else if (block.type === "image") {
        const source = block.source as { data?: unknown } | undefined;
        const dimensions = typeof source?.data === "string" ? readImageDimensions(source.data) : null;
        if (!dimensions) return null;
        estimate += maximumImageTokens(dimensions.width, dimensions.height);
      }
    }
  }
  return estimate;
}

export function maximumImageTokens(width: number, height: number): number {
  const patchTokens = Math.ceil(width / 28 + 1) * Math.ceil(height / 28 + 1);
  const areaTokens = Math.ceil((width * height) / 750);
  return Math.ceil(Math.max(patchTokens, areaTokens) * 1.1) + 100;
}

/** Reads PNG or JPEG pixel dimensions from the start of base64 image data. */
export function readImageDimensions(base64Data: string): { width: number; height: number } | null {
  let headerBytes: Uint8Array;
  try {
    const prefix = base64Data.slice(0, IMAGE_HEADER_BASE64_PREFIX_LENGTH - (IMAGE_HEADER_BASE64_PREFIX_LENGTH % 4));
    headerBytes = Uint8Array.from(atob(prefix), (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
  return readPNGDimensions(headerBytes) ?? readJPEGDimensions(headerBytes);
}

function readPNGDimensions(bytes: Uint8Array): { width: number; height: number } | null {
  const pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (bytes.length < 24 || !pngSignature.every((byte, index) => bytes[index] === byte)) return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return validDimensions(view.getUint32(16), view.getUint32(20));
}

function readJPEGDimensions(bytes: Uint8Array): { width: number; height: number } | null {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  let offset = 2;
  while (offset + 9 < bytes.length) {
    if (bytes[offset] !== 0xff) return null;
    const marker = bytes[offset + 1];
    // Fill bytes and standalone markers carry no length.
    if (marker === 0xff) { offset += 1; continue; }
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { offset += 2; continue; }
    const segmentLength = (bytes[offset + 2] << 8) | bytes[offset + 3];
    // Start-of-frame markers hold the dimensions; C4, C8 and CC are other tables.
    const isStartOfFrame = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (isStartOfFrame) {
      const height = (bytes[offset + 5] << 8) | bytes[offset + 6];
      const width = (bytes[offset + 7] << 8) | bytes[offset + 8];
      return validDimensions(width, height);
    }
    if (segmentLength < 2) return null;
    offset += 2 + segmentLength;
  }
  return null;
}

function validDimensions(width: number, height: number): { width: number; height: number } | null {
  return width > 0 && height > 0 ? { width, height } : null;
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}
