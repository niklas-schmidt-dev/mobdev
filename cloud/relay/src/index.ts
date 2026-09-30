import { Buffer } from "node:buffer";
import { WorkerEntrypoint } from "cloudflare:workers";
import { cacheMacsAllowed, findAccessToken, listHosts, touchAccessToken, type AccessRow } from "../../shared/db";
import type { MacDevices } from "../../shared/devices";
import { bearer, hostName, isAccessToken, isClientKey, isHostSecret, spaceForClientKey, spaceForSecret } from "../../shared/keys";
import { FREE_PLAN } from "../../shared/plans";
import { autumnFor, hasRelayPlan, macsAllowed, quotaFromCustomer, type Quota } from "./billing";
import type { RelayEnv } from "./env";
import {
  AGENT_BURST,
  DASHBOARD_URL,
  FORWARDED_REQUEST_HEADERS,
  FORWARDED_RESPONSE_HEADERS,
  MAX_BODY_BYTES,
  MAX_ONLINE_HOSTS_PER_ACCOUNT,
  jsonError,
  macLimitError,
} from "./protocol";

export { RelaySpace } from "./space";

/**
 * The hosted Mobdev relay (relay.mobdev.sh). Same protocol as the self-hosted Go relay,
 * plus access tokens from the dashboard so only signed-up accounts can register Macs, and a list
 * of every Mac and iPhone of an account (/v1/account/devices).
 */
export default {
  async fetch(request: Request, env: RelayEnv, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/healthz") return new Response("ok\n", { headers: { "content-type": "text/plain" } });
    if (url.pathname === "/v1/host/connect") return connectHost(request, url, env, ctx);
    if (url.pathname === "/v1/account/devices") return accountDevices(request, env, ctx);
    return forwardToHost(request, url, env);
  },
} satisfies ExportedHandler<RelayEnv>;

/**
 * Every Mac of the access token's account with the devices it last reported, for the Mac app.
 * Reads D1 only, so it does not wake the account's spaces.
 */
async function accountDevices(request: Request, env: RelayEnv, ctx: ExecutionContext): Promise<Response> {
  if (request.method !== "GET") return jsonError(405, "use GET", { Allow: "GET" });
  const token = bearer(request);
  const access = isAccessToken(token) ? await findAccessToken(env.DB, token) : null;
  if (!access) return jsonError(401, "missing, unknown or revoked access token", { "WWW-Authenticate": "Bearer" });
  ctx.waitUntil(touchAccessToken(env.DB, access.id));
  const macs: MacDevices[] = (await listHosts(env.DB, access.account_id)).map((host) => ({
    name: host.name,
    online: host.online === 1,
    connected_at: host.connected_at,
    disconnected_at: host.disconnected_at,
    devices: host.devices,
  }));
  return Response.json({ macs }, { headers: { "Cache-Control": "no-store" } });
}

async function connectHost(request: Request, url: URL, env: RelayEnv, ctx: ExecutionContext): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    return jsonError(426, "expected a WebSocket upgrade");
  }
  const token = request.headers.get("X-Relay-Access");
  if (!isAccessToken(token)) return jsonError(403, `this relay needs an access token from ${DASHBOARD_URL}`);
  const secret = bearer(request);
  if (!isHostSecret(secret)) return jsonError(401, "missing or malformed host secret");
  const name = hostName(url.searchParams.get("name"));
  if (!name) return jsonError(400, "host name must be 1-64 characters of a-z, 0-9, '.', '_' or '-'");

  const spaceId = await spaceForSecret(secret);
  if (!(await env.CONNECT_LIMIT.limit({ key: `${spaceId}/${name}` })).success) {
    return jsonError(429, "this Mac reconnected too often; try again in a minute", { "Retry-After": "60" });
  }
  const access = await findAccessToken(env.DB, token);
  if (!access) return jsonError(403, `this relay needs an access token from ${DASHBOARD_URL}`);

  const plan = await planForConnect(env, ctx, access);
  const macs = Math.min(plan.macs, MAX_ONLINE_HOSTS_PER_ACCOUNT);
  // A quick answer without waking the space. RelaySpace decides for good when it records the Mac.
  const online = await env.DB.prepare(
    "SELECT COUNT(*) AS count FROM hosts WHERE account_id = ?1 AND online = 1 AND NOT (space_id = ?2 AND name = ?3)",
  )
    .bind(access.account_id, spaceId, name)
    .first<{ count: number }>();
  if ((online?.count ?? 0) >= macs) return macLimitError(macs);
  ctx.waitUntil(touchAccessToken(env.DB, access.id));

  const headers = new Headers({
    Upgrade: "websocket",
    "X-Mobdev-Space": spaceId,
    "X-Mobdev-Name": name,
    "X-Mobdev-Account": access.account_id,
    "X-Mobdev-Token": access.id,
    "X-Mobdev-Macs": String(macs),
  });
  if (plan.billing) headers.set("X-Mobdev-Billing", JSON.stringify(plan.billing));
  return env.RELAY_SPACE.getByName(spaceId).fetch(new Request(url, { headers }));
}

/**
 * How many Macs the account may connect and, when the relay bills, what it may still use this
 * period. Creates the Autumn customer on the Free plan if needed. While Autumn is unreachable, the
 * Mac limit it last reported applies and requests pass until it answers again.
 */
async function planForConnect(
  env: RelayEnv,
  ctx: ExecutionContext,
  access: AccessRow,
): Promise<{ macs: number; billing: { quota: Quota | null } | null }> {
  const autumn = autumnFor(env);
  if (!autumn) return { macs: MAX_ONLINE_HOSTS_PER_ACCOUNT, billing: null };
  try {
    const customer = await autumn.customer(access.account_id, access.email);
    if (!hasRelayPlan(customer)) throw new Error("Autumn has no relay plan for this account; push autumn.config.ts");
    const macs = Math.min(macsAllowed(customer), MAX_ONLINE_HOSTS_PER_ACCOUNT);
    if (macs !== access.macs_allowed) ctx.waitUntil(cacheMacsAllowed(env.DB, access.account_id, macs));
    return { macs, billing: { quota: quotaFromCustomer(customer) } };
  } catch (error) {
    console.warn("could not read the plan from Autumn; using the last known one", error);
    return { macs: access.macs_allowed ?? FREE_PLAN.macs, billing: { quota: null } };
  }
}

async function forwardToHost(request: Request, url: URL, env: RelayEnv): Promise<Response> {
  const key = bearer(request);
  if (!isClientKey(key)) return jsonError(401, "missing or malformed client key", { "WWW-Authenticate": "Bearer" });
  const spaceId = await spaceForClientKey(key);
  if (!(await env.AGENT_LIMIT.limit({ key: spaceId })).success) {
    return jsonError(
      429,
      `too many requests for this Mac key: at most ${AGENT_BURST.limit} every ${AGENT_BURST.seconds} seconds`,
      { "Retry-After": String(AGENT_BURST.seconds) },
    );
  }
  const space = env.RELAY_SPACE.getByName(spaceId);

  if (url.pathname === "/v1/relay/hosts" && request.method === "GET") {
    return Response.json({ hosts: await space.hosts() });
  }
  if (url.pathname === "/v1/relay/devices" && request.method === "GET") {
    return Response.json({ macs: await space.devices() });
  }

  let path = url.pathname;
  let name = request.headers.get("X-Mobdev-Host")?.toLowerCase() || null;
  if (path.startsWith("/h/")) {
    const rest = path.slice(3);
    const slash = rest.indexOf("/");
    if (slash <= 0) return jsonError(404, "use /h/<mac-name>/<path>");
    name = rest.slice(0, slash).toLowerCase();
    path = rest.slice(slash);
  }
  if (path !== "/mcp" && !path.startsWith("/v1/")) return jsonError(404, "not found");

  const length = Number(request.headers.get("Content-Length") ?? 0);
  if (length > MAX_BODY_BYTES) return jsonError(413, "request body too large");
  const body = await readBody(request, MAX_BODY_BYTES);
  if (!body) return jsonError(413, "request body too large");

  const headers: Record<string, string> = {};
  for (const [header, value] of request.headers) {
    if (FORWARDED_REQUEST_HEADERS.includes(header) || header.startsWith("mcp-param-")) headers[header] = value;
  }
  const answer = await space.forward({
    name,
    method: request.method,
    path,
    query: url.search.slice(1),
    headers,
    body: body.toString("base64"),
  });

  const responseHeaders = new Headers();
  for (const [header, value] of Object.entries(answer.headers)) {
    if (FORWARDED_RESPONSE_HEADERS.includes(header.toLowerCase())) responseHeaders.set(header, value);
  }
  const status = answer.status >= 200 && answer.status <= 599 ? answer.status : 502;
  const responseBody = status === 204 || status === 304 ? null : Buffer.from(answer.body, "base64");
  return new Response(responseBody, { status, headers: responseHeaders });
}

/**
 * Reads a request body, or returns null and stops reading as soon as it grows past `limit` bytes.
 * Content-Length is optional, so the size is only known while reading.
 */
async function readBody(request: Request, limit: number): Promise<Buffer | null> {
  if (!request.body) return Buffer.alloc(0);
  const reader: ReadableStreamDefaultReader<Uint8Array> = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) return Buffer.concat(chunks, size);
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
}

/** Called by the website over a service binding, never over HTTP. */
export class RelayAdmin extends WorkerEntrypoint<RelayEnv> {
  /** Which Macs are really connected, per space. The D1 flags can be stale after a restart. */
  async connected(spaceIds: string[]): Promise<Record<string, string[]>> {
    const entries = await Promise.all(
      spaceIds.map(async (spaceId) => [spaceId, await this.env.RELAY_SPACE.getByName(spaceId).hosts()] as const),
    );
    return Object.fromEntries(entries);
  }

  /** Disconnects the Macs that use a revoked access token. */
  async disconnectToken(tokenId: string, spaceIds: string[]): Promise<number> {
    const closed = await Promise.all(
      spaceIds.map((spaceId) => this.env.RELAY_SPACE.getByName(spaceId).revokeToken(tokenId)),
    );
    return closed.reduce((sum, count) => sum + count, 0);
  }
}
