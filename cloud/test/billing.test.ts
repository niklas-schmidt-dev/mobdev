import { env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { exhausted, type Quota } from "../relay/src/billing";
import { clientKeyForSecret, spaceForSecret } from "../shared/keys";
import { FEATURES, FREE_PLAN, PRO_PLAN } from "../shared/plans";
import { fakeAutumn } from "./fake-autumn";
import { account, agent, connect, fakeMac, secret } from "./helpers";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function space(hostSecret: string) {
  return env.RELAY_SPACE.getByName(await spaceForSecret(hostSecret));
}

/** Runs the usage flush the relay scheduled after the last request. */
async function flush(hostSecret: string): Promise<void> {
  const stub = await space(hostSecret);
  for (let attempt = 0; attempt < 50; attempt++) {
    if (await runDurableObjectAlarm(stub)) return;
    await sleep(20);
  }
  throw new Error("the relay scheduled no usage flush");
}

async function until(check: () => Promise<boolean>): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (await check()) return;
    await sleep(20);
  }
  throw new Error("timed out");
}

/** Waits for the start of a rate limit window, so a burst does not straddle two. */
async function windowStart(seconds: number, room: number): Promise<void> {
  const into = Date.now() % (seconds * 1000);
  if (into > (seconds - room) * 1000) await sleep(seconds * 1000 - into + 50);
}

async function macsAllowed(accountId: string): Promise<number | null> {
  const row = await env.DB.prepare("SELECT macs_allowed FROM accounts WHERE id = ?1")
    .bind(accountId)
    .first<{ macs_allowed: number | null }>();
  return row?.macs_allowed ?? null;
}

beforeEach(() => {
  fakeAutumn.down = false;
  fakeAutumn.loseNextTrackResponse = false;
});

describe("plans", () => {
  it("creates the Autumn customer when a Mac connects and allows as many Macs as the plan", async () => {
    const { id, token } = await account();
    fakeAutumn.setPlan(id, FREE_PLAN);
    await fakeMac(secret(), token, "one");
    expect(fakeAutumn.customers.get(id)?.email).toBe(`${id}@example.com`);

    const second = await connect(secret(), token, "two");
    expect(second.status).toBe(429);
    expect(((await second.json()) as { error: string }).error).toContain("allows 1 connected Mac");

    fakeAutumn.setPlan(id, PRO_PLAN);
    await fakeMac(secret(), token, "two");
    await fakeMac(secret(), token, "three");
    expect((await connect(secret(), token, "four")).status).toBe(429);
    await until(async () => (await macsAllowed(id)) === PRO_PLAN.macs);
  });

  it("does not lock anyone out when Autumn has no plan for the account", async () => {
    const { id, token } = await account();
    fakeAutumn.withoutPlan.add(id);
    const hostSecret = secret();
    await fakeMac(hostSecret, token);
    const key = await clientKeyForSecret(hostSecret);
    for (let i = 0; i < 3; i++) expect((await agent("/v1/status", key)).status).toBe(200);
    await flush(hostSecret); // Autumn refuses the usage; requests keep passing.
    expect((await agent("/v1/status", key)).status).toBe(200);
    expect((await connect(secret(), token, "second")).status).toBe(429); // Free's Mac limit applies.
  });

  it("keeps the last known Mac limit while Autumn is down", async () => {
    const { id, token } = await account();
    await fakeMac(secret(), token, "one");
    await until(async () => (await macsAllowed(id)) === PRO_PLAN.macs);

    fakeAutumn.down = true;
    await fakeMac(secret(), token, "two");
    await fakeMac(secret(), token, "three");
    expect((await connect(secret(), token, "four")).status).toBe(429);
  });
});

describe("metering", () => {
  it("sends requests and active time to Autumn in one batch", async () => {
    const { id, token } = await account();
    const hostSecret = secret();
    await fakeMac(hostSecret, token);
    const key = await clientKeyForSecret(hostSecret);

    for (let i = 0; i < 3; i++) expect((await agent("/v1/status", key)).status).toBe(200);
    expect((await agent("/v1/slow", key)).status).toBe(200);
    expect((await agent("/v1/relay/hosts", key)).status).toBe(200); // Answered by the relay, not counted.
    expect(fakeAutumn.trackedFor(id, FEATURES.requests)).toBe(0);

    await flush(hostSecret);
    expect(fakeAutumn.trackedFor(id, FEATURES.requests)).toBe(4);
    expect(fakeAutumn.trackedFor(id, FEATURES.activeSeconds)).toBe(1);

    expect((await agent("/v1/status", key)).status).toBe(200);
    await flush(hostSecret);
    expect(fakeAutumn.trackedFor(id, FEATURES.requests)).toBe(5);
  });

  it("stops at the monthly allowance and picks up an upgrade", async () => {
    const { id, token } = await account();
    fakeAutumn.setPlan(id, { ...FREE_PLAN, requests: 3 });
    const hostSecret = secret();
    await fakeMac(hostSecret, token);
    const key = await clientKeyForSecret(hostSecret);

    for (let i = 0; i < 3; i++) expect((await agent("/v1/status", key)).status).toBe(200);
    const over = await agent("/v1/status", key);
    expect(over.status).toBe(429);
    expect(over.body.error).toContain("used up its hosted relay requests until");
    expect(Number(over.headers.get("Retry-After"))).toBeGreaterThan(0);

    fakeAutumn.setPlan(id, PRO_PLAN);
    await flush(hostSecret);
    expect(fakeAutumn.trackedFor(id, FEATURES.requests)).toBe(3);
    expect((await agent("/v1/status", key)).status).toBe(200);
  });

  it("lets requests through while Autumn is down and applies the allowance once it answers", async () => {
    const { id, token } = await account();
    fakeAutumn.setPlan(id, { ...FREE_PLAN, requests: 2 });
    fakeAutumn.down = true;
    const hostSecret = secret();
    await fakeMac(hostSecret, token);
    const key = await clientKeyForSecret(hostSecret);

    for (let i = 0; i < 3; i++) expect((await agent("/v1/status", key)).status).toBe(200);
    await flush(hostSecret);
    expect(fakeAutumn.tracked.filter((t) => t.customer === id)).toHaveLength(0);

    fakeAutumn.down = false;
    await flush(hostSecret); // The retry the failed flush scheduled.
    expect(fakeAutumn.trackedFor(id, FEATURES.requests)).toBe(3);
    expect((await agent("/v1/status", key)).status).toBe(429);
  });

  it("never counts a batch twice when Autumn's answer gets lost", async () => {
    const { id, token } = await account();
    const hostSecret = secret();
    await fakeMac(hostSecret, token);
    const key = await clientKeyForSecret(hostSecret);

    for (let i = 0; i < 2; i++) await agent("/v1/status", key);
    fakeAutumn.loseNextTrackResponse = true;
    await flush(hostSecret);
    await flush(hostSecret);
    expect(fakeAutumn.trackedFor(id, FEATURES.requests)).toBe(2);

    await agent("/v1/status", key);
    await flush(hostSecret);
    expect(fakeAutumn.trackedFor(id, FEATURES.requests)).toBe(3);
  });

  it("keeps the usage of a Mac that disconnects until Autumn has it", async () => {
    const { id, token } = await account();
    const hostSecret = secret();
    const mac = await fakeMac(hostSecret, token);
    const key = await clientKeyForSecret(hostSecret);
    for (let i = 0; i < 2; i++) await agent("/v1/status", key);

    mac.socket.close(1000, "bye");
    const stub = await space(hostSecret);
    const stored = () => runInDurableObject(stub, async (_, state) => (await state.storage.list({ prefix: "meter:" })).size);
    await until(async () => (await stored()) === 1);

    await flush(hostSecret);
    expect(fakeAutumn.trackedFor(id, FEATURES.requests)).toBe(2);
    expect(await stored()).toBe(0);
  });
});

describe("rate limits", () => {
  it("limits the requests a Mac has in flight", async () => {
    const { token } = await account();
    const hostSecret = secret();
    const mac = await fakeMac(hostSecret, token);
    const key = await clientKeyForSecret(hostSecret);

    const silent = Array.from({ length: 4 }, () => agent("/v1/silent", key));
    await sleep(200);
    const fifth = await agent("/v1/status", key);
    expect(fifth.status).toBe(429);
    expect(fifth.body.error).toContain("already handling 4 requests");
    expect(fifth.headers.get("Retry-After")).toBe("1");

    mac.socket.close(1000, "bye");
    expect((await Promise.all(silent)).map((answer) => answer.status)).toEqual([502, 502, 502, 502]);
  });

  it("limits bursts of agent requests per client key", async () => {
    const key = await clientKeyForSecret(secret());
    await windowStart(10, 4);
    const statuses: number[] = [];
    for (let i = 0; i < 51; i++) statuses.push((await agent("/v1/relay/hosts", key)).status);
    expect(statuses.slice(0, 50).every((status) => status === 200)).toBe(true);
    expect(statuses[50]).toBe(429);
  });

  it("limits how often a Mac reconnects", async () => {
    const { token } = await account();
    const hostSecret = secret();
    await windowStart(60, 5);
    for (let i = 0; i < 10; i++) expect((await connect(hostSecret, token)).status).toBe(101);
    const refused = await connect(hostSecret, token);
    expect(refused.status).toBe(429);
    expect(refused.headers.get("Retry-After")).toBe("60");
  });
});

describe("allowance", () => {
  const quota: Quota = { requests: 10, seconds: 100, resetsAt: Date.now() + 86_400_000, checkedAt: Date.now() };

  it("counts what the relay has not confirmed yet", () => {
    expect(exhausted(quota, { requests: 9, seconds: 0 })).toBeNull();
    expect(exhausted(quota, { requests: 10, seconds: 0 })?.message).toContain("requests");
    expect(exhausted(quota, { requests: 0, seconds: 100 })?.message).toContain("active time");
    expect(exhausted(quota, { requests: 10, seconds: 0 })?.retryAfter).toBeGreaterThan(86_000);
  });

  it("lets requests through when the allowance is unknown, unlimited or renewed", () => {
    expect(exhausted(null, { requests: 99, seconds: 99 })).toBeNull();
    expect(exhausted({ ...quota, requests: null, seconds: null }, { requests: 99, seconds: 999 })).toBeNull();
    expect(exhausted({ ...quota, resetsAt: Date.now() - 1 }, { requests: 99, seconds: 0 })).toBeNull();
  });
});
