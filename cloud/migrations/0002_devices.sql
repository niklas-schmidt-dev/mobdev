-- The iPhones and iPads each Mac reports over the relay ("devices" frame): the latest validated
-- list as a JSON array, kept after the Mac disconnects so it can be shown as offline.

ALTER TABLE hosts ADD COLUMN devices TEXT;
ALTER TABLE hosts ADD COLUMN devices_updated_at INTEGER;
