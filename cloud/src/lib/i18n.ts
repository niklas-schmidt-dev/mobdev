import { createIsomorphicFn } from "@tanstack/react-start";
import { getLocale } from "gt-tanstack-start";
import { localeOfPath, toLocale, type Locale } from "./locales";

/**
 * The language of the page being rendered. On the server General Translation resolves it per
 * request from the path, then its cookie and Accept-Language; start.ts redirects to /de before
 * a German visitor sees an English path, so it always matches the path. The browser reads the path.
 */
export const currentLocale = createIsomorphicFn()
  .server((): Locale => toLocale(getLocale()))
  .client((): Locale => localeOfPath(window.location.pathname));

/**
 * Translations for General Translation, written by hand: `bunx gt generate` updates en.json from
 * the <T>, useGT and msg calls and adds new entries to de.json in English, to be translated there.
 */
export async function loadTranslations(locale: string) {
  return (await import(`../_gt/${locale}.json`)).default;
}
