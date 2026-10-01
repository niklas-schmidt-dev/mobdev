import { createCsrfMiddleware, createMiddleware, createStart } from "@tanstack/react-start";
import { authkitMiddleware } from "@workos/authkit-tanstack-react-start";
import { getLocale, gtMiddleware } from "gt-tanstack-start";
import { DEFAULT_LOCALE, isLocalizedPath, localizePath, toLocale } from "./lib/locales";
import { authConfigured } from "./server/auth-config";

// Reject cross-site calls to server functions before any session work runs.
const csrfMiddleware = createCsrfMiddleware({
  filter: (ctx) => ctx.handlerType === "serverFn",
});

/**
 * Sends a visitor on an English page to its German copy when General Translation resolved German
 * for them: from the language cookie of their last choice or visit, else from Accept-Language.
 * Crawlers send neither, so search engines see each page under its own URL.
 */
const localeRedirectMiddleware = createMiddleware().server(({ request, pathname, next }) => {
  // isLocalizedPath only knows the English paths: /docs, not /de/docs.
  if (request.method !== "GET" || !isLocalizedPath(pathname)) return next();
  const locale = toLocale(getLocale());
  if (locale === DEFAULT_LOCALE) return next();
  const url = new URL(request.url);
  url.pathname = localizePath(pathname, locale);
  return new Response(null, {
    status: 307,
    headers: { Location: url.toString(), Vary: "Accept-Language, Cookie", "Cache-Control": "private, no-store" },
  });
});

// AuthKit rejects every request when its settings are missing, so it only runs once they are set.
// gtMiddleware resolves each request's language for the redirect, the pages and server functions.
export const startInstance = createStart(() => ({
  requestMiddleware: [
    csrfMiddleware,
    ...(authConfigured() ? [authkitMiddleware()] : []),
    gtMiddleware,
    localeRedirectMiddleware,
  ],
}));
