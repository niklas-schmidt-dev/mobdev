// Key formats shared with the Mac app (RelayClient.swift) and the Go relay (relay/relay.go).
//   mdh_…  host secret, known only to the Mac
//   mdc_…  client key = "mdc_" + hex(HMAC-SHA256(host secret, "mobdev-relay-client-v1"))
//   mda_…  access token that lets a Mac use the hosted relay (issued in the dashboard)
// A space is sha256(client key): the Mac and its agents meet there without the relay
// storing either key.

const encoder = new TextEncoder();

function hex(buffer: ArrayBuffer): string {
  return [...new Uint8Array(buffer)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(value: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", encoder.encode(value)));
}

export async function clientKeyForSecret(secret: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  return "mdc_" + hex(await crypto.subtle.sign("HMAC", key, encoder.encode("mobdev-relay-client-v1")));
}

export function isHostSecret(value: string | null): value is string {
  return value !== null && value.startsWith("mdh_") && value.length >= 20 && value.length <= 200;
}

export function isClientKey(value: string | null): value is string {
  return value !== null && /^mdc_[0-9a-f]{64}$/.test(value);
}

export function isAccessToken(value: string | null): value is string {
  return value !== null && /^mda_[0-9a-f]{64}$/.test(value);
}

export async function spaceForClientKey(clientKey: string): Promise<string> {
  return sha256Hex(clientKey);
}

export async function spaceForSecret(secret: string): Promise<string> {
  return spaceForClientKey(await clientKeyForSecret(secret));
}

export function randomHex(bytes: number): string {
  return hex(crypto.getRandomValues(new Uint8Array(bytes)).buffer);
}

export function bearer(request: Request): string | null {
  const value = request.headers.get("Authorization");
  if (!value || !/^bearer /i.test(value)) return null;
  return value.slice(7).trim();
}

const hostNamePattern = /^[a-z0-9][a-z0-9._-]{0,63}$/;

export function hostName(value: string | null): string | null {
  const name = (value || "mac").toLowerCase();
  return hostNamePattern.test(name) ? name : null;
}
