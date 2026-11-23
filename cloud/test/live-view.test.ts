import { describe, expect, it } from "vitest";
import { offlineRetryDelay, watchVisibility } from "../src/lib/live-view";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/** A stand-in for `document` whose visibility a test switches. */
class FakePage extends EventTarget {
  hidden: boolean;
  constructor(hidden = false) {
    super();
    this.hidden = hidden;
  }
  show(visible: boolean) {
    this.hidden = !visible;
    this.dispatchEvent(new Event("visibilitychange"));
  }
}

function watch(page: FakePage, after: number) {
  const calls: string[] = [];
  const stop = watchVisibility(page, after, {
    hidden: () => calls.push("hidden"),
    visible: () => calls.push("visible"),
  });
  return { calls, stop };
}

describe("browser live view", () => {
  it("asks again less often while the Mac stays offline, at most a minute apart", () => {
    expect([1, 2, 3, 4, 5, 6, 20].map(offlineRetryDelay)).toEqual([5000, 10_000, 20_000, 40_000, 60_000, 60_000, 60_000]);
  });

  it("pauses once the tab has been hidden long enough, and says when it shows again", async () => {
    const page = new FakePage();
    const { calls, stop } = watch(page, 50);

    page.show(false);
    await sleep(20);
    page.show(true); // Back before the pause: a waiting retry may run now.
    await sleep(60);
    expect(calls).toEqual(["visible"]);

    page.show(false);
    page.show(false); // Repeated events do not restart the wait.
    await sleep(80);
    expect(calls).toEqual(["visible", "hidden"]);
    page.show(true);
    expect(calls).toEqual(["visible", "hidden", "visible"]);

    stop();
    page.show(false);
    await sleep(80);
    expect(calls).toEqual(["visible", "hidden", "visible"]);
  });

  it("pauses a view opened in a background tab", async () => {
    const { calls, stop } = watch(new FakePage(true), 30);
    await sleep(60);
    expect(calls).toEqual(["hidden"]);
    stop();
  });
});
