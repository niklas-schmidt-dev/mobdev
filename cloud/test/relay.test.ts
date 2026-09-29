import { SELF, env } from "cloudflare:test";
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
import { clientKeyForSecret, randomHex } from "../shared/keys";

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
