import { parseStoredDevices, type Device } from "./devices";
import { UserError } from "./errors";
import { randomHex, sha256Hex } from "./keys";

export interface AccessTokenRow {
  id: string;
  name: string;
  prefix: string;
  created_at: number;
  last_used_at: number | null;
}

export interface HostRow {
  space_id: string;
  name: string;
  token_id: string | null;
  online: number;
  connected_at: number | null;
  disconnected_at: number | null;
  /** The iPhones and iPads the Mac last reported; kept after it disconnects. */
  devices: Device[];
  devices_updated_at: number | null;
}

export const MAX_TOKENS_PER_ACCOUNT = 20;

export async function upsertAccount(db: D1Database, id: string, email: string): Promise<void> {
  await db
    .prepare(
      "INSERT INTO accounts (id, email, created_at) VALUES (?1, ?2, ?3) ON CONFLICT(id) DO UPDATE SET email = excluded.email",
    )
    .bind(id, email, Date.now())
    .run();
}

export async function listAccessTokens(db: D1Database, accountId: string): Promise<AccessTokenRow[]> {
  const { results } = await db
    .prepare(
      "SELECT id, name, prefix, created_at, last_used_at FROM access_tokens WHERE account_id = ?1 ORDER BY created_at DESC",
    )
    .bind(accountId)
    .all<AccessTokenRow>();
  return results;
}

/**
 * Creates a token and returns it once in full; only its hash is kept. Counting and inserting are
 * one statement, so concurrent calls cannot pass the limit together.
 */
export async function createAccessToken(
  db: D1Database,
  accountId: string,
  name: string,
): Promise<{ row: AccessTokenRow; token: string }> {
  const trimmed = name.trim().slice(0, 60) || "Mac";
  const token = "mda_" + randomHex(32);
  const row: AccessTokenRow = {
    id: "tok_" + randomHex(12),
    name: trimmed,
    prefix: token.slice(0, 12),
    created_at: Date.now(),
    last_used_at: null,
  };
  const { meta } = await db
    .prepare(
      `INSERT INTO access_tokens (id, account_id, name, token_hash, prefix, created_at)
       SELECT ?1, ?2, ?3, ?4, ?5, ?6 WHERE (SELECT COUNT(*) FROM access_tokens WHERE account_id = ?2) < ?7`,
    )
    .bind(row.id, accountId, row.name, await sha256Hex(token), row.prefix, row.created_at, MAX_TOKENS_PER_ACCOUNT)
    .run();
  if (meta.changes === 0) {
    throw new UserError(
      "token-limit",
      `You can have at most ${MAX_TOKENS_PER_ACCOUNT} access tokens.`,
      MAX_TOKENS_PER_ACCOUNT,
    );
  }
  return { row, token };
}

/**
 * Deletes a token and returns the spaces of every Mac that used it, so they can be dropped. One
 * batch: a Mac that registers after it cannot use the token anymore (RelaySpace checks again after
 * accepting it), one that registered before is in the list. Offline Macs are listed too because
 * the online flag can be stale.
 */
export async function deleteAccessToken(db: D1Database, accountId: string, tokenId: string): Promise<string[]> {
  const owned = await db
    .prepare("SELECT id FROM access_tokens WHERE id = ?1 AND account_id = ?2")
    .bind(tokenId, accountId)
    .first();
  if (!owned) return [];
  const [, spaces] = await db.batch<{ space_id: string }>([
    db.prepare("DELETE FROM access_tokens WHERE id = ?1").bind(tokenId),
    db.prepare("SELECT DISTINCT space_id FROM hosts WHERE token_id = ?1").bind(tokenId),
    db.prepare("UPDATE hosts SET token_id = NULL WHERE token_id = ?1").bind(tokenId),
  ]);
  return (spaces?.results ?? []).map((row) => row.space_id);
}

/** Whether an access token still exists, i.e. was not revoked. */
export async function accessTokenExists(db: D1Database, tokenId: string): Promise<boolean> {
  return (await db.prepare("SELECT 1 FROM access_tokens WHERE id = ?1").bind(tokenId).first()) !== null;
}

export interface AccessRow {
  id: string;
  account_id: string;
  email: string;
  /** How many Macs the plan allowed when Autumn last answered; used while it cannot be reached. */
  macs_allowed: number | null;
}

/** Resolves an access token presented by a Mac. */
export async function findAccessToken(db: D1Database, token: string): Promise<AccessRow | null> {
  return db
    .prepare(
      `SELECT t.id, t.account_id, a.email, a.macs_allowed FROM access_tokens t
       JOIN accounts a ON a.id = t.account_id WHERE t.token_hash = ?1`,
    )
    .bind(await sha256Hex(token))
    .first<AccessRow>();
}

export async function cacheMacsAllowed(db: D1Database, accountId: string, macs: number): Promise<void> {
  await db.prepare("UPDATE accounts SET macs_allowed = ?1 WHERE id = ?2").bind(macs, accountId).run();
}

export async function touchAccessToken(db: D1Database, tokenId: string): Promise<void> {
  await db.prepare("UPDATE access_tokens SET last_used_at = ?1 WHERE id = ?2").bind(Date.now(), tokenId).run();
}

/**
 * Records a connected Mac, unless the account already has `macs` other Macs online. Checking and
 * writing are one statement, so concurrent connections cannot pass the limit together. False when
 * nothing was written. `connectedAt` identifies the connection for recordHostOffline.
 */
export async function recordHostOnline(
  db: D1Database,
  host: { spaceId: string; name: string; accountId: string; tokenId: string; connectedAt: number },
  macs: number,
): Promise<boolean> {
  // SQLite needs the WHERE to tell the SELECT's end from ON CONFLICT.
  const { meta } = await db
    .prepare(
      `INSERT INTO hosts (space_id, name, account_id, token_id, online, connected_at)
       SELECT ?1, ?2, ?3, ?4, 1, ?5
       WHERE (SELECT COUNT(*) FROM hosts WHERE account_id = ?3 AND online = 1 AND NOT (space_id = ?1 AND name = ?2)) < ?6
       ON CONFLICT(space_id, name) DO UPDATE SET
         account_id = excluded.account_id, token_id = excluded.token_id, online = 1,
         connected_at = excluded.connected_at`,
    )
    .bind(host.spaceId, host.name, host.accountId, host.tokenId, host.connectedAt, macs)
    .run();
  return meta.changes > 0;
}

/**
 * Marks one connection of a Mac offline. A newer connection of the same Mac has another
 * `connected_at` and stays online. False when that connection was no longer the recorded one.
 */
export async function recordHostOffline(
  db: D1Database,
  spaceId: string,
  name: string,
  connectedAt: number | null,
): Promise<boolean> {
  const { meta } = await db
    .prepare(
      "UPDATE hosts SET online = 0, disconnected_at = ?1 WHERE space_id = ?2 AND name = ?3 AND connected_at IS ?4",
    )
    .bind(Date.now(), spaceId, name, connectedAt)
    .run();
  return meta.changes > 0;
}

/**
 * Stores the devices a Mac reported. The timestamp check keeps a slower write of an older list
 * from overwriting a newer one.
 */
export async function recordHostDevices(
  db: D1Database,
  spaceId: string,
  name: string,
  devices: Device[],
  updatedAt: number,
): Promise<void> {
  await db
    .prepare(
      `UPDATE hosts SET devices = ?1, devices_updated_at = ?2
       WHERE space_id = ?3 AND name = ?4 AND COALESCE(devices_updated_at, 0) <= ?2`,
    )
    .bind(JSON.stringify(devices), updatedAt, spaceId, name)
    .run();
}

/** The account's Macs, online ones first, then the most recently connected. */
export async function listHosts(db: D1Database, accountId: string): Promise<HostRow[]> {
  const { results } = await db
    .prepare(
      `SELECT space_id, name, token_id, online, connected_at, disconnected_at, devices, devices_updated_at FROM hosts
       WHERE account_id = ?1 ORDER BY online DESC, COALESCE(connected_at, 0) DESC LIMIT 100`,
    )
    .bind(accountId)
    .all<Omit<HostRow, "devices"> & { devices: string | null }>();
  return results.map((row) => ({ ...row, devices: parseStoredDevices(row.devices) }));
}

/** Forgets an offline Mac, and the live view links to it with it. */
export async function forgetHost(db: D1Database, accountId: string, spaceId: string, name: string): Promise<void> {
  const { meta } = await db
    .prepare("DELETE FROM hosts WHERE account_id = ?1 AND space_id = ?2 AND name = ?3 AND online = 0")
    .bind(accountId, spaceId, name)
    .run();
  if (meta.changes === 0) return;
  await db
    .prepare("DELETE FROM live_shares WHERE account_id = ?1 AND space_id = ?2 AND mac = ?3")
    .bind(accountId, spaceId, name)
    .run();
}
