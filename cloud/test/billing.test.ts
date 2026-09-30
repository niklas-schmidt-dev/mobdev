import { env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { exhausted, type Quota } from "../relay/src/billing";
import { carryOverUsage, removeAccount } from "../shared/accounts";
import { Autumn } from "../shared/autumn";
import { listAccessTokens, listHosts, upsertAccount } from "../shared/db";
import { clientKeyForSecret, sha256Hex, spaceForSecret } from "../shared/keys";
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
  fakeAutumn.deleteAnswer = null;
  fakeAutumn.beforeCustomer = null;
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

  it("allows only as many Macs as the plan when several connect at once", async () => {
    const { id, token } = await account();
    fakeAutumn.setPlan(id, FREE_PLAN);
    // All five wait at the plan lookup until each has arrived, so all pass the first count together.
    let arrived = 0;
    let release = () => {};
    const together = new Promise<void>((resolve) => (release = resolve));
    fakeAutumn.beforeCustomer = async () => {
      if (++arrived === 5) release();
      await together;
    };
    const responses = await Promise.all(
      Array.from({ length: 5 }, (_, i) => connect(secret(), token, `mac-${i}`)),
    ).finally(() => (fakeAutumn.beforeCustomer = null));
    for (const response of responses) response.webSocket?.accept();
    expect(responses.map((response) => response.status).sort()).toEqual([101, 429, 429, 429, 429]);
    const refused = responses.find((response) => response.status === 429)!;
    expect(((await refused.json()) as { error: string }).error).toContain("allows 1 connected Mac");
    expect((await listHosts(env.DB, id)).filter((host) => host.online === 1)).toHaveLength(1);
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

  it("sends what a Mac used after a failed batch once it disconnects", async () => {
    const { id, token } = await account();
    const hostSecret = secret();
    const mac = await fakeMac(hostSecret, token);
    const key = await clientKeyForSecret(hostSecret);
    for (let i = 0; i < 2; i++) await agent("/v1/status", key);
    fakeAutumn.down = true;
    await flush(hostSecret); // The batch of 2 waits for Autumn.
    await agent("/v1/status", key); // Counted next to that batch.

    mac.socket.close(1000, "bye");
    const stub = await space(hostSecret);
    const stored = () => runInDurableObject(stub, async (_, state) => (await state.storage.list({ prefix: "meter:" })).size);
    await until(async () => (await stored()) === 1);

    fakeAutumn.down = false;
    await flush(hostSecret);
    expect(fakeAutumn.trackedFor(id, FEATURES.requests)).toBe(3);
    expect(await stored()).toBe(0);
  });

  it("counts the time of requests still in flight against the allowance", async () => {
    const { id, token } = await account();
    fakeAutumn.setPlan(id, FREE_PLAN);
    fakeAutumn.customer(id).used.seconds = FREE_PLAN.activeHours * 3600 - 1; // One second left.
    const hostSecret = secret();
    const mac = await fakeMac(hostSecret, token);
    const key = await clientKeyForSecret(hostSecret);

    const silent = agent("/v1/silent", key); // Keeps the Mac busy; overlapping requests never let it idle.
    await sleep(1100);
    const over = await agent("/v1/status", key);
    expect(over.status).toBe(429);
    expect(over.body.error).toContain("active time");
    mac.socket.close(1000, "bye");
    expect((await silent).status).toBe(502);
  });

  it("sends the active time of a Mac that stays busy", async () => {
    const { id, token } = await account();
    const hostSecret = secret();
    const mac = await fakeMac(hostSecret, token);
    const key = await clientKeyForSecret(hostSecret);

    const silent = agent("/v1/silent", key);
    await sleep(1100);
    await flush(hostSecret); // Scheduled when the request started.
    expect(fakeAutumn.trackedFor(id, FEATURES.requests)).toBe(1);
    expect(fakeAutumn.trackedFor(id, FEATURES.activeSeconds)).toBe(1);
    expect(await runDurableObjectAlarm(await space(hostSecret))).toBe(true); // Still busy: the next one is due.
    mac.socket.close(1000, "bye");
    expect((await silent).status).toBe(502);
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

describe("deleting an account", () => {
  const autumn = new Autumn("am_sk_test_fake");
  const disconnect = async (tokenId: string, spaceIds: string[]) => {
    await exports.RelayAdmin.disconnectToken(tokenId, spaceIds);
  };
  const user = (id: string) => ({ id, email: `${id}@example.com` });
  const accountExists = async (id: string) =>
    (await env.DB.prepare("SELECT 1 FROM accounts WHERE id = ?1").bind(id).first()) !== null;
  const kept = async (id: string) =>
    env.DB.prepare("SELECT requests, active_seconds, deleted_at FROM deleted_usage WHERE user_hash = ?1")
      .bind(await sha256Hex(id))
      .first<{ requests: number; active_seconds: number; deleted_at: number | null }>();

  it("deletes nothing until Autumn has deleted the customer", async () => {
    const { id, token } = await account();
    fakeAutumn.setPlan(id, FREE_PLAN);
    const mac = await fakeMac(secret(), token);

    fakeAutumn.deleteAnswer = 503;
    await expect(removeAccount(env.DB, autumn, user(id), disconnect)).rejects.toThrow(/nothing was deleted/);
    expect(fakeAutumn.customers.has(id)).toBe(true);
    expect(await accountExists(id)).toBe(true);
    expect(await listAccessTokens(env.DB, id)).toHaveLength(1);
    expect((await listHosts(env.DB, id))[0]).toMatchObject({ online: 1 });

    fakeAutumn.deleteAnswer = null;
    await removeAccount(env.DB, autumn, user(id), disconnect);
    expect(fakeAutumn.customers.has(id)).toBe(false);
    expect(await mac.closed).toBe(4001);
    expect(await accountExists(id)).toBe(false);
    expect(await listAccessTokens(env.DB, id)).toEqual([]);
    expect(await listHosts(env.DB, id)).toEqual([]);

    // A retry after Autumn already deleted the customer goes through.
    fakeAutumn.setPlan(id, FREE_PLAN); // What get_or_create makes of the missing customer.
    fakeAutumn.deleteAnswer = 404;
    await expect(removeAccount(env.DB, autumn, user(id), disconnect)).resolves.toBeUndefined();
  });

  it("refuses while a paid plan keeps charging", async () => {
    const { id } = await account();
    fakeAutumn.setPlan(id, PRO_PLAN);
    await expect(removeAccount(env.DB, autumn, user(id), disconnect)).rejects.toThrow(/Cancel Pro/);
    expect(fakeAutumn.customers.has(id)).toBe(true);
    expect(await accountExists(id)).toBe(true);
  });

  it("carries this month's usage over to the user's next account", async () => {
    const { id } = await account();
    fakeAutumn.setPlan(id, FREE_PLAN);
    fakeAutumn.customer(id).used = { requests: 500, seconds: 600 };
    await removeAccount(env.DB, autumn, user(id), disconnect);
    expect(await kept(id)).toMatchObject({ requests: 500, active_seconds: 600, deleted_at: expect.any(Number) });

    // The same user signs up again.
    await upsertAccount(env.DB, id, user(id).email);
    fakeAutumn.down = true;
    await expect(carryOverUsage(env.DB, autumn, user(id))).rejects.toThrow(); // createToken refuses then.
    fakeAutumn.down = false;
    fakeAutumn.loseNextTrackResponse = true;
    await expect(carryOverUsage(env.DB, autumn, user(id))).rejects.toThrow();
    await carryOverUsage(env.DB, autumn, user(id));
    expect(fakeAutumn.customer(id).used).toEqual({ requests: 500, seconds: 600 });
    expect(await kept(id)).toBeNull();
    await carryOverUsage(env.DB, autumn, user(id));
    expect(fakeAutumn.customer(id).used).toEqual({ requests: 500, seconds: 600 });
  });

  it("does not count usage twice when the deletion failed", async () => {
    const { id } = await account();
    fakeAutumn.setPlan(id, FREE_PLAN);
    fakeAutumn.customer(id).used = { requests: 50, seconds: 0 };
    fakeAutumn.deleteAnswer = 503;
    await expect(removeAccount(env.DB, autumn, user(id), disconnect)).rejects.toThrow(/nothing was deleted/);
    fakeAutumn.deleteAnswer = null;
    await carryOverUsage(env.DB, autumn, user(id)); // The account lives on and has the usage itself.
    expect(fakeAutumn.customer(id).used.requests).toBe(50);
    expect(await kept(id)).toMatchObject({ requests: 50, deleted_at: null });
  });

  it("keeps nothing without usage, and forgets usage once the allowance renewed", async () => {
    const unused = await account();
    fakeAutumn.setPlan(unused.id, FREE_PLAN);
    await removeAccount(env.DB, autumn, user(unused.id), disconnect);
    expect(await kept(unused.id)).toBeNull();

    const { id } = await account();
    fakeAutumn.setPlan(id, FREE_PLAN);
    fakeAutumn.customer(id).used = { requests: 5, seconds: 0 };
    await removeAccount(env.DB, autumn, user(id), disconnect);
    await upsertAccount(env.DB, id, user(id).email);
    await carryOverUsage(env.DB, autumn, user(id), fakeAutumn.resetsAt);
    expect(fakeAutumn.customers.has(id)).toBe(false);
    expect(await kept(id)).toBeNull();
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
