import { SELF, env } from "cloudflare:test";
import { expect } from "vitest";
import { createAccessToken, upsertAccount } from "../shared/db";
import { randomHex } from "../shared/keys";

export const BASE = "https://relay.mobdev.test";

export async function account(): Promise<{ id: string; token: string; tokenId: string }> {
  const id = "user_" + randomHex(6);
  await upsertAccount(env.DB, id, `${id}@example.com`);
  const { row, token } = await createAccessToken(env.DB, id, "Studio");
  return { id, token, tokenId: row.id };
}

export function secret(): string {
  return "mdh_" + randomHex(32);
}

export async function connect(hostSecret: string, accessToken: string | null, name = "studio"): Promise<Response> {
  const headers: Record<string, string> = { Upgrade: "websocket", Authorization: `Bearer ${hostSecret}` };
  if (accessToken) headers["X-Relay-Access"] = accessToken;
  return SELF.fetch(`${BASE}/v1/host/connect?name=${name}`, { headers });
}

/**
 * A fake Mac: answers every request with what it received. It never answers /v1/silent, and
 * answers /v1/slow after a little more than a second.
 */
export async function fakeMac(hostSecret: string, accessToken: string, name = "studio") {
  const response = await connect(hostSecret, accessToken, name);
  expect(response.status).toBe(101);
  const socket = response.webSocket!;
  socket.accept();
  const closed = new Promise<number>((resolve) => socket.addEventListener("close", (event) => resolve(event.code)));
  socket.addEventListener("message", async (event) => {
    const message = JSON.parse(event.data as string);
    if (message.type !== "request" || message.path === "/v1/silent") return;
    if (message.path === "/v1/slow") await new Promise((resolve) => setTimeout(resolve, 1100));
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

export async function agent(path: string, key: string, init: RequestInit = {}) {
  const response = await SELF.fetch(BASE + path, {
    ...init,
    headers: { Authorization: `Bearer ${key}`, ...(init.headers as Record<string, string>) },
  });
  return { status: response.status, headers: response.headers, body: (await response.json()) as Record<string, string> };
}
