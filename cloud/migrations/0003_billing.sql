-- Plans and usage live in Autumn, payments in Stripe. The relay only remembers how many Macs an
-- account's plan allowed when Autumn last answered, so Macs can still connect while it is down.

ALTER TABLE accounts ADD COLUMN macs_allowed INTEGER;
