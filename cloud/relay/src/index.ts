import { Buffer } from "node:buffer";
import { WorkerEntrypoint } from "cloudflare:workers";
import { findAccessToken, touchAccessToken } from "../../shared/db";
import { bearer, hostName, isAccessToken, isClientKey, isHostSecret, spaceForClientKey, spaceForSecret } from "../../shared/keys";
import type { RelayEnv } from "./env";
import {
  FORWARDED_REQUEST_HEADERS,
  FORWARDED_RESPONSE_HEADERS,
  MAX_BODY_BYTES,
  MAX_ONLINE_HOSTS_PER_ACCOUNT,
  jsonError,
} from "./protocol";

export { RelaySpace } from "./space";

/**
 * The hosted Mobdev relay (relay.mobdev.sh). Same protocol as the self-hosted Go relay,
 * plus access tokens from the dashboard so only signed-up accounts can register Macs.
 */
export default {
  async fetch(request: Request, env: RelayEnv, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/healthz") return new Response("ok\n", { headers: { "content-type": "text/plain" } });
    if (url.pathname === "/v1/host/connect") return connectHost(request, url, env, ctx);
    return forwardToHost(request, url, env);
  },
} satisfies ExportedHandler<RelayEnv>;

async function connectHost(request: Request, url: URL, env: RelayEnv, ctx: ExecutionContext): Promise<Response> {
  if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
    return jsonError(426, "expected a WebSocket upgrade");
  }
  const token = request.headers.get("X-Relay-Access");
  const access = isAccessToken(token) ? await findAccessToken(env.DB, token) : null;
  if (!access) return jsonError(403, "this relay needs an access token from https://mobdev.sh/dashboard");
  const secret = bearer(request);
  if (!isHostSecret(secret)) return jsonError(401, "missing or malformed host secret");
  const name = hostName(url.searchParams.get("name"));
  if (!name) return jsonError(400, "host name must be 1-64 characters of a-z, 0-9, '.', '_' or '-'");

  const spaceId = await spaceForSecret(secret);
  const online = await env.DB.prepare(
    "SELECT COUNT(*) AS count FROM hosts WHERE account_id = ?1 AND online = 1 AND NOT (space_id = ?2 AND name = ?3)",
  )
    .bind(access.account_id, spaceId, name)
    .first<{ count: number }>();
  if ((online?.count ?? 0) >= MAX_ONLINE_HOSTS_PER_ACCOUNT) {
    return jsonError(429, `at most ${MAX_ONLINE_HOSTS_PER_ACCOUNT} Macs can be connected per account`);
  }
  ctx.waitUntil(touchAccessToken(env.DB, access.id));

  const headers = new Headers({
    Upgrade: "websocket",
    "X-Mobdev-Space": spaceId,
    "X-Mobdev-Name": name,
    "X-Mobdev-Account": access.account_id,
    "X-Mobdev-Token": access.id,
  });
  return env.RELAY_SPACE.getByName(spaceId).fetch(new Request(url, { headers }));
}

async function forwardToHost(request: Request, url: URL, env: RelayEnv): Promise<Response> {
  const key = bearer(request);
  if (!isClientKey(key)) return jsonError(401, "missing or malformed client key", { "WWW-Authenticate": "Bearer" });
  const space = env.RELAY_SPACE.getByName(await spaceForClientKey(key));

  if (url.pathname === "/v1/relay/hosts" && request.method === "GET") {
    return Response.json({ hosts: await space.hosts() });
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
  const body = await request.arrayBuffer();
  if (body.byteLength > MAX_BODY_BYTES) return jsonError(413, "request body too large");

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
    body: Buffer.from(body).toString("base64"),
  });

  const responseHeaders = new Headers();
  for (const [header, value] of Object.entries(answer.headers)) {
    if (FORWARDED_RESPONSE_HEADERS.includes(header.toLowerCase())) responseHeaders.set(header, value);
  }
  const status = answer.status >= 200 && answer.status <= 599 ? answer.status : 502;
  const responseBody = status === 204 || status === 304 ? null : Buffer.from(answer.body, "base64");
  return new Response(responseBody, { status, headers: responseHeaders });
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
