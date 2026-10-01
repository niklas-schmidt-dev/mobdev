import { LOCALES, localizePath, type Locale } from "./locales";

/** The public origin. Open Graph and canonical links need absolute URLs. */
export const SITE_URL = "https://mobdev.sh";

type PageText = { title: string; description: string };

/**
 * Title and description of each public page in each language, for search results and shared links.
 * The home page's are also the defaults of every other page. List every page in public/sitemap.xml.
 */
const pages = {
  "/": {
    en: {
      title: "Mobdev — AI agents for iPhone, iOS Simulator and Android",
      description:
        "Free, open-source Mac app that lets Claude Code, Codex or any MCP agent drive your iPhone, iOS simulators and Android: install builds, read logs, run tests.",
    },
    de: {
      title: "Mobdev — KI-Agenten für iPhone, iOS-Simulator und Android",
      description:
        "Kostenlose Open-Source-App für den Mac: Claude Code, Codex oder jeder MCP-Agent steuert dein iPhone, iOS-Simulatoren und Android, installiert Builds und liest Logs.",
    },
  },
  "/docs": {
    en: {
      title: "Docs — Mobdev: setup, MCP tools, simulators and Android",
      description:
        "Install Mobdev, set up your iPhone, connect Claude Code, Codex or any MCP agent, and use every tool on iOS simulators and Android, locally or through the relay.",
    },
    de: {
      title: "Doku — Mobdev: Einrichtung, MCP-Tools, Simulatoren und Android",
      description:
        "Mobdev installieren, das iPhone einrichten, Claude Code, Codex oder jeden MCP-Agenten verbinden und jedes Tool auf iOS-Simulatoren und Android nutzen, lokal oder per Relay.",
    },
  },
  "/privacy": {
    en: {
      title: "Privacy — Mobdev",
      description:
        "What the Mobdev Mac app, your account, the hosted relay and payments keep about you, and how to delete it.",
    },
    de: {
      title: "Datenschutz — Mobdev",
      description:
        "Was die Mobdev-App auf dem Mac, dein Konto, das gehostete Relay und die Zahlungen über dich speichern und wie du es löschst.",
    },
  },
} satisfies Record<string, Record<Locale, PageText>>;

export type PublicPage = keyof typeof pages;

/** The home page's title and description in a language. */
export function siteText(locale: Locale): PageText {
  return pages["/"][locale];
}

/**
 * The head of a public page in a language: its title and description plus the Open Graph tags that
 * differ from the site-wide ones in `__root.tsx`. The canonical link folds http://, ?query and
 * trailing-slash copies into this URL; the alternates point search engines to the other language.
 */
export function pageHead(path: PublicPage, locale: Locale) {
  const { title, description } = pages[path][locale];
  const url = (to: Locale) => `${SITE_URL}${localizePath(path, to)}`;
  return {
    meta: [
      { title },
      { name: "description", content: description },
      { property: "og:title", content: title },
      { property: "og:description", content: description },
      { property: "og:url", content: url(locale) },
    ],
    links: [
      { rel: "canonical", href: url(locale) },
      ...LOCALES.map((to) => ({ rel: "alternate", hrefLang: to, href: url(to) })),
      { rel: "alternate", hrefLang: "x-default", href: url("en") },
    ],
  };
}

/** The head of an account page: kept out of search results. */
export function privatePageHead(title: string) {
  return { meta: [{ title }, { name: "robots", content: "noindex" }] };
}
