import { SELF, env, runInDurableObject } from "cloudflare:test";
import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import {
  createAccessToken,
  deleteAccessToken,
  listAccessTokens,
  listHosts,
  upsertAccount,
  MAX_TOKENS_PER_ACCOUNT,
} from "../shared/db";
import type { MacDevices } from "../shared/devices";
import { clientKeyForSecret, randomHex, spaceForSecret } from "../shared/keys";

const BASE = "https://relay.mobdev.test";

async function account(): Promise<{ id: string; token: string; tokenId: string }> {
  const id = "user_" + randomHex(6);
  await upsertAccount(env.DB, id, `${id}@example.com`);
  const { row, token } = await createAccessToken(env.DB, id, "Studio");
  return { id, token, tokenId: row.id };
}

function secret(): string {
  return "mdh_" + randomHex(32);
}

async function connect(hostSecret: string, accessToken: string | null, name = "studio"): Promise<Response> {
  const headers: Record<string, string> = { Upgrade: "websocket", Authorization: `Bearer ${hostSecret}` };
  if (accessToken) headers["X-Relay-Access"] = accessToken;
  return SELF.fetch(`${BASE}/v1/host/connect?name=${name}`, { headers });
}

/** A fake Mac: answers every request with what it received. */
async function fakeMac(hostSecret: string, accessToken: string, name = "studio") {
  const response = await connect(hostSecret, accessToken, name);
  expect(response.status).toBe(101);
  const socket = response.webSocket!;
  socket.accept();
  const closed = new Promise<number>((resolve) => socket.addEventListener("close", (event) => resolve(event.code)));
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data as string);
    if (message.type !== "request" || message.path === "/v1/silent") return;
    const echo = { host: name, method: message.method, path: message.path, query: message.query, body: atob(message.body) };
    socket.send(
      JSON.stringify({
        type: "response",
        id: message.id,
        status: 200,
        headers: { "Content-Type": "application/json", "Set-Cookie": "nope=1" },
        body: btoa(JSON.stringify(echo)),
      }),
    );
  });
  return { socket, closed };
}

async function agent(path: string, key: string, init: RequestInit = {}) {
  const response = await SELF.fetch(BASE + path, {
    ...init,
    headers: { Authorization: `Bearer ${key}`, ...(init.headers as Record<string, string>) },
  });
  return { status: response.status, headers: response.headers, body: (await response.json()) as Record<string, string> };
}

describe("keys", () => {
  it("derives the same client key as the Mac app and the Go relay", async () => {
    expect(await clientKeyForSecret("mdh_0123456789abcdef")).toBe(
      "mdc_0e465dea368fb6d8eb7a0c146da16c6a88b354216735682efcdf51a0ec3a9ab4",
    );
  });
});

describe("hosted relay", () => {
  it("requires an access token from the dashboard", async () => {
    expect((await connect(secret(), null)).status).toBe(403);
    expect((await connect(secret(), "mda_" + randomHex(32))).status).toBe(403);
    const { token } = await account();
    const clientKeyAsSecret = await clientKeyForSecret(secret());
    expect((await connect(clientKeyAsSecret, token)).status).toBe(401);
    expect((await connect(secret(), token, "Not A Name!")).status).toBe(400);
  });

  it("forwards agent requests to the Mac and back", async () => {
    const { id, token } = await account();
    const hostSecret = secret();
    await fakeMac(hostSecret, token);
    const key = await clientKeyForSecret(hostSecret);

    const answer = await agent("/mcp", key, {
      method: "POST",
      body: '{"jsonrpc":"2.0"}',
      headers: { "Content-Type": "application/json", "Mcp-Method": "tools/call" },
    });
    expect(answer.status).toBe(200);
    expect(answer.body).toMatchObject({ host: "studio", method: "POST", path: "/mcp", body: '{"jsonrpc":"2.0"}' });
    expect(answer.headers.get("Set-Cookie")).toBeNull();

    const routed = await agent("/h/studio/v1/status?x=1", key);
    expect(routed.body).toMatchObject({ path: "/v1/status", query: "x=1" });

    expect((await agent("/v1/relay/hosts", key)).body).toEqual({ hosts: ["studio"] });
    const hosts = await listHosts(env.DB, id);
    expect(hosts).toHaveLength(1);
    expect(hosts[0]).toMatchObject({ name: "studio", online: 1 });
  });

  it("rejects wrong keys and foreign paths", async () => {
    const { token } = await account();
    const hostSecret = secret();
    await fakeMac(hostSecret, token);
    const key = await clientKeyForSecret(hostSecret);
    expect((await agent("/mcp", hostSecret, { method: "POST" })).status).toBe(401);
    expect((await agent("/admin", key)).status).toBe(404);
    expect((await agent("/mcp", await clientKeyForSecret(secret()), { method: "POST" })).status).toBe(503);
  });

  it("asks for a name when several Macs share a key", async () => {
    const { token } = await account();
    const hostSecret = secret();
    await fakeMac(hostSecret, token, "office");
    await fakeMac(hostSecret, token, "home");
    const key = await clientKeyForSecret(hostSecret);
    const conflict = await agent("/mcp", key, { method: "POST" });
    expect(conflict.status).toBe(409);
    expect(conflict.body.error).toContain("home, office");
    expect((await agent("/h/office/mcp", key, { method: "POST" })).body.host).toBe("office");
    expect((await agent("/mcp", key, { method: "POST", headers: { "X-Mobdev-Host": "home" } })).body.host).toBe("home");
  });

  it("replaces an older connection with the same key and name", async () => {
    const { token } = await account();
    const hostSecret = secret();
    const first = await fakeMac(hostSecret, token);
    await fakeMac(hostSecret, token);
    expect(await first.closed).toBe(4000);
    const key = await clientKeyForSecret(hostSecret);
    expect((await agent("/mcp", key, { method: "POST" })).status).toBe(200);
  });

  it("answers keepalive pings", async () => {
    const { token } = await account();
    const response = await connect(secret(), token);
    const socket = response.webSocket!;
    socket.accept();
    const pong = new Promise<string>((resolve) => socket.addEventListener("message", (event) => resolve(event.data as string)));
    socket.send("ping");
    expect(await pong).toBe("pong");
  });

  it("fails pending requests when the Mac disconnects", async () => {
    const { token } = await account();
    const hostSecret = secret();
    const mac = await fakeMac(hostSecret, token);
    const key = await clientKeyForSecret(hostSecret);
    const pending = agent("/v1/silent", key);
    setTimeout(() => mac.socket.close(1001, "bye"), 50);
    expect((await pending).status).toBe(502);
  });

  it("disconnects Macs when their access token is revoked", async () => {
    const { id, token, tokenId } = await account();
    const hostSecret = secret();
    const mac = await fakeMac(hostSecret, token);
    const spaces = await deleteAccessToken(env.DB, id, tokenId);
    expect(spaces).toHaveLength(1);
    expect(await exports.RelayAdmin.disconnectToken(tokenId, spaces)).toBe(1);
    expect(await mac.closed).toBe(4001);
    expect((await listHosts(env.DB, id))[0]).toMatchObject({ online: 0 });
    expect((await connect(hostSecret, token)).status).toBe(403);
  });

  it("limits access tokens per account and scopes deletion to the owner", async () => {
    const { id, tokenId } = await account();
    for (let i = 1; i < MAX_TOKENS_PER_ACCOUNT; i++) await createAccessToken(env.DB, id, `Mac ${i}`);
    await expect(createAccessToken(env.DB, id, "one too many")).rejects.toThrow(/at most/);
    expect(await deleteAccessToken(env.DB, "user_someone_else", tokenId)).toEqual([]);
    expect(await listAccessTokens(env.DB, id)).toHaveLength(MAX_TOKENS_PER_ACCOUNT);
  });
});

const iPhone = {
  id: "00008120-000639440C13C01E",
  name: "iPhone von Niklas",
  model: "iPhone15,2",
  model_name: "iPhone 14 Pro",
  os_version: "27.0",
  device_class: "iPhone",
  screen: true,
  bluetooth: true,
  ready: true,
};

function sendDevices(socket: WebSocket, devices: unknown) {
  socket.send(JSON.stringify({ type: "devices", devices }));
}

async function accountDevices(token: string | null, init: RequestInit = {}) {
  const response = await SELF.fetch(`${BASE}/v1/account/devices`, {
    ...init,
    headers: token ? { Authorization: `Bearer ${token}` } : {},
  });
  return {
    status: response.status,
    body: (await response.json()) as { macs: MacDevices[]; ok?: boolean; error?: string },
  };
}

/** Polls until the relay has caught up with frames sent over a WebSocket. */
async function eventually<T>(read: () => Promise<T>, done: (value: T) => boolean): Promise<T> {
  let value = await read();
  for (let attempt = 0; attempt < 100 && !done(value); attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 20));
    value = await read();
  }
  return value;
}

describe("device registry", () => {
  it("stores the devices a Mac reports and lists them for its account", async () => {
    const { id, token } = await account();
    const hostSecret = secret();
    const mac = await fakeMac(hostSecret, token);
    expect((await accountDevices(token)).body.macs).toMatchObject([{ name: "studio", online: true, devices: [] }]);

    sendDevices(mac.socket, [{ ...iPhone, name: "x".repeat(150), serial: "dropped" }, { id: "ipad-1", device_class: "iPad" }]);
    const listed = await eventually(
      () => accountDevices(token),
      (result) => result.body.macs[0]?.devices.length === 2,
    );
    expect(listed.status).toBe(200);
    const devices = [
      { ...iPhone, name: "x".repeat(100) },
      { id: "ipad-1", name: "", model: "", model_name: "", os_version: "", device_class: "iPad", screen: false, bluetooth: false, ready: false },
    ];
    expect(listed.body).toEqual({
      macs: [{ name: "studio", online: true, connected_at: expect.any(Number), disconnected_at: null, devices }],
    });

    // Agents with the Mac's client key see the connected Macs of that key.
    const key = await clientKeyForSecret(hostSecret);
    expect((await agent("/v1/relay/devices", key)).body).toEqual({
      macs: [{ name: "studio", online: true, connected_at: expect.any(Number), disconnected_at: null, devices }],
    });
    expect((await listHosts(env.DB, id))[0]?.devices).toEqual(devices);

    // Every token of the account may list, and using it counts.
    const other = await createAccessToken(env.DB, id, "Laptop");
    expect((await accountDevices(other.token)).body.macs.map((entry) => entry.name)).toEqual(["studio"]);
    const tokens = await eventually(
      () => listAccessTokens(env.DB, id),
      (rows) => rows.some((row) => row.id === other.row.id && row.last_used_at !== null),
    );
    expect(tokens.find((row) => row.id === other.row.id)?.last_used_at).toEqual(expect.any(Number));

    // A Mac without iPhones sends an empty list.
    sendDevices(mac.socket, []);
    const emptied = await eventually(
      () => accountDevices(token),
      (result) => result.body.macs[0]?.devices.length === 0,
    );
    expect(emptied.body.macs[0]?.devices).toEqual([]);
  });

  it("never shows another account's Macs", async () => {
    const mine = await account();
    const theirs = await account();
    const myMac = await fakeMac(secret(), mine.token, "mine");
    const theirMac = await fakeMac(secret(), theirs.token, "theirs");
    sendDevices(myMac.socket, [iPhone]);
    sendDevices(theirMac.socket, [{ ...iPhone, id: "their-phone" }]);
    const own = await eventually(
      () => accountDevices(mine.token),
      (result) => result.body.macs[0]?.devices.length === 1,
    );
    expect(own.body.macs).toMatchObject([{ name: "mine", devices: [iPhone] }]);
    const other = await eventually(
      () => accountDevices(theirs.token),
      (result) => result.body.macs[0]?.devices.length === 1,
    );
    expect(other.body.macs).toMatchObject([{ name: "theirs", devices: [{ id: "their-phone" }] }]);
  });

  it("rejects missing, unknown and revoked access tokens", async () => {
    for (const token of [null, "mda_" + randomHex(32), await clientKeyForSecret(secret()), "not-a-token"]) {
      const answer = await accountDevices(token);
      expect(answer.status).toBe(401);
      expect(answer.body).toEqual({ ok: false, error: expect.any(String) });
    }
    const { id, token, tokenId } = await account();
    expect((await accountDevices(token)).status).toBe(200);
    expect((await accountDevices(token, { method: "POST" })).status).toBe(405);
    await deleteAccessToken(env.DB, id, tokenId);
    expect((await accountDevices(token)).status).toBe(401);
  });

  it("ignores malformed and oversized frames and keeps at most 32 devices", async () => {
    const { token } = await account();
    const hostSecret = secret();
    const mac = await fakeMac(hostSecret, token);
    const key = await clientKeyForSecret(hostSecret);
    sendDevices(mac.socket, [iPhone]);
    await eventually(
      () => accountDevices(token),
      (result) => result.body.macs[0]?.devices.length === 1,
    );

    const oversized = JSON.stringify({ type: "devices", devices: [{ ...iPhone, name: "x".repeat(17_000) }] });
    for (const frame of [
      '{"type":"devices"',
      '{"type":"devices"}',
      '{"type":"devices","devices":{}}',
      '{"type":"devices","devices":[null]}',
      JSON.stringify({ type: "devices", devices: [{ name: "no id" }] }),
      JSON.stringify({ type: "devices", devices: [{ ...iPhone, screen: "yes" }] }),
      JSON.stringify({ type: "devices", devices: [{ ...iPhone, id: 42 }] }),
      oversized,
      "null",
      "[]",
    ]) {
      mac.socket.send(frame);
    }
    // The Mac answers this after sending the frames above, so the relay has seen them all.
    expect((await agent("/v1/status", key)).status).toBe(200);
    expect((await accountDevices(token)).body.macs[0]?.devices).toEqual([iPhone]);
    expect((await agent("/v1/relay/devices", key)).body).toMatchObject({ macs: [{ devices: [iPhone] }] });

    const many = Array.from({ length: 40 }, (_, index) => ({ id: `device-${index}` }));
    sendDevices(mac.socket, many);
    const capped = await eventually(
      () => accountDevices(token),
      (result) => result.body.macs[0]?.devices.length !== 1,
    );
    expect(capped.body.macs[0]?.devices.map((device) => device.id)).toEqual(many.slice(0, 32).map((device) => device.id));
  });

  it("keeps the last list after the Mac disconnects", async () => {
    const { id, token } = await account();
    const hostSecret = secret();
    const mac = await fakeMac(hostSecret, token, "desk");
    sendDevices(mac.socket, [iPhone]);
    await eventually(
      () => accountDevices(token),
      (result) => result.body.macs[0]?.devices.length === 1,
    );
    const space = env.RELAY_SPACE.getByName(await spaceForSecret(hostSecret));
    const storedKeys = () => runInDurableObject(space, async (_, state) => [...(await state.storage.list()).keys()]);
    expect(await storedKeys()).toEqual(["devices:desk"]);
    mac.socket.close(1000, "bye");
    const offline = await eventually(
      () => accountDevices(token),
      (result) => result.body.macs[0]?.online === false,
    );
    expect(offline.body.macs).toEqual([
      { name: "desk", online: false, connected_at: expect.any(Number), disconnected_at: expect.any(Number), devices: [iPhone] },
    ]);
    expect((await listHosts(env.DB, id))[0]).toMatchObject({ online: 0, devices: [iPhone] });
    expect((await agent("/v1/relay/devices", await clientKeyForSecret(hostSecret))).body).toEqual({ macs: [] });
    // Only D1 keeps it, so forgetting the Mac or deleting the account removes it everywhere.
    expect(await storedKeys()).toEqual([]);
  });
});

describe("relay admin", () => {
  it("reports which Macs are really connected", async () => {
    const { token } = await account();
    const hostSecret = secret();
    const mac = await fakeMac(hostSecret, token, "desk");
    const space = await spaceForSecret(hostSecret);
    expect(await exports.RelayAdmin.connected([space, "0".repeat(64)])).toEqual({ [space]: ["desk"], ["0".repeat(64)]: [] });
    mac.socket.close(1000, "bye");
    let names = ["desk"];
    for (let attempt = 0; attempt < 100 && names.length > 0; attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 20));
      names = (await exports.RelayAdmin.connected([space]))[space] ?? [];
    }
    expect(names).toEqual([]);
  });
});
