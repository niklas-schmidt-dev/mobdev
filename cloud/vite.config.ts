import { cloudflare } from "@cloudflare/vite-plugin";
import tailwindcss from "@tailwindcss/vite";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [
    cloudflare({ viteEnvironment: { name: "ssr" }, persistState: { path: ".wrangler/state" } }),
    tailwindcss(),
    tanstackStart(),
    react(),
  ],
  // Portless serves the dev server on https://<name>.localhost and forwards to this port.
  server: { allowedHosts: [".localhost"] },
});
