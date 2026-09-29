import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Tests run inside the Workers runtime against the relay worker, its Durable Object and a
// local D1 with the real migrations. Autumn is a fake (test/fake-autumn.ts).
export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./relay/wrangler.jsonc" },
        miniflare: { bindings: { TEST_MIGRATIONS: migrations, AUTUMN_SECRET_KEY: "am_sk_test_fake" } },
      }),
    ],
    test: {
      include: ["test/**/*.test.ts"],
      setupFiles: ["test/apply-migrations.ts", "test/setup-autumn.ts"],
    },
  };
});
