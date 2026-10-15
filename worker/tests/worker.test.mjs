import test from "node:test";
import assert from "node:assert/strict";
import { worker, readJsonObject, validateMessages, sanitizeMessages, withConversationHistoryCached, AccessLedger, tokenHash, readImageDimensions, maximumImageTokens } from "../.wrangler/tests/entry.mjs";

const environment = { SAGE_ADMIN_KEY: "test-only-admin", CHAT_RESERVATION_MICRO_USD: "1000000", TTS_RESERVATION_MICRO_USD: "100000", GLOBAL_MONTHLY_BUDGET_MICRO_USD: "100000000", GLOBAL_DAILY_BUDGET_MICRO_USD: "10000000", ACCESS_LEDGER: { idFromName(name) { return name; }, get() { return { async fetch(request) { const body = await request.json(); if (body.tokenHash !== await tokenHash("sage_" + "a".repeat(64))) return new Response("", { status: 401 }); return new Response("{}", { status: 200 }); } }; } }, ANTHROPIC_API_KEY: "test-only-provider", ELEVENLABS_API_KEY: "test-only-voice", ELEVENLABS_VOICE_ID: "test-voice", RATE_LIMITER: { async limit() { return { success: true }; } }, WAITLIST: { async get() { return null; }, async put() {} } };
function request(path, body, headers = {}) {
  return new Request(`https://worker.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: "Bearer sage_" + "a".repeat(64), origin: "https://sage.kesideonyeocha.com", ...headers }, body: JSON.stringify(body) });
}

test("null, arrays, primitives and malformed JSON return 400 across all routes", async () => {
  for (const path of ["/chat", "/tts", "/waitlist"]) {
    for (const body of [null, [], "hello", 42]) assert.equal((await worker.fetch(request(path, body), environment)).status, 400);
    const invalid = request(path, {});
    const malformed = new Request(invalid.url, { method: "POST", headers: invalid.headers, body: "{" });
    assert.equal((await worker.fetch(malformed, environment)).status, 400);
  }
});

test("body limit measures streamed bytes even with missing or dishonest Content-Length", async () => {
  for (const length of [undefined, "1"]) {
    const headers = length ? { "content-length": length } : {};
    const stream = new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode('{"value":"')); controller.enqueue(new Uint8Array(64)); controller.close(); } });
    const bodyRequest = new Request("https://worker.test/chat", { method: "POST", headers, body: stream, duplex: "half" });
    await assert.rejects(readJsonObject(bodyRequest, 32), error => error.status === 413);
  }
});

test("small public and voice routes reject oversized actual bodies", async () => {
  for (const path of ["/tts", "/waitlist"]) assert.equal((await worker.fetch(request(path, { text: "a".repeat(17_000) }), environment)).status, 413);
});

test("authentication and rate limits prevent provider calls", async () => {
  assert.equal((await worker.fetch(request("/chat", {}, { authorization: "Bearer wrong" }), environment)).status, 401);
  const limited = { ...environment, RATE_LIMITER: { async limit() { return { success: false }; } } };
  assert.equal((await worker.fetch(request("/chat", {}), limited)).status, 429);
  assert.equal((await worker.fetch(request("/waitlist", {}), limited)).status, 429);
});

test("chat rejects invalid roles, empty content, unsupported mode and images", async () => {
  for (const messages of [[], [{ role: "user", content: [] }], [{ role: "user", content: " " }], [{ role: "assistant", content: "hello" }], [{ role: "user", content: [null] }], [{ role: "user", content: [{ type: "image", source: { type: "base64", media_type: "image/jpeg", data: "not base64" } }] }]]) {
    assert.notEqual(validateMessages(messages), null);
    assert.equal((await worker.fetch(request("/chat", { messages }), environment)).status, 400);
  }
  assert.equal((await worker.fetch(request("/chat", { mode: "other", messages: [{ role: "user", content: "hello" }] }), environment)).status, 400);
});

test("image count and conversation limits are enforced", () => {
  const image = { type: "image", source: { type: "base64", media_type: "image/jpeg", data: "YWJj" } };
  assert.equal(validateMessages([{ role: "user", content: Array(4).fill(image) }]), null);
  assert.match(validateMessages([{ role: "user", content: Array(5).fill(image) }]), /at most 4/);
  assert.match(validateMessages(Array.from({ length: 43 }, (_, index) => ({ role: index % 2 ? "assistant" : "user", content: "hello" }))), /at most 41/);
});

test("provider options are stripped and history caching does not mutate input", () => {
  const messages = [{ role: "user", content: [{ type: "text", text: "question", cache_control: { type: "ephemeral" }, extra: "untrusted" }] }, { role: "assistant", content: "answer" }, { role: "user", content: "next" }];
  const sanitized = sanitizeMessages(messages);
  assert.deepEqual(sanitized[0].content, [{ type: "text", text: "question" }]);
  const cached = withConversationHistoryCached(sanitized);
  assert.equal(cached[1].content[0].cache_control.type, "ephemeral");
  assert.equal(sanitized[1].content, "answer");
});

test("chat forwards the normalized request and streams the response", async () => {
  const originalFetch = globalThis.fetch;
  let upstreamPayload;
  globalThis.fetch = async (url, options) => { upstreamPayload = JSON.parse(options.body); return new Response('data: {"type":"message_stop"}\n\n', { headers: { "content-type": "text/event-stream" } }); };
  try {
    const response = await worker.fetch(request("/chat", { messages: [{ role: "user", content: "hello" }] }), environment);
    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type"), /text\/event-stream/);
    assert.match(await response.text(), /message_stop/);
    assert.equal(upstreamPayload.messages[0].content, "hello");
    assert.equal(upstreamPayload.stream, true);
  } finally { globalThis.fetch = originalFetch; }
});

test("waitlist rejects foreign origins, supports preflight, ignores honeypots, stores normalized signups", async () => {
  assert.equal((await worker.fetch(request("/waitlist", { email: "person@example.com" }, { origin: "https://foreign.test" }), environment)).status, 403);
  const preflight = new Request("https://worker.test/waitlist", { method: "OPTIONS", headers: { origin: "https://sage.kesideonyeocha.com" } });
  assert.equal((await worker.fetch(preflight, environment)).status, 204);
  const writes = [];
  const storage = { ...environment, WAITLIST: { async get() { return null; }, async put(key, value) { writes.push([key, JSON.parse(value)]); } } };
  assert.equal((await worker.fetch(request("/waitlist", { website: "bot" }), storage)).status, 200);
  assert.equal(writes.length, 0);
  assert.equal((await worker.fetch(request("/waitlist", { email: " Person@Example.com ", platform: "windows" }), storage)).status, 200);
  assert.equal(writes[0][0], "signup:person@example.com");
  assert.equal(writes[0][1].platform, "windows");
});


test("public routes fail closed when rate limiting is missing or fails", async () => {
  for (const limiter of [undefined, { async limit() { throw new Error("service unavailable"); } }]) {
    const unavailable = { ...environment, RATE_LIMITER: limiter };
    for (const path of ["/chat", "/tts", "/waitlist"]) {
      const response = await worker.fetch(request(path, {}), unavailable);
      assert.equal(response.status, 503);
    }
  }
});

function memoryStorage() {
  const values = new Map();
  let tail = Promise.resolve();
  const storage = {
    async get(key) { return structuredClone(values.get(key)); },
    async put(key, value) { values.set(key, structuredClone(value)); },
    transaction(callback) {
      const next = tail.then(() => callback(storage));
      tail = next.catch(() => {});
      return next;
    },
  };
  return storage;
}
function ledgerCall(ledger, operation, body) {
  return ledger.fetch(new Request(`https://ledger.internal/${operation}`, { method: "POST", body: JSON.stringify(body) }));
}

test("individual tokens cannot be replaced by the legacy shared app key", async () => {
  assert.equal((await worker.fetch(request("/chat", {}, { authorization: "", "x-sage-app-key": "test-only-key" }), environment)).status, 401);
  assert.equal((await worker.fetch(request("/chat", {}, { authorization: "Bearer sage_" + "b".repeat(64) }), environment)).status, 401);
  assert.equal((await worker.fetch(request("/chat", {}), { ...environment, ACCESS_LEDGER: undefined })).status, 503);
  assert.equal((await worker.fetch(request("/chat", {}), { ...environment, ACCESS_LEDGER: { idFromName() { return "global"; }, get() { throw new Error("unavailable"); } } })).status, 503);
});

test("ledger reservations are atomic, per-account, globally bounded, and rotation preserves usage", async () => {
  const ledger = new AccessLedger({ storage: memoryStorage() });
  const hash = await tokenHash("sage_" + "c".repeat(64));
  assert.equal((await ledgerCall(ledger, "provision", { accountID: "alice", tokenHash: hash, monthlyLimit: 3 })).status, 200);
  const reservation = { tokenHash: hash, charge: 1, globalMonthlyLimit: 100, globalDailyLimit: 100 };
  const attempts = await Promise.all(Array.from({ length: 10 }, () => ledgerCall(ledger, "reserve", reservation)));
  assert.equal(attempts.filter(response => response.status === 200).length, 3);
  assert.equal(attempts.filter(response => response.status === 429).length, 7);
  const replacement = await tokenHash("sage_" + "d".repeat(64));
  await ledgerCall(ledger, "provision", { accountID: "alice", tokenHash: replacement, monthlyLimit: 3 });
  assert.equal((await ledgerCall(ledger, "authorize", { tokenHash: hash })).status, 401);
  assert.equal((await ledgerCall(ledger, "reserve", { ...reservation, tokenHash: replacement })).status, 429);
  await ledgerCall(ledger, "provision", { accountID: "bob", tokenHash: hash, monthlyLimit: 100 });
  assert.equal((await ledgerCall(ledger, "reserve", { ...reservation, globalDailyLimit: 3 })).status, 503);
  assert.equal((await ledgerCall(ledger, "reserve", { ...reservation, globalMonthlyLimit: 3 })).status, 503);
  assert.equal((await ledgerCall(ledger, "reserve", { ...reservation, charge: 0 })).status, 503);
  await ledgerCall(ledger, "revoke", { accountID: "bob" });
  assert.equal((await ledgerCall(ledger, "authorize", { tokenHash: hash })).status, 401);
  assert.equal((await ledgerCall(ledger, "provision", { accountID: "__proto__", tokenHash: hash, monthlyLimit: 10 })).status, 400);
});

test("admin provisioning requires separate credentials and issued tokens are returned once without caching", async () => {
  const ledger = new AccessLedger({ storage: memoryStorage() });
  const adminEnvironment = { ...environment, ACCESS_LEDGER: { idFromName() { return "global"; }, get() { return ledger; } } };
  const body = { accountID: "beta-user", monthlyLimitMicroUSD: 5000000 };
  assert.equal((await worker.fetch(request("/admin/accounts/provision", body), adminEnvironment)).status, 401);
  const response = await worker.fetch(request("/admin/accounts/provision", body, { "x-sage-admin-key": environment.SAGE_ADMIN_KEY }), adminEnvironment);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  const issued = await response.json();
  assert.match(issued.accessToken, /^sage_[a-f0-9]{64}$/);
  const headers = { authorization: "Bearer " + issued.accessToken };
  assert.equal((await worker.fetch(request("/chat", {}, headers), adminEnvironment)).status, 400);
  await worker.fetch(request("/admin/accounts/revoke", { accountID: "beta-user" }, { "x-sage-admin-key": environment.SAGE_ADMIN_KEY }), adminEnvironment);
  assert.equal((await worker.fetch(request("/chat", {}, headers), adminEnvironment)).status, 401);
});

test("denied budgets prevent any paid provider request, including TTS", async () => {
  const originalFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async (url) => { calls += 1; throw new Error("must not call paid provider"); };
  const denied = { ...environment, ACCESS_LEDGER: { idFromName() { return "global"; }, get() { return { async fetch(request) { return new URL(request.url).pathname === "/reserve" ? new Response("", { status: 429 }) : new Response("{}"); } }; } } };
  try {
    assert.equal((await worker.fetch(request("/chat", { messages: [{ role: "user", content: "hello" }] }), denied)).status, 429);
    assert.equal((await worker.fetch(request("/tts", { text: "hello" }), denied)).status, 429);
    assert.equal(calls, 0);
  } finally { globalThis.fetch = originalFetch; }
});

test("local input bound rejects oversized or unmeasurable inputs before paid inference", async () => {
  const originalFetch = globalThis.fetch;
  let paidCalls = 0;
  globalThis.fetch = async () => { paidCalls += 1; return new Response("unexpected"); };
  const unreadableImage = { type: "image", source: { type: "base64", media_type: "image/jpeg", data: "AAAA" } };
  try {
    const oversized = await worker.fetch(request("/chat", { messages: [{ role: "user", content: "a".repeat(100_001) }] }), environment);
    assert.equal(oversized.status, 413);
    const unmeasurable = await worker.fetch(request("/chat", { messages: [{ role: "user", content: [unreadableImage, { type: "text", text: "hi" }] }] }), environment);
    assert.equal(unmeasurable.status, 400);
    assert.equal(paidCalls, 0);
  } finally { globalThis.fetch = originalFetch; }
});

test("image dimensions are read from PNG and JPEG headers and bounded above Anthropic's formulas", () => {
  const png = new Uint8Array(24);
  png.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  new DataView(png.buffer).setUint32(16, 1280);
  new DataView(png.buffer).setUint32(20, 800);
  const toBase64 = bytes => btoa(String.fromCharCode(...bytes));
  assert.deepEqual(readImageDimensions(toBase64(png)), { width: 1280, height: 800 });
  // SOI, an APP0 segment, then a baseline start-of-frame with height 720 and width 1280.
  const jpeg = [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x02, 0xd0, 0x05, 0x00, 0x03, 0, 0, 0, 0];
  assert.deepEqual(readImageDimensions(toBase64(jpeg)), { width: 1280, height: 720 });
  assert.equal(readImageDimensions("AAAA"), null);
  assert.ok(maximumImageTokens(1280, 800) >= Math.ceil(1280 * 800 / 750));
  assert.ok(maximumImageTokens(1280, 800) >= Math.ceil(1280 / 28) * Math.ceil(800 / 28));
  // Sage's worst case (four 1280px screens plus a long conversation) stays well inside the limit.
  assert.ok(4 * maximumImageTokens(1280, 1280) < 20_000);
});

test("each transport retry reserves again and no provider fallback is requested", async () => {
  const originalFetch = globalThis.fetch;
  let reservations = 0;
  let paidCalls = 0;
  const retryEnvironment = { ...environment, ACCESS_LEDGER: { idFromName() { return "global"; }, get() { return { async fetch(request) { if (new URL(request.url).pathname === "/reserve") reservations += 1; return new Response("{}"); } }; } } };
  globalThis.fetch = async (url, options) => {
    const payload = JSON.parse(options.body);
    assert.equal(payload.fallbacks, undefined);
    paidCalls += 1;
    if (paidCalls === 1) throw new Error("ambiguous disconnect");
    return new Response('data: {"type":"message_stop"}\n\n');
  };
  try {
    assert.equal((await worker.fetch(request("/chat", { messages: [{ role: "user", content: "hello" }] }), retryEnvironment)).status, 200);
    assert.equal(reservations, 2);
    assert.equal(paidCalls, 2);
  } finally { globalThis.fetch = originalFetch; }
});

test("account rate limits are shared across IPs and survive ledger reconstruction", async () => {
  const storage = memoryStorage();
  let ledger = new AccessLedger({ storage });
  const hash = await tokenHash("sage_" + "e".repeat(64));
  await ledgerCall(ledger, "provision", { accountID: "alice", tokenHash: hash, monthlyLimit: 100 });
  for (let number = 0; number < 20; number += 1) assert.equal((await ledgerCall(ledger, "authorize", { tokenHash: hash })).status, 200);
  ledger = new AccessLedger({ storage });
  assert.equal((await ledgerCall(ledger, "authorize", { tokenHash: hash })).status, 429);
});

test("monthly and daily reservations reset at UTC period boundaries", async () => {
  const storage = memoryStorage();
  const hash = await tokenHash("sage_" + "f".repeat(64));
  await storage.put("ledger", {
    accounts: { alice: { tokenHash: hash, monthlyLimit: 1, revoked: false } },
    monthly: { alice: { period: "2000-01", reserved: 1 } },
    globalMonth: { period: "2000-01", reserved: 1 }, globalDay: { period: "2000-01-01", reserved: 1 },
  });
  const ledger = new AccessLedger({ storage });
  const reservation = { tokenHash: hash, charge: 1, globalMonthlyLimit: 1, globalDailyLimit: 1 };
  assert.equal((await ledgerCall(ledger, "reserve", reservation)).status, 200);
  assert.equal((await ledgerCall(ledger, "reserve", reservation)).status, 429);
});
