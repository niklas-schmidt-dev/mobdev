import type { RelaySpace } from "./space";

export interface RelayEnv {
  DB: D1Database;
  RELAY_SPACE: DurableObjectNamespace<RelaySpace>;
}
