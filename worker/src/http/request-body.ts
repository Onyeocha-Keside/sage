/** Read the actual byte stream. Content-Length is only an early rejection hint. */
export class RequestBodyError extends Error {
  constructor(public readonly status: number, message: string) { super(message); }
}

export async function readJsonObject(request: Request, maximumBytes: number): Promise<Record<string, unknown>> {
  if (Number(request.headers.get("content-length")) > maximumBytes) {
    throw new RequestBodyError(413, "Request too large");
  }
  if (!request.body) throw new RequestBodyError(400, "Body must be a JSON object");
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let receivedBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      receivedBytes += value.byteLength;
      if (receivedBytes > maximumBytes) {
        await reader.cancel();
        throw new RequestBodyError(413, "Request too large");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(receivedBytes);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  let parsed: unknown;
  try { parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
  catch { throw new RequestBodyError(400, "Body must be JSON"); }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new RequestBodyError(400, "Body must be a JSON object");
  }
  return parsed as Record<string, unknown>;
}

export function requestBodyErrorResponse(error: unknown, extraHeaders: Record<string, string> = {}): Response {
  if (!(error instanceof RequestBodyError)) throw error;
  return new Response(JSON.stringify({ error: error.message }), {
    status: error.status,
    headers: { "content-type": "application/json", ...extraHeaders },
  });
}
