import type { RelaySpace } from "./space";

export interface RelayEnv {
  DB: D1Database;
  RELAY_SPACE: DurableObjectNamespace<RelaySpace>;
  /** Agent requests per client key; see AGENT_BURST. */
  AGENT_LIMIT: RateLimit;
  /** Connection attempts per Mac. */
  CONNECT_LIMIT: RateLimit;
  /** Secret. Without it the relay neither meters nor bills, and only the fixed limits apply. */
  AUTUMN_SECRET_KEY?: string;
}
