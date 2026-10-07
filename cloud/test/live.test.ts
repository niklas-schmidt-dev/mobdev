import { SELF, env, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { LIVE_MAX_VIEWERS_PER_MAC, normalizeLiveInput, type LiveGrant } from "../shared/live";
import { FEATURES } from "../shared/plans";
import { MAX_SHARES_PER_ACCOUNT, createShare, deleteShare, findShare, listShares } from "../shared/shares";
import { clientKeyForSecret, spaceForSecret } from "../shared/keys";
import { fakeAutumn } from "./fake-autumn";
import { BASE, account, connect, secret } from "./helpers";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Message = Record<string, any>;

/** Collects a socket's JSON messages and its close. */
function inbox(socket: WebSocket) {
  const messages: Message[] = [];
  const closed = new Promise<{ code: number; reason: string }>((resolve) =>
    socket.addEventListener("close", (event) => resolve({ code: event.code, reason: event.reason })),
  );
  socket.addEventListener("message", (event) => {
    if (event.data === "pong") return;
    messages.push(JSON.parse(event.data as string));
  });
  return {
    messages,
    closed,
    of: (type: string) => messages.filter((message) => message.type === type),
    /** The next message of a type, waiting up to 3 s. */
    async next(type: string): Promise<Message> {
      for (let waited = 0; waited < 3000; waited += 10) {
        const index = messages.findIndex((message) => message.type === type);
        if (index >= 0) return messages.splice(index, 1)[0]!;
        await sleep(10);
      }
      throw new Error(`no ${type} arrived`);
    },
    send: (message: unknown) => socket.send(typeof message === "string" ? message : JSON.stringify(message)),
    socket,
  };
}

/** A Mac connected to the hosted relay that only records what the relay sends it. */
async function liveMac(name = "studio") {
  const { id, token } = await account();
  const hostSecret = secret();
  const response = await connect(hostSecret, token, name);
  expect(response.status).toBe(101);
  const socket = response.webSocket!;
  socket.accept();
  return { accountId: id, hostSecret, key: await clientKeyForSecret(hostSecret), spaceId: await spaceForSecret(hostSecret), ...inbox(socket) };
}

async function openViewer(path: string, credential: string, options: { protocol?: boolean } = {}) {
  const headers: Record<string, string> = { Upgrade: "websocket" };
  if (options.protocol) headers["Sec-WebSocket-Protocol"] = `mobdev-live, mobdev-auth.${credential}`;
  else headers.Authorization = `Bearer ${credential}`;
  return SELF.fetch(BASE + path, { headers });
}

async function viewer(path: string, credential: string, options: { protocol?: boolean } = {}) {
  const response = await openViewer(path, credential, options);
  expect(response.status, await (response.status === 101 ? "" : response.text())).toBe(101);
  const socket = response.webSocket!;
  socket.accept();
  return { response, ...inbox(socket) };
}

function frame(id: string, seq: number) {
  return { type: "live_frame", id, seq, width: 390, height: 844, jpeg: "/9j/AAAA" };
}

function grant(overrides: Partial<LiveGrant> = {}): LiveGrant {
  return { mac: "studio", device: "phone", mode: "control", viewer: { kind: "owner", label: null }, shareId: null, endsAt: null, ...overrides };
}

describe("live view", () => {
  it("streams the Mac's frames to a viewer with the client key", async () => {
    const mac = await liveMac();
    const watching = await viewer("/h/studio/v1/live?device=phone&fps=7", mac.key);
    expect(await watching.next("live")).toEqual({ type: "live", mac: "studio", device: "phone", mode: "control", fps: 7 });
    const start = await mac.next("live_start");
    expect(start).toMatchObject({ device: "phone", fps: 7, viewers: [{ kind: "key", control: true }] });

    mac.send(frame(start.id, 1));
    expect(await watching.next("live_frame")).toEqual(frame(start.id, 1));
    watching.send({ type: "ack", seq: 1 });
    mac.send(frame(start.id, 2));
    expect((await watching.next("live_frame")).seq).toBe(2);

    watching.socket.close(1000, "bye");
    expect(await mac.next("live_stop")).toEqual({ type: "live_stop", id: start.id });
  });

  it("takes the key as a subprotocol from browsers and names the protocol in its answer", async () => {
    const mac = await liveMac();
    const watching = await viewer("/v1/live", mac.key, { protocol: true });
    expect(watching.response.headers.get("Sec-WebSocket-Protocol")).toBe("mobdev-live");
    expect(await watching.next("live")).toMatchObject({ mac: "studio", device: "", fps: 5 });

    expect((await openViewer("/v1/live", await clientKeyForSecret(secret()))).status).toBe(503);
    expect((await openViewer("/v1/live", mac.hostSecret)).status).toBe(401);
    expect((await openViewer("/v1/live?fps=fast", mac.key)).status).toBe(400);
    expect((await SELF.fetch(`${BASE}/v1/live`, { headers: { Authorization: `Bearer ${mac.key}` } })).status).toBe(426);
  });

  it("shares one stream per device and skips frames for viewers that fall behind", async () => {
    const mac = await liveMac();
    const slow = await viewer("/v1/live?device=phone&fps=3", mac.key);
    const first = await mac.next("live_start");
    const fast = await viewer("/v1/live?device=phone&fps=9", mac.key);
    const second = await mac.next("live_start");
    expect(second.id).toBe(first.id);
    expect(second).toMatchObject({ fps: 9 });
    expect(second.viewers).toHaveLength(2);

    for (let seq = 1; seq <= 6; seq++) {
      mac.send(frame(first.id, seq));
      expect((await fast.next("live_frame")).seq).toBe(seq);
      fast.send({ type: "ack", seq });
    }
    await sleep(50);
    expect(slow.of("live_frame").map((message) => message.seq)).toEqual([1, 2]);
    slow.send({ type: "ack", seq: 2 });
    await sleep(50);
    mac.send(frame(first.id, 7));
    expect((await slow.next("live_frame")).seq).toBe(1); // Still in its inbox.
    await sleep(50);
    expect(slow.of("live_frame").map((message) => message.seq)).toEqual([2, 7]);

    fast.socket.close(1000, "bye");
    expect(await mac.next("live_start")).toMatchObject({ id: first.id, fps: 3 });
  });

  it("checks input and sends it to the Mac", async () => {
    const mac = await liveMac();
    const watching = await viewer("/v1/live?device=phone", mac.key);
    const start = await mac.next("live_start");
    watching.send({ type: "input", action: "tap", x: 0.5, y: 0.25, extra: "dropped" });
    expect(await mac.next("live_input")).toEqual({ type: "live_input", id: start.id, input: { action: "tap", x: 0.5, y: 0.25 } });
    watching.send({ type: "input", action: "text", text: "Grüße" });
    expect((await mac.next("live_input")).input).toEqual({ action: "text", text: "Grüße" });

    watching.send({ type: "input", action: "tap", x: 2, y: 0.5 });
    expect((await watching.next("live_error")).message).toContain("fractions");
    watching.send({ type: "input", action: "reboot" });
    expect((await watching.next("live_error")).message).toContain("action must be");
    for (let i = 0; i < 12; i++) watching.send({ type: "input", action: "home" });
    expect((await watching.next("live_error")).message).toContain("too many inputs");
  });

  it("ends a view when the Mac ends its stream or disconnects", async () => {
    const mac = await liveMac();
    const refused = await viewer("/v1/live?device=phone", mac.key);
    const start = await mac.next("live_start");
    mac.send({ type: "live_end", id: start.id, code: "disabled", reason: "Live view is off on this Mac." });
    expect(await refused.next("live_end")).toEqual({ type: "live_end", code: "disabled", reason: "Live view is off on this Mac." });
    expect((await refused.closed).code).toBe(4003);

    const watching = await viewer("/v1/live?device=phone", mac.key);
    await mac.next("live_start");
    mac.socket.close(1001, "bye");
    expect((await watching.next("live_end")).code).toBe("mac_offline");
    expect((await watching.closed).code).toBe(4002);
  });

  it("limits viewers per Mac", async () => {
    const mac = await liveMac();
    for (let i = 0; i < LIVE_MAX_VIEWERS_PER_MAC; i++) await viewer(`/v1/live?device=phone-${i % 3}`, mac.key);
    expect((await openViewer("/v1/live?device=phone-0", mac.key)).status).toBe(429);
  });

  it("renews streams on the Mac while someone watches", async () => {
    const mac = await liveMac();
    const watching = await viewer("/v1/live?device=phone", mac.key);
    await watching.next("live");
    const start = await mac.next("live_start");
    const space = env.RELAY_SPACE.getByName(mac.spaceId);
    expect(await runDurableObjectAlarm(space)).toBe(true);
    expect(await mac.next("live_start")).toEqual(start);
  });
});

describe("live view tickets", () => {
  it("are good once, for the Mac, device and mode the dashboard granted", async () => {
    const mac = await liveMac();
    const view = grant({ mode: "view", viewer: { kind: "share", label: "QA" } });
    const result = await exports.RelayAdmin.liveTicket(mac.spaceId, view);
    if (!("ticket" in result)) throw new Error(`no ticket: ${result.error}`);
    const watching = await viewer("/v1/live?device=ignored&fps=4", result.ticket, { protocol: true });
    expect(await watching.next("live")).toEqual({ type: "live", mac: "studio", device: "phone", mode: "view", fps: 4 });
    const start = await mac.next("live_start");
    expect(start.viewers).toEqual([{ kind: "share", label: "QA", control: false }]);
    watching.send({ type: "input", action: "home" });
    expect((await watching.next("live_error")).message).toBe("this live view is view only");
    expect(mac.of("live_input")).toEqual([]);

    expect((await openViewer("/v1/live", result.ticket, { protocol: true })).status).toBe(401);
    expect(await exports.RelayAdmin.liveTicket(mac.spaceId, grant({ mac: "elsewhere" }))).toEqual({ error: "offline" });
    const forged = `mdv_${mac.spaceId}${"0".repeat(32)}`;
    expect((await openViewer("/v1/live", forged, { protocol: true })).status).toBe(401);
  });

  it("let the owner control the device", async () => {
    const mac = await liveMac();
    const result = await exports.RelayAdmin.liveTicket(mac.spaceId, grant());
    if (!("ticket" in result)) throw new Error("no ticket");
    const watching = await viewer("/v1/live", result.ticket, { protocol: true });
    expect((await watching.next("live")).mode).toBe("control");
    expect((await mac.next("live_start")).viewers).toEqual([{ kind: "owner", control: true }]);
    watching.send({ type: "input", action: "home" });
    expect((await mac.next("live_input")).input).toEqual({ action: "home" });
  });

  it("end when their share link is revoked or expires", async () => {
    const mac = await liveMac();
    const created = await createShare(env.DB, mac.accountId, {
      spaceId: mac.spaceId,
      mac: "studio",
      device: "phone",
      mode: "control",
      label: "QA",
      hours: 1,
    });
    const share = created!.row;
    const ticket = async (overrides: Partial<LiveGrant> = {}) => {
      const result = await exports.RelayAdmin.liveTicket(
        mac.spaceId,
        grant({ viewer: { kind: "share", label: "QA" }, shareId: share.id, endsAt: share.expires_at, ...overrides }),
      );
      if (!("ticket" in result)) throw new Error("no ticket");
      return result.ticket;
    };

    // Revoked in the dashboard: the relay ends its views right away.
    const first = await viewer("/v1/live", await ticket(), { protocol: true });
    await mac.next("live_start");
    expect(await deleteShare(env.DB, mac.accountId, share.id)).toMatchObject({ id: share.id });
    expect(await exports.RelayAdmin.endShare(mac.spaceId, share.id)).toBe(1);
    expect((await first.next("live_end")).code).toBe("revoked");
    expect((await first.closed).code).toBe(4005);
    expect((await mac.next("live_stop")).type).toBe("live_stop");

    // If that call is lost, the next check finds the link gone.
    const again = (await createShare(env.DB, mac.accountId, {
      spaceId: mac.spaceId, mac: "studio", device: "phone", mode: "view", label: "QA", hours: 1,
    }))!.row;
    const second = await viewer("/v1/live", await ticket({ shareId: again.id }), { protocol: true });
    await deleteShare(env.DB, mac.accountId, again.id);
    await runDurableObjectAlarm(env.RELAY_SPACE.getByName(mac.spaceId));
    expect((await second.closed).code).toBe(4005);

    // Expired: the alarm goes off when the link ends.
    const third = await viewer("/v1/live", await ticket({ shareId: null, endsAt: Date.now() + 300 }), { protocol: true });
    await third.next("live");
    await sleep(350);
    await runDurableObjectAlarm(env.RELAY_SPACE.getByName(mac.spaceId));
    expect((await third.next("live_end")).code).toBe("expired");
    expect((await third.closed).code).toBe(4004);
  });
});

describe("live view metering", () => {
  it("counts watching as active time and each input as a request", async () => {
    const mac = await liveMac();
    fakeAutumn.setPlan(mac.accountId, fakeAutumn.defaultPlan);
    const watching = await viewer("/v1/live?device=phone", mac.key);
    await mac.next("live_start");
    watching.send({ type: "input", action: "home" });
    watching.send({ type: "input", action: "home" });
    await mac.next("live_input");
    await mac.next("live_input");
    await sleep(1100);
    watching.socket.close(1000, "bye");
    await mac.next("live_stop");
    const space = env.RELAY_SPACE.getByName(mac.spaceId);
    for (let attempt = 0; attempt < 50 && fakeAutumn.trackedFor(mac.accountId, FEATURES.activeSeconds) === 0; attempt++) {
      await runDurableObjectAlarm(space);
      await sleep(20);
    }
    expect(fakeAutumn.trackedFor(mac.accountId, FEATURES.activeSeconds)).toBeGreaterThanOrEqual(1);
    expect(fakeAutumn.trackedFor(mac.accountId, FEATURES.requests)).toBe(2);
  });

  it("refuses viewers once the active time is used up", async () => {
    const mac = await liveMac();
    await runInDurableObject(env.RELAY_SPACE.getByName(mac.spaceId), (_instance, state) => {
      for (const socket of state.getWebSockets("studio")) {
        const attachment = socket.deserializeAttachment();
        attachment.quota = { requests: 100, seconds: 0, resetsAt: Date.now() + 86_400_000, checkedAt: Date.now() };
        socket.serializeAttachment(attachment);
      }
    });
    const refused = await openViewer("/v1/live?device=phone", mac.key);
    expect(refused.status).toBe(429);
    expect(((await refused.json()) as { error: string }).error).toContain("active time");
  });
});

describe("share links", () => {
  it("belong to one of the account's Macs, expire and are revoked by their owner only", async () => {
    const mac = await liveMac();
    const other = await account();
    const input = { spaceId: mac.spaceId, mac: "studio", device: null, mode: "view" as const, label: " For Anna ", hours: 24 };
    expect(await createShare(env.DB, other.id, input)).toBeNull(); // Not their Mac.
    const created = await createShare(env.DB, mac.accountId, input);
    expect(created!.token).toMatch(/^mds_[0-9a-f]{64}$/);
    expect(created!.row).toMatchObject({ label: "For Anna", device: null, mode: "view" });
    expect(created!.row.expires_at - created!.row.created_at).toBe(24 * 3600_000);
    expect(await findShare(env.DB, created!.token)).toEqual(created!.row);
    expect(await findShare(env.DB, "mds_" + "0".repeat(64))).toBeNull();

    expect(await deleteShare(env.DB, other.id, created!.row.id)).toBeNull();
    expect(await listShares(env.DB, mac.accountId)).toEqual([created!.row]);
    // Expired links are dropped from the list.
    expect(await listShares(env.DB, mac.accountId, created!.row.expires_at)).toEqual([]);
    expect(await findShare(env.DB, created!.token)).toBeNull();
  });

  it("are limited per account", async () => {
    const mac = await liveMac();
    const input = { spaceId: mac.spaceId, mac: "studio", device: "phone", mode: "control" as const, label: "x", hours: 1 };
    await Promise.all(Array.from({ length: MAX_SHARES_PER_ACCOUNT }, () => createShare(env.DB, mac.accountId, input)));
    await expect(createShare(env.DB, mac.accountId, input)).rejects.toThrow(/at most 20 share links/);
  });
});

describe("live input checks", () => {
  it("match the Go relay's", () => {
    expect(normalizeLiveInput({ action: "swipe", from_x: 0.5, from_y: 0.8, to_x: 0.5, to_y: 0.2, duration: 9 })).toEqual({
      input: { action: "swipe", duration: 2, from_x: 0.5, from_y: 0.8, to_x: 0.5, to_y: 0.2 },
    });
    expect(normalizeLiveInput({ action: "key", key: "enter", modifiers: ["shift", "cmd"] })).toEqual({
      input: { action: "key", key: "enter", modifiers: ["cmd", "shift"] },
    });
    expect(normalizeLiveInput({ action: "scroll", direction: "down", amount: 50 })).toEqual({
      input: { action: "scroll", amount: 20, direction: "down", x: 0.5, y: 0.5 },
    });
    expect(normalizeLiveInput({ action: "text", text: "a".repeat(1001) })).toHaveProperty("error");
    expect(normalizeLiveInput({ action: "key", key: "a", modifiers: ["cmd", "cmd"] })).toHaveProperty("error");
    expect(normalizeLiveInput({ action: "tap", x: 0.5 })).toHaveProperty("error");
  });
});
