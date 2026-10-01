import { createRouter } from "@tanstack/react-router";
import { initializeGT } from "gt-tanstack-start";
import gtConfig from "../gt.config.json";
import { currentLocale, loadTranslations } from "./lib/i18n";
import { localizePath, stripLocale } from "./lib/locales";
import { routeTree } from "./routeTree.gen";

initializeGT({ ...gtConfig, loadTranslations });

export function getRouter() {
  return createRouter({
    routeTree,
    scrollRestoration: true,
    defaultPreload: "intent",
    // /de/docs is the docs route in German; links on a German page point to German pages.
    rewrite: {
      input: ({ url }) => {
        url.pathname = stripLocale(url.pathname);
        return url;
      },
      output: ({ url }) => {
        url.pathname = localizePath(url.pathname, currentLocale());
        return url;
      },
    },
  });
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof getRouter>;
  }
}
