import type { D1Migration } from "cloudflare:test";
import type { RelayEnv } from "../relay/src/env";

// Tests run against the relay worker (see vitest.config.ts).
declare global {
  namespace Cloudflare {
    interface Env extends RelayEnv {
      TEST_MIGRATIONS: D1Migration[];
    }
    interface GlobalProps {
      mainModule: typeof import("../relay/src/index");
    }
  }
}
