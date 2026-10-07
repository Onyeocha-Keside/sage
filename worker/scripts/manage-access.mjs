// Run manually after configuring/deploying the Worker. Never pass admin keys as
// command-line arguments; use the SAGE_ADMIN_KEY environment variable.
const [operation, accountID, rawLimit] = process.argv.slice(2);
if (!["provision", "revoke"].includes(operation) || !/^[a-zA-Z0-9_-]{1,80}$/.test(accountID ?? "")) {
  throw new Error("Usage: node scripts/manage-access.mjs provision ACCOUNT_ID MONTHLY_LIMIT_MICRO_USD | revoke ACCOUNT_ID");
}
const server = new URL(process.env.SAGE_WORKER_URL ?? "http://localhost:8787");
if (server.protocol !== "https:" && !(server.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(server.hostname))) {
  throw new Error("Access administration requires HTTPS except on localhost");
}
if (server.username || server.password || server.search || server.hash) throw new Error("Use a plain Worker URL");
const adminKey = process.env.SAGE_ADMIN_KEY;
if (!adminKey) throw new Error("Set SAGE_ADMIN_KEY in your environment");
const body = { accountID };
if (operation === "provision") {
  const limit = Number(rawLimit);
  if (!Number.isSafeInteger(limit) || limit <= 0 || limit > 1_000_000_000_000) throw new Error("Monthly allowance must be a positive integer in millionths of USD");
  body.monthlyLimitMicroUSD = limit;
}
const response = await fetch(new URL(`/admin/accounts/${operation}`, server), {
  method: "POST", headers: { "content-type": "application/json", "x-sage-admin-key": adminKey },
  body: JSON.stringify(body), signal: AbortSignal.timeout(20_000),
});
if (!response.ok) throw new Error(`Account administration failed (${response.status})`);
// Provisioning returns the new token once. Treat the output as a credential.
console.log(JSON.stringify(await response.json(), null, 2));
