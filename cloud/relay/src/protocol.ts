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
export const MAX_ONLINE_HOSTS_PER_ACCOUNT = 10;

export const FORWARDED_REQUEST_HEADERS = ["content-type", "accept", "mcp-protocol-version", "mcp-method", "mcp-name"];
export const FORWARDED_RESPONSE_HEADERS = ["content-type", "allow", "x-image-width", "x-image-height"];

export function errorResponse(status: number, message: string): RelayResponse {
  return {
    status,
    headers: { "content-type": "application/json" },
    body: btoa(JSON.stringify({ ok: false, error: message })),
  };
}

export function jsonError(status: number, message: string, headers: HeadersInit = {}): Response {
  return Response.json({ ok: false, error: message }, { status, headers });
}
