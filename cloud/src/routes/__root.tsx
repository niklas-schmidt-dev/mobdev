/// <reference types="vite/client" />
import { HeadContent, Outlet, Scripts, createRootRoute } from "@tanstack/react-router";
import { GTProvider, getTranslationsSnapshot } from "gt-tanstack-start";
import type { ReactNode } from "react";
import { currentLocale } from "../lib/i18n";
import { SITE_URL, siteText } from "../lib/meta";
import appCss from "../styles.css?url";

// Pages override title, description, og:title and og:url and add their canonical and language
// links with pageHead(). og.png and apple-touch-icon.png come from scripts/og-image.ts.
export const Route = createRootRoute({
  // The language only changes with a full page load, so the translations are loaded once.
  loader: async () => {
    const locale = currentLocale();
    return { locale, translations: await getTranslationsSnapshot(locale) };
  },
  staleTime: Infinity,
  head: () => {
    const locale = currentLocale();
    const { title, description } = siteText(locale);
    return {
      meta: [
        { charSet: "utf-8" },
        { name: "viewport", content: "width=device-width, initial-scale=1" },
        { title },
        { name: "description", content: description },
        { property: "og:site_name", content: "Mobdev" },
        { property: "og:type", content: "website" },
        { property: "og:locale", content: locale === "de" ? "de_DE" : "en_US" },
        { property: "og:title", content: title },
        { property: "og:description", content: description },
        { property: "og:url", content: `${SITE_URL}/` },
        { property: "og:image", content: `${SITE_URL}/og.png` },
        { property: "og:image:width", content: "1200" },
        { property: "og:image:height", content: "630" },
        // The image's own words, which are English in both languages.
        { property: "og:image:alt", content: "Mobdev. Mobile development. All in one app." },
        { name: "twitter:card", content: "summary_large_image" },
      ],
      links: [
        { rel: "stylesheet", href: appCss },
        { rel: "icon", href: "/favicon.png", type: "image/png", sizes: "32x32" },
        { rel: "icon", href: "/favicon.svg?v=2", type: "image/svg+xml" },
        { rel: "apple-touch-icon", href: "/apple-touch-icon.png" },
      ],
    };
  },
  shellComponent: RootDocument,
  component: Outlet,
});

function RootDocument({ children }: { children: ReactNode }) {
  const { locale, translations } = Route.useLoaderData();
  return (
    <html lang={locale}>
      <head>
        <HeadContent />
        {/* Here rather than in `head`, which keeps only one meta tag per name. */}
        <meta name="theme-color" media="(prefers-color-scheme: light)" content="#ffffff" />
        <meta name="theme-color" media="(prefers-color-scheme: dark)" content="#000000" />
      </head>
      <body className="min-h-dvh bg-page font-sans text-ink">
        <GTProvider locale={locale} translations={translations}>
          {children}
        </GTProvider>
        <Scripts />
      </body>
    </html>
  );
}
