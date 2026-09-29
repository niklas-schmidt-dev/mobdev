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

/** Creates a token and returns it once in full; only its hash is kept. */
export async function createAccessToken(
  db: D1Database,
  accountId: string,
  name: string,
): Promise<{ row: AccessTokenRow; token: string }> {
  const trimmed = name.trim().slice(0, 60) || "Mac";
  const count = await db
    .prepare("SELECT COUNT(*) AS count FROM access_tokens WHERE account_id = ?1")
    .bind(accountId)
    .first<{ count: number }>();
  if ((count?.count ?? 0) >= MAX_TOKENS_PER_ACCOUNT) {
    throw new Error(`You can have at most ${MAX_TOKENS_PER_ACCOUNT} access tokens.`);
  }
  const token = "mda_" + randomHex(32);
  const row: AccessTokenRow = {
    id: "tok_" + randomHex(12),
    name: trimmed,
    prefix: token.slice(0, 12),
    created_at: Date.now(),
    last_used_at: null,
  };
  await db
    .prepare(
      "INSERT INTO access_tokens (id, account_id, name, token_hash, prefix, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )
    .bind(row.id, accountId, row.name, await sha256Hex(token), row.prefix, row.created_at)
    .run();
  return { row, token };
}

/** Deletes a token and returns the spaces its Macs are connected to, so they can be dropped. */
export async function deleteAccessToken(db: D1Database, accountId: string, tokenId: string): Promise<string[]> {
  const owned = await db
    .prepare("SELECT id FROM access_tokens WHERE id = ?1 AND account_id = ?2")
    .bind(tokenId, accountId)
    .first();
  if (!owned) return [];
  const { results } = await db
    .prepare("SELECT DISTINCT space_id FROM hosts WHERE token_id = ?1 AND online = 1")
    .bind(tokenId)
    .all<{ space_id: string }>();
  await db.batch([
    db.prepare("DELETE FROM access_tokens WHERE id = ?1").bind(tokenId),
    db.prepare("UPDATE hosts SET token_id = NULL WHERE token_id = ?1").bind(tokenId),
  ]);
  return results.map((row) => row.space_id);
}

/** Resolves an access token presented by a Mac. */
export async function findAccessToken(
  db: D1Database,
  token: string,
): Promise<{ id: string; account_id: string } | null> {
  return db
    .prepare("SELECT id, account_id FROM access_tokens WHERE token_hash = ?1")
    .bind(await sha256Hex(token))
    .first<{ id: string; account_id: string }>();
}

export async function touchAccessToken(db: D1Database, tokenId: string): Promise<void> {
  await db.prepare("UPDATE access_tokens SET last_used_at = ?1 WHERE id = ?2").bind(Date.now(), tokenId).run();
}

export async function recordHostOnline(
  db: D1Database,
  host: { spaceId: string; name: string; accountId: string; tokenId: string },
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO hosts (space_id, name, account_id, token_id, online, connected_at)
       VALUES (?1, ?2, ?3, ?4, 1, ?5)
       ON CONFLICT(space_id, name) DO UPDATE SET
         account_id = excluded.account_id, token_id = excluded.token_id, online = 1,
         connected_at = excluded.connected_at`,
    )
    .bind(host.spaceId, host.name, host.accountId, host.tokenId, Date.now())
    .run();
}

export async function recordHostOffline(db: D1Database, spaceId: string, name: string): Promise<void> {
  await db
    .prepare("UPDATE hosts SET online = 0, disconnected_at = ?1 WHERE space_id = ?2 AND name = ?3")
    .bind(Date.now(), spaceId, name)
    .run();
}

export async function listHosts(db: D1Database, accountId: string): Promise<HostRow[]> {
  const { results } = await db
    .prepare(
      `SELECT space_id, name, token_id, online, connected_at, disconnected_at FROM hosts
       WHERE account_id = ?1 ORDER BY online DESC, COALESCE(connected_at, 0) DESC LIMIT 100`,
    )
    .bind(accountId)
    .all<HostRow>();
  return results;
}

export async function forgetHost(db: D1Database, accountId: string, spaceId: string, name: string): Promise<void> {
  await db
    .prepare("DELETE FROM hosts WHERE account_id = ?1 AND space_id = ?2 AND name = ?3 AND online = 0")
    .bind(accountId, spaceId, name)
    .run();
}
