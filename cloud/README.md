# mobdev.sh

The website, dashboard and hosted relay. Everything runs on Cloudflare.

| Part | Where | What |
|---|---|---|
| Website and dashboard | `src/`, worker `mobdev-web`, `mobdev.sh` | TanStack Start. Sign-in with WorkOS AuthKit. Dashboard issues access tokens and lists Macs. |
| Hosted relay | `relay/`, worker `mobdev-relay`, `relay.mobdev.sh` | One Durable Object per space. Macs connect with hibernatable WebSockets, so an idle Mac costs nothing. Same protocol as [`../relay`](../relay). |
| Database | D1 `mobdev`, `migrations/` | Accounts, hashed access tokens, which Macs are connected. No request or screenshot content. |

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

Not automated. With a Cloudflare account that has the `mobdev.sh` zone:

1. `bunx wrangler d1 create mobdev` and put the ID into both `wrangler.jsonc` files.
2. `bunx wrangler d1 migrations apply mobdev --remote`
3. `bun run deploy:relay` (creates `relay.mobdev.sh`).
4. In a WorkOS production environment, add the redirect URI `https://mobdev.sh/api/auth/callback`,
   the sign-out URI `https://mobdev.sh/` and the initiate login URI
   `https://mobdev.sh/api/auth/sign-in`.
5. `bunx wrangler secret put WORKOS_CLIENT_ID`, `WORKOS_API_KEY` and `WORKOS_COOKIE_PASSWORD`
   (32+ random characters).
6. `bun run deploy:web` (creates `mobdev.sh`).
