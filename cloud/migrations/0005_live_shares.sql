-- Share links for live view: whoever opens mobdev.sh/live/<token> may watch one Mac's devices, or
-- one device, until the link expires or its owner revokes it (which deletes the row). Only the
-- token's SHA-256 hash is stored. `device` NULL means every device of the Mac; `mode` is "view"
-- (watch only) or "control" (watch, tap and type).

CREATE TABLE live_shares (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  space_id TEXT NOT NULL,
  mac TEXT NOT NULL,
  device TEXT,
  mode TEXT NOT NULL CHECK (mode IN ('view', 'control')),
  label TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX live_shares_account ON live_shares(account_id);
