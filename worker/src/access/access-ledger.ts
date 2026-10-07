import { jsonResponse } from "../http/responses";
import { readJsonObject, requestBodyErrorResponse } from "../http/request-body";

interface Account {
  tokenHash: string;
  monthlyLimit: number;
  revoked: boolean;
}
interface Usage { period: string; reserved: number }
interface LedgerData {
  accounts: Record<string, Account>;
  monthly: Record<string, Usage>;
  globalMonth: Usage;
  globalDay: Usage;
  minuteRequests?: Record<string, { minute: string; count: number }>;
}
export interface LedgerStorage {
  get<Value>(key: string): Promise<Value | undefined>;
  put(key: string, value: unknown): Promise<void>;
  transaction<Value>(callback: (transaction: LedgerStorage) => Promise<Value>): Promise<Value>;
}

/** One globally named Durable Object serializes account and global reservations.
 * No refunds: disconnects, ambiguous failures, and retries may still incur cost.
 * Amounts are conservative operator-defined reservations, not invoice readings.
 */
export class AccessLedger {
  constructor(private state: { storage: LedgerStorage }) {}

  async fetch(request: Request): Promise<Response> {
    let body: Record<string, unknown>;
    try { body = await readJsonObject(request, 4096); }
    catch (error) { return requestBodyErrorResponse(error); }
    const path = new URL(request.url).pathname;
    const now = new Date();
    const month = now.toISOString().slice(0, 7);
    const day = now.toISOString().slice(0, 10);
    return this.state.storage.transaction(async storage => {
      const data = await storage.get<LedgerData>("ledger") ?? {
        accounts: {}, monthly: {}, globalMonth: { period: month, reserved: 0 }, globalDay: { period: day, reserved: 0 },
      };
      const accountID = typeof body.accountID === "string" ? body.accountID : "";
      if (path === "/provision") {
        if (["__proto__", "constructor", "prototype"].includes(accountID) || !/^[a-zA-Z0-9_-]{1,80}$/.test(accountID) || typeof body.tokenHash !== "string" || !/^[a-f0-9]{64}$/.test(body.tokenHash)
            || !positiveInteger(body.monthlyLimit)) return jsonResponse(400, { error: "Invalid account policy" });
        // Rotation deliberately retains this month's usage.
        data.accounts[accountID] = { tokenHash: body.tokenHash, monthlyLimit: body.monthlyLimit, revoked: false };
        await storage.put("ledger", data);
        return jsonResponse(200, { accountID });
      }
      if (path === "/revoke") {
        if (!Object.hasOwn(data.accounts, accountID)) return jsonResponse(404, { error: "Unknown account" });
        data.accounts[accountID].revoked = true;
        await storage.put("ledger", data);
        return jsonResponse(200, { accountID, revoked: true });
      }
      if (path !== "/authorize" && path !== "/reserve") return jsonResponse(404, { error: "Unknown ledger operation" });
      const accountEntry = Object.entries(data.accounts).find(([, account]) => account.tokenHash === body.tokenHash && !account.revoked);
      if (!accountEntry) return jsonResponse(401, { error: "Access token is invalid or revoked" });
      const [authenticatedID, account] = accountEntry;
      if (path === "/authorize") {
        const minute = now.toISOString().slice(0, 16);
        data.minuteRequests ??= {};
        const usage = data.minuteRequests[authenticatedID]?.minute === minute
          ? data.minuteRequests[authenticatedID] : { minute, count: 0 };
        if (usage.count >= 20) return jsonResponse(429, { error: "Account request limit reached; try again shortly" });
        usage.count += 1;
        data.minuteRequests[authenticatedID] = usage;
        await storage.put("ledger", data);
        return jsonResponse(200, { accountID: authenticatedID });
      }
      if (!positiveInteger(body.charge) || !positiveInteger(body.globalMonthlyLimit) || !positiveInteger(body.globalDailyLimit)) {
        return jsonResponse(503, { error: "Budget policy is unavailable" });
      }
      if (data.globalMonth.period !== month) data.globalMonth = { period: month, reserved: 0 };
      if (data.globalDay.period !== day) data.globalDay = { period: day, reserved: 0 };
      const usage = data.monthly[authenticatedID]?.period === month ? data.monthly[authenticatedID] : { period: month, reserved: 0 };
      if (usage.reserved + body.charge > account.monthlyLimit) return jsonResponse(429, { error: "Your monthly Sage allowance is exhausted" });
      if (data.globalMonth.reserved + body.charge > body.globalMonthlyLimit || data.globalDay.reserved + body.charge > body.globalDailyLimit) {
        return jsonResponse(503, { error: "Sage's service budget is exhausted; please try later" });
      }
      usage.reserved += body.charge;
      data.monthly[authenticatedID] = usage;
      data.globalMonth.reserved += body.charge;
      data.globalDay.reserved += body.charge;
      await storage.put("ledger", data);
      return jsonResponse(200, { accountID: authenticatedID, monthlyReserved: usage.reserved, monthlyLimit: account.monthlyLimit });
    });
  }
}
function positiveInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0 && value <= 1_000_000_000_000;
}
