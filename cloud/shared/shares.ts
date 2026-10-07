import { parseStoredDevices, type Device } from "./devices";
import { UserError } from "./errors";
import { randomHex, sha256Hex } from "./keys";
import type { LiveMode } from "./live";

// Share links for live view (migrations/0005_live_shares.sql). The dashboard creates and revokes
// them; the share page turns one into a relay ticket; the relay checks that a link it serves still
// exists. A link is "mds_" + 64 hex characters, shown once; only its SHA-256 hash is stored.

export interface ShareRow {
  id: string;
  space_id: string;
  mac: string;
  /** Null: every device of the Mac. */
  device: string | null;
  mode: LiveMode;
  label: string;
  created_at: number;
  expires_at: number;
}

export const MAX_SHARES_PER_ACCOUNT = 20;
/** How long a link may last, in hours: an hour, a day or a week. */
export const SHARE_HOURS = [1, 24, 168] as const;

const sharePattern = /^mds_[0-9a-f]{64}$/;

export function isShareToken(value: string | null | undefined): value is string {
  return typeof value === "string" && sharePattern.test(value);
}

const columns = "id, space_id, mac, device, mode, label, created_at, expires_at";

/**
 * Creates a link to one of the account's Macs, or one device of it, and returns it once in full.
 * Counting and inserting are one statement, so concurrent calls cannot pass the limit together.
 * Null when the account has no such Mac.
 */
export async function createShare(
  db: D1Database,
  accountId: string,
  input: { spaceId: string; mac: string; device: string | null; mode: LiveMode; label: string; hours: number },
  now = Date.now(),
): Promise<{ row: ShareRow; token: string } | null> {
  const owned = await db
    .prepare("SELECT 1 FROM hosts WHERE account_id = ?1 AND space_id = ?2 AND name = ?3")
    .bind(accountId, input.spaceId, input.mac)
    .first();
  if (!owned) return null;
  const hours = SHARE_HOURS.includes(input.hours as (typeof SHARE_HOURS)[number]) ? input.hours : 24;
  const token = "mds_" + randomHex(32);
  const row: ShareRow = {
    id: "shr_" + randomHex(12),
    space_id: input.spaceId,
    mac: input.mac,
    device: input.device ? input.device.slice(0, 200) : null,
    mode: input.mode === "control" ? "control" : "view",
    label: input.label.trim().slice(0, 60) || "Shared view",
    created_at: now,
    expires_at: now + hours * 3600_000,
  };
  const { meta } = await db
    .prepare(
      `INSERT INTO live_shares (id, account_id, space_id, mac, device, mode, label, token_hash, created_at, expires_at)
       SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10
       WHERE (SELECT COUNT(*) FROM live_shares WHERE account_id = ?2 AND expires_at > ?9) < ?11`,
    )
    .bind(
      row.id,
      accountId,
      row.space_id,
      row.mac,
      row.device,
      row.mode,
      row.label,
      await sha256Hex(token),
      row.created_at,
      row.expires_at,
      MAX_SHARES_PER_ACCOUNT,
    )
    .run();
  if (meta.changes === 0) {
    throw new UserError(
      "share-limit",
      `You can have at most ${MAX_SHARES_PER_ACCOUNT} share links. Revoke one first.`,
      MAX_SHARES_PER_ACCOUNT,
    );
  }
  return { row, token };
}

/** The account's links that have not expired, newest first. Expired ones are deleted on the way. */
export async function listShares(db: D1Database, accountId: string, now = Date.now()): Promise<ShareRow[]> {
  const [, listed] = await db.batch<ShareRow>([
    db.prepare("DELETE FROM live_shares WHERE account_id = ?1 AND expires_at <= ?2").bind(accountId, now),
    db
      .prepare(`SELECT ${columns} FROM live_shares WHERE account_id = ?1 ORDER BY created_at DESC`)
      .bind(accountId),
  ]);
  return listed?.results ?? [];
}

/** Revokes a link; returns its space so the relay can end its views. Null when the account has no such link. */
export async function deleteShare(db: D1Database, accountId: string, id: string): Promise<ShareRow | null> {
  const row = await db
    .prepare(`DELETE FROM live_shares WHERE id = ?1 AND account_id = ?2 RETURNING ${columns}`)
    .bind(id, accountId)
    .first<ShareRow>();
  return row ?? null;
}

/** The link a token opens, expired or not; null when there is none (never was, or revoked). */
export async function findShare(db: D1Database, token: string): Promise<ShareRow | null> {
  if (!isShareToken(token)) return null;
  return db
    .prepare(`SELECT ${columns} FROM live_shares WHERE token_hash = ?1`)
    .bind(await sha256Hex(token))
    .first<ShareRow>();
}

/**
 * What a link shows: the link and the devices its Mac last reported (only the linked one for a
 * device link). The Mac counts only while it belongs to the account that made the link: one moved
 * to another account shows no devices and is offline.
 */
export async function openShare(
  db: D1Database,
  token: string,
): Promise<{ share: ShareRow; online: boolean; devices: Device[] } | null> {
  if (!isShareToken(token)) return null;
  const row = await db
    .prepare(
      `SELECT s.id, s.space_id, s.mac, s.device, s.mode, s.label, s.created_at, s.expires_at,
              h.online AS host_online, h.devices AS host_devices
       FROM live_shares s
       LEFT JOIN hosts h ON h.space_id = s.space_id AND h.name = s.mac AND h.account_id = s.account_id
       WHERE s.token_hash = ?1`,
    )
    .bind(await sha256Hex(token))
    .first<ShareRow & { host_online: number | null; host_devices: string | null }>();
  if (!row) return null;
  const { host_online, host_devices, ...share } = row;
  const devices = parseStoredDevices(host_devices).filter((device) => share.device === null || device.id === share.device);
  return { share, online: host_online === 1, devices };
}

/** Which of these links still exist; the relay ends views whose link was revoked. */
export async function existingShares(db: D1Database, ids: string[]): Promise<Set<string>> {
  if (ids.length === 0) return new Set();
  const placeholders = ids.map((_, index) => `?${index + 1}`).join(", ");
  const { results } = await db
    .prepare(`SELECT id FROM live_shares WHERE id IN (${placeholders})`)
    .bind(...ids)
    .all<{ id: string }>();
  return new Set(results.map((row) => row.id));
}
