-- Deleting an account deletes its Autumn customer and with it the month's usage. Until that
-- allowance would have renewed, this keeps what the account used, under a SHA-256 hash of the
-- WorkOS user ID, and the dashboard adds it to the user's next account, so deleting and signing up
-- again does not reset the free allowance (shared/accounts.ts).

CREATE TABLE deleted_usage (
  user_hash TEXT PRIMARY KEY,
  requests INTEGER NOT NULL,
  active_seconds INTEGER NOT NULL,
  resets_at INTEGER NOT NULL,
  -- Set once Autumn deleted the customer; until then the account still has this usage itself.
  deleted_at INTEGER
);
