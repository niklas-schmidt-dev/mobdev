# mobdev.sh

The website, dashboard and hosted relay. Everything runs on Cloudflare.

| Part | Where | What |
|---|---|---|
| Website and dashboard | `src/`, worker `mobdev-web`, `mobdev.sh` | TanStack Start. Sign-in with WorkOS AuthKit. Dashboard issues access tokens and lists Macs. |
| Hosted relay | `relay/`, worker `mobdev-relay`, `relay.mobdev.sh` | One Durable Object per space. Macs connect with hibernatable WebSockets, so an idle Mac costs nothing. Same protocol as [`../relay`](../relay). |
| Database | D1 `mobdev`, `migrations/` | Accounts, hashed access tokens, which Macs are connected and the iPhones they report. No request or screenshot content. |

The relay is a separate worker so deploying the website never disconnects Macs. The website
reaches it only through a service binding (`RelayAdmin`), for example to disconnect Macs when a
token is revoked.

## How the hosted relay authenticates

- A Mac connects to `wss://relay.mobdev.sh/v1/host/connect` with its host secret (`mdh_…`) and an
  access token (`mda_…`) from the dashboard. The relay stores only the token's SHA-256 hash.
- Agents call `https://relay.mobdev.sh/h/<mac>/mcp` with the Mac's client key (`mdc_…`), derived
  from the host secret. The relay routes by `sha256(client key)` and never sees the secret.
- Revoking a token deletes it and closes its Macs' connections (close code 4001).
- Limits: 16 MB per request, 90 s per request, 32 Macs per key, 10 connected Macs and 20 tokens
  per account.

## Device registry

Each Mac sends its relay a `devices` frame right after connecting and whenever its iPhones or
their state change (format and validation in [`../relay/README.md`](../relay/README.md#devices),
code in `shared/devices.ts`). Invalid or oversized frames are ignored. The relay keeps the latest
valid list per Mac in D1 (`hosts.devices` as JSON, `hosts.devices_updated_at`), where it stays
after the Mac disconnects until the Mac is forgotten or the account deleted, and while the Mac is
connected also in its space's Durable Object storage.

| Who | Request | |
|---|---|---|
| Mac app | `GET /v1/account/devices` with `Bearer mda_…` | Every Mac of the token's account, online first, then newest connection. Reads D1 only; marks the token as used. `401` for a missing, unknown or revoked token. |
| Agent | `GET /v1/relay/devices` with `Bearer mdc_…` | The connected Macs of that key, from the Durable Object. Same as the Go relay. |

```json
{"macs":[{"name":"niklass-macbook-pro","online":true,"connected_at":1790700000000,"disconnected_at":null,
  "devices":[{"id":"00008120-000639440C13C01E","name":"iPhone von Niklas","model":"iPhone15,2",
    "model_name":"iPhone 14 Pro","os_version":"27.0","device_class":"iPhone","screen":true,"bluetooth":true,"ready":true}]}]}
```

`online` is what D1 recorded when Macs connected and disconnected; the dashboard also checks the
relay. The dashboard lists each Mac's devices under it.

## Local development

```sh
bun install
cp .dev.vars.example .dev.vars          # WorkOS sandbox credentials
eval "$(~/.local/bin/dev-scope)"
bun run db:migrate
portless run --name "relay.$DEV_NAMESPACE" bun run dev:relay
portless run --name "web.$DEV_NAMESPACE" bun run dev
```

Both share the local D1 in `.wrangler/state`. Set `WORKOS_REDIRECT_URI` and `RELAY_URL` in
`.dev.vars` to the Portless URLs (`portless get web.$DEV_NAMESPACE`), and add the redirect URI to
the WorkOS sandbox. Point the Mac app's relay URL at the relay's Portless URL to test remote
access with a real Mac.

```sh
bun run typecheck
bun run test        # relay worker, Durable Object and D1 queries in the Workers runtime
bun run build
```

## Deploy

Live since 2026-09-29 in the Cloudflare account "Niklas Schmidt": D1 `mobdev`
(`f79069d6-9e8e-4ea4-8b50-a6a0f5fd6ba9`), workers `mobdev-relay` (`relay.mobdev.sh`) and
`mobdev-web` (`mobdev.sh`). WorkOS project "Mobdev", environment "Production" (client ID in
`wrangler.jsonc`) has the redirect URI, sign-out URI and CORS origin for `mobdev.sh`.

To ship changes:

```sh
bunx wrangler d1 migrations apply mobdev --remote   # only when migrations/ changed
bun run deploy:relay                                 # disconnects Macs briefly; they reconnect
bun run deploy:web
```

Secrets of `mobdev-web` (`bunx wrangler secret put <name>`): `WORKOS_API_KEY` (Production secret
key) and `WORKOS_COOKIE_PASSWORD` (set). Without the API key the public pages work and the
dashboard says accounts are being set up.
