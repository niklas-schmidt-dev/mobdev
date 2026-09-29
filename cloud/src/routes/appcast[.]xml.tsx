import { createFileRoute } from "@tanstack/react-router";
import { latestAsset } from "../lib/releases";

/** mobdev.sh/appcast.xml: the Sparkle update feed of the newest release. */
export const Route = createFileRoute("/appcast.xml")({
  server: {
    handlers: {
      GET: async () => {
        const upstream = await fetch(latestAsset("appcast.xml"), { cf: { cacheTtl: 300 } });
        if (!upstream.ok) return new Response("No release yet.\n", { status: 404 });
        return new Response(upstream.body, {
          headers: { "Content-Type": "application/xml; charset=utf-8", "Cache-Control": "public, max-age=300" },
        });
      },
    },
  },
});
