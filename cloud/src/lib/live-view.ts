// When the browser's live view (components/live.tsx) lets go and when it asks again. Plain logic,
// so tests run it without a browser.

/**
 * A view whose tab has been hidden this long closes: the Mac stops streaming and the account's
 * active time stops counting. It opens again when the tab shows.
 */
export const PAUSE_HIDDEN_MS = 30_000;
const OFFLINE_RETRY_MS = 5000;
const OFFLINE_RETRY_MAX_MS = 60_000;

/**
 * How long to wait before asking again after the `attempt`th answer (from 1) that the Mac is
 * offline: 5 s, then twice as long each time, up to a minute. Each ask is a ticket request.
 */
export function offlineRetryDelay(attempt: number): number {
  return Math.min(OFFLINE_RETRY_MAX_MS, OFFLINE_RETRY_MS * 2 ** Math.max(0, attempt - 1));
}

/** The part of `document` this needs; tests pass a stand-in. */
export interface Page extends EventTarget {
  readonly hidden: boolean;
}

/**
 * Calls `hidden` once the page has been hidden for `after` ms in a row, also when it starts
 * hidden, and `visible` each time it shows again. Returns a function that stops watching.
 */
export function watchVisibility(page: Page, after: number, on: { hidden(): void; visible(): void }): () => void {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const changed = () => {
    if (page.hidden) {
      timer ??= setTimeout(() => {
        timer = undefined;
        on.hidden();
      }, after);
    } else {
      clearTimeout(timer);
      timer = undefined;
      on.visible();
    }
  };
  if (page.hidden) changed();
  page.addEventListener("visibilitychange", changed);
  return () => {
    clearTimeout(timer);
    page.removeEventListener("visibilitychange", changed);
  };
}
