import { createFileRoute } from "@tanstack/react-router";
import { latestAsset } from "../lib/releases";

/** mobdev.sh/download: the newest disk image, or the build instructions before the first release. */
export const Route = createFileRoute("/download")({
  server: {
    handlers: {
      GET: async ({ request }: { request: Request }) => {
        const dmg = latestAsset("Mobdev.dmg");
        const probe = await fetch(dmg, { method: "HEAD", redirect: "manual", cf: { cacheTtl: 300 } });
        const target = probe.status >= 300 && probe.status < 400 ? dmg : new URL("/docs#install", request.url).toString();
        return new Response(null, { status: 302, headers: { Location: target, "Cache-Control": "public, max-age=300" } });
      },
    },
  },
});
