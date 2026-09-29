/// <reference types="vite/client" />
import { HeadContent, Outlet, Scripts, createRootRoute } from "@tanstack/react-router";
import type { ReactNode } from "react";
import { SITE_URL } from "../lib/meta";
import appCss from "../styles.css?url";

const title = "Mobdev — Give your AI agent a real iPhone";
const description =
  "Mobdev lets Claude Code, Codex and other agents see and tap a real iPhone from your Mac. No developer mode, nothing installed on the phone. Free and open source.";

// Pages override title, og:title and og:url with pageMeta(). og.png and apple-touch-icon.png come
// from scripts/og-image.ts.
export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title },
      { name: "description", content: description },
      { name: "theme-color", content: "#ffffff" },
      { property: "og:site_name", content: "Mobdev" },
      { property: "og:type", content: "website" },
      { property: "og:title", content: title },
      { property: "og:description", content: description },
      { property: "og:url", content: `${SITE_URL}/` },
      { property: "og:image", content: `${SITE_URL}/og.png` },
      { property: "og:image:width", content: "1200" },
      { property: "og:image:height", content: "630" },
      { property: "og:image:alt", content: "Mobdev. Your agent. A real iPhone." },
      { name: "twitter:card", content: "summary_large_image" },
    ],
    links: [
      { rel: "stylesheet", href: appCss },
      { rel: "icon", href: "/favicon.svg", type: "image/svg+xml" },
      { rel: "apple-touch-icon", href: "/apple-touch-icon.png" },
    ],
  }),
  shellComponent: RootDocument,
  component: Outlet,
});

function RootDocument({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <head>
        <HeadContent />
      </head>
      <body className="min-h-dvh bg-white font-sans text-ink">
        {children}
        <Scripts />
      </body>
    </html>
  );
}
