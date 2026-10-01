/**
 * The site's languages and their URLs. English pages live at /docs, their German copies at /de/docs.
 * The router maps /de/… onto the same routes (router.tsx), and request middleware sends visitors on
 * an English page whose browser or earlier choice asks for German to the German copy (start.ts).
 * Keep in step with "locales" in gt.config.json.
 */
export const LOCALES = ["en", "de"] as const;
export type Locale = (typeof LOCALES)[number];
export const DEFAULT_LOCALE: Locale = "en";

/** Pages that exist in every language. Server routes such as /download and /api have no copies. */
const LOCALIZED_PATHS = new Set(["/", "/docs", "/privacy", "/dashboard", "/sign-out"]);

export function isLocalizedPath(path: string): boolean {
  return LOCALIZED_PATHS.has(path);
}

export function toLocale(value: string | undefined): Locale {
  return LOCALES.find((locale) => locale === value) ?? DEFAULT_LOCALE;
}

function prefixOf(pathname: string): Locale | undefined {
  const segment = pathname.split("/")[1];
  return LOCALES.find((locale) => locale !== DEFAULT_LOCALE && locale === segment);
}

/** The language a public path is in: /de/… is German, everything else English. */
export function localeOfPath(pathname: string): Locale {
  return prefixOf(pathname) ?? DEFAULT_LOCALE;
}

/** The route path behind a public path: /de/docs → /docs. */
export function stripLocale(pathname: string): string {
  const prefix = prefixOf(pathname);
  return prefix ? pathname.slice(prefix.length + 1) || "/" : pathname;
}

/** The public path of a page in a language: /docs → /de/docs. */
export function localizePath(path: string, locale: Locale): string {
  if (locale === DEFAULT_LOCALE || !isLocalizedPath(path)) return path;
  return path === "/" ? `/${locale}` : `/${locale}${path}`;
}
