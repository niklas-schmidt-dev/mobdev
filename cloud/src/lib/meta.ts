/** The public origin. Open Graph needs absolute URLs. */
export const SITE_URL = "https://mobdev.sh";

/**
 * The title of a page plus the Open Graph tags that differ from the site-wide ones in `__root.tsx`,
 * so a shared link to it shows its own title instead of the home page's.
 */
export function pageMeta(title: string, path: `/${string}`) {
  return [
    { title },
    { property: "og:title", content: title },
    { property: "og:url", content: `${SITE_URL}${path}` },
  ];
}
