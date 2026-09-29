import { vi } from "vitest";
import { fakeAutumn } from "./fake-autumn";

// The relay under test has an Autumn key (vitest.config.ts), so it meters and bills against this
// fake. Durable Objects share the test's isolate, so the mock reaches them too. Responses must be
// created per call: an object made in one Durable Object cannot be read in another.
const realFetch = globalThis.fetch;
vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
  const request = new Request(input, init);
  if (new URL(request.url).hostname === "api.useautumn.com") return fakeAutumn.handle(request);
  return realFetch(input, init);
});
