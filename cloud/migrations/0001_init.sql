-- Accounts are WorkOS users. Access tokens let a Mac connect to the hosted relay; only their
-- SHA-256 hash is stored. Hosts mirror which Macs are connected, written by the relay.

CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE access_tokens (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  prefix TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER
);

CREATE INDEX access_tokens_account ON access_tokens(account_id);

CREATE TABLE hosts (
  space_id TEXT NOT NULL,
  name TEXT NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  token_id TEXT,
  online INTEGER NOT NULL DEFAULT 0,
  connected_at INTEGER,
  disconnected_at INTEGER,
  PRIMARY KEY (space_id, name)
);

CREATE INDEX hosts_account ON hosts(account_id);
CREATE INDEX hosts_token ON hosts(token_id);
