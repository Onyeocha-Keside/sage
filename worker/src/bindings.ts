export interface RateLimitBinding {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface KeyValueBinding {
  get(key: string): Promise<string | null>;
  put(key: string, value: string): Promise<void>;
}

export interface Env {
  ANTHROPIC_API_KEY: string;
  SAGE_ADMIN_KEY?: string;
  ACCESS_LEDGER?: {
    idFromName(name: string): unknown;
    get(id: unknown): { fetch(request: Request): Promise<Response> };
  };
  CHAT_RESERVATION_MICRO_USD?: string;
  TTS_RESERVATION_MICRO_USD?: string;
  GLOBAL_MONTHLY_BUDGET_MICRO_USD?: string;
  GLOBAL_DAILY_BUDGET_MICRO_USD?: string;
  ELEVENLABS_API_KEY?: string;
  ELEVENLABS_VOICE_ID?: string;
  RATE_LIMITER?: RateLimitBinding;
  WAITLIST?: KeyValueBinding;
}
