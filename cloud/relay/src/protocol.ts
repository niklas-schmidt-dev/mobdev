// Frames on a Mac's WebSocket, JSON text like the Go relay's (../../../relay):
// relay → Mac: {"type":"request","id","method","path","query","headers","body"} and
//   {"type":"cancel","id"} when the relay stopped waiting for that request (REQUEST_TIMEOUT_MS), so
//   the Mac can stop working on it. Macs that do not know "cancel" ignore it.
// Mac → relay: {"type":"response","id","status","headers","body"}, {"type":"devices","devices"}
//   (shared/devices.ts) and "ping", which the runtime answers with "pong".
// Frames of an unknown type are ignored in both directions.

/** An agent request on its way to a Mac. Bodies are base64. */
export interface RelayRequest {
  name: string | null;
  method: string;
  path: string;
  query: string;
  headers: Record<string, string>;
  body: string;
}

/** A Mac's answer. Bodies are base64. */
export interface RelayResponse {
  status: number;
  headers: Record<string, string>;
  body: string;
}

/** Close codes sent to Macs. The Mac app reconnects unless its key is rejected. */
export const CLOSE_REPLACED = 4000;
export const CLOSE_REVOKED = 4001;

export const MAX_BODY_BYTES = 16 * 1024 * 1024;
export const REQUEST_TIMEOUT_MS = 90_000;
export const MAX_HOSTS_PER_SPACE = 32;
/** Connected Macs per account, whatever the plan allows. */
export const MAX_ONLINE_HOSTS_PER_ACCOUNT = 10;
/** Requests a Mac may have in flight; more wait with 429. The phone does one thing at a time anyway. */
export const MAX_IN_FLIGHT_PER_MAC = 4;
/** Agent requests per client key and window. Must match AGENT_LIMIT in wrangler.jsonc. */
export const AGENT_BURST = { limit: 50, seconds: 10 } as const;

/** Usage is sent to Autumn this long after a request finishes, in one batch per Mac. */
export const USAGE_FLUSH_MS = 30_000;
/** Wait before sending usage again when Autumn could not be reached. */
export const USAGE_RETRY_MS = 60_000;
/** An exhausted or unknown allowance is asked for again at most this often, so upgrades apply. */
export const QUOTA_REFRESH_MS = 60_000;
/**
 * A connection checks at most this often, on its next request, that its access token still exists.
 * Revoking a token disconnects its Macs right away; this catches connections that call missed.
 */
export const TOKEN_RECHECK_MS = 60_000;

export const DASHBOARD_URL = "https://mobdev.sh/dashboard";

// Any method and any body pass, byte for byte: bodies travel base64 in the frames, so a build
// uploaded in chunks (PUT /v1/uploads/<id>, application/octet-stream, up to 8 MiB each) reaches the
// Mac unchanged. The Go relay forwards the same headers.
export const FORWARDED_REQUEST_HEADERS = ["content-type", "accept", "mcp-protocol-version", "mcp-method", "mcp-name"];
export const FORWARDED_RESPONSE_HEADERS = ["content-type", "allow", "retry-after", "x-image-width", "x-image-height"];

export function errorResponse(status: number, message: string, headers: Record<string, string> = {}): RelayResponse {
  return {
    status,
    headers: { "content-type": "application/json", ...headers },
    body: btoa(JSON.stringify({ ok: false, error: message })),
  };
}

export function jsonError(status: number, message: string, headers: HeadersInit = {}): Response {
  return Response.json({ ok: false, error: message }, { status, headers });
}

/** The account already has as many Macs connected as it may. The Mac app waits 5 minutes after a 429. */
export function macLimitError(macs: number): Response {
  const allowed = macs === 1 ? "1 connected Mac" : `${macs} connected Macs`;
  return jsonError(429, `this account's plan allows ${allowed}; disconnect one or upgrade at ${DASHBOARD_URL}`);
}
