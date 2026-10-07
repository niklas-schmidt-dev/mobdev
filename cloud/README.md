# mobdev.sh

The website, dashboard and hosted relay. Everything runs on Cloudflare.

| Part | Where | What |
|---|---|---|
| Website and dashboard | `src/`, worker `mobdev-web`, `mobdev.sh` | TanStack Start. Sign-in with WorkOS AuthKit. Dashboard issues access tokens and lists Macs. |
| Hosted relay | `relay/`, worker `mobdev-relay`, `relay.mobdev.sh` | One Durable Object per space. Macs connect with hibernatable WebSockets, so an idle Mac costs nothing. Same protocol as [`../relay`](../relay). |
| Database | D1 `mobdev`, `migrations/` | Accounts, hashed access tokens, which Macs are connected and the iPhones they report, hashed live view share links, and a deleted account's usage until its allowance renews (below). No request or screenshot content. |
| Billing | [Autumn](https://docs.useautumn.com) on Stripe, `autumn.config.ts` | Plans, monthly allowances and usage per account; checkout and billing portal. |

The relay is a separate worker so deploying the website never disconnects Macs. The website
reaches it only through a service binding (`RelayAdmin`), for example to disconnect Macs when a
token is revoked.

## How the hosted relay authenticates

- A Mac connects to `wss://relay.mobdev.sh/v1/host/connect` with its host secret (`mdh_…`) and an
  access token (`mda_…`) from the dashboard. The relay stores only the token's SHA-256 hash.
- Agents call `https://relay.mobdev.sh/h/<mac>/mcp` with the Mac's client key (`mdc_…`), derived
  from the host secret. The relay routes by `sha256(client key)` and never sees the secret.
- Revoking a token deletes it and closes its Macs' connections (close code 4001). If that call
  fails, each connection finds out at its next request: it checks its token at most once a
  minute (`TOKEN_RECHECK_MS`). A Mac that connects while its token is revoked is checked again
  after it is accepted.
- Limits: 16 MB per request, 90 s per request (then the relay sends the Mac
  `{"type":"cancel","id"}` so it can stop), 32 Macs per key, 20 tokens per account, and at
  most 10 connected Macs per account whatever the plan says.

## Plans, limits and billing

The plans are in `shared/plans.ts`; `autumn.config.ts` pushes them to Autumn, and the website
shows the same numbers. Free: 1 Mac, 20,000 requests and 10 active hours a month. Pro, $9 USD a
month plus applicable tax: 3 Macs, 1,000,000 requests and 300 active hours. Local use and self-hosted relays have no
limits.

What keeps cost bounded, cheapest check first:

| Limit | Where | Answer |
|---|---|---|
| 50 agent requests per 10 s per client key; 10 connects per minute per Mac | Rate limiting bindings in `relay/wrangler.jsonc`, checked in the worker before the Durable Object | `429`, `Retry-After` |
| 4 requests in flight per Mac | `RelaySpace.forward` | `429`, `Retry-After: 1` |
| Connected Macs per plan | `connectHost` reads Autumn's `macs` balance (the last value is cached in `accounts.macs_allowed` for when Autumn is down); `RelaySpace` enforces it in the same D1 statement that records the Mac, so concurrent connections cannot pass it | `429` on connect; the Mac app waits 5 minutes |
| Requests and active seconds per month | Autumn balances `relay_requests`, `relay_active_seconds`, cached in each connection | `429`, `Retry-After` until renewal |

How usage gets to Autumn: each Mac connection has a meter in its WebSocket attachment (so it
survives hibernation) that counts forwarded requests and the time with at least one request in
flight. That time is what Durable Object duration costs, and requests still in flight count
against the allowance too. About 30 s after a Mac starts on a request, and every 30 s while it
stays busy, a Durable Object alarm sends one batch per connection with `balances.track`.
Idempotency keys make retries safe. The answer carries the remaining balance, which the
connection enforces locally without calling Autumn per request. A Mac that disconnects leaves its
meter in storage until all of it is confirmed. If Autumn is unreachable, requests pass, usage
waits, and the relay retries every minute. Relay deploys can lose up to 30 s of uncounted usage.

Deleting an account deletes nothing until Autumn has deleted the customer. Before that, the
month's usage goes to `deleted_usage` under a SHA-256 hash of the WorkOS user ID, until the
allowance renews. If the same user signs up again before then, the dashboard adds that usage to
the new Autumn customer before it issues a token, so deleting the account does not reset the free
allowance (`shared/accounts.ts`).

Relay logs are sampled at 5 % (`head_sampling_rate`): at three log events per agent request,
full logging would cost more than the requests themselves.

The relay reads Autumn only with `AUTUMN_SECRET_KEY` set. Without it, it neither meters nor bills
and only the fixed limits apply, which is how local development runs by default.

Setting up Autumn (once per environment):

1. Create the Autumn organization and connect Stripe. Keep the default currency USD: Pro's price
   has no currency of its own and takes the organization's. The config enables Stripe Tax
   (`settings.automaticTax: true`). Before pushing it, complete Stripe Tax setup, confirm active
   tax registrations, and set the default price tax behavior to **exclusive** ($9 plus applicable
   tax). Without a registration in the customer's location, Stripe calculates zero tax.
   Save the live Customer portal settings with cancellation, payment methods and invoices enabled.
2. `bunx atmn login`, then `bunx atmn push` to preview and `bunx atmn push --yes` to apply the
   plans (`--prod` for production).
3. Set `AUTUMN_SECRET_KEY` on both workers:
   `bunx wrangler secret put AUTUMN_SECRET_KEY` and
   `bunx wrangler secret put AUTUMN_SECRET_KEY -c relay/wrangler.jsonc`.

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

## Live view

The relay streams a device's screen to viewers and passes their taps and typing back, with the
same protocol as the Go relay ([`../relay/README.md`](../relay/README.md#live-view), code in
`shared/live.ts` and `RelaySpace`). Viewer sockets are hibernatable WebSockets of the Mac's space,
tagged `viewer` and `viewer:<mac>`. The Mac streams only while "Allow live view" is on under
Remote Access in the app (off by default).

| Who | How | May |
|---|---|---|
| Agents and tools | `GET /v1/live` with the client key, as `Bearer mdc_…` or the `mobdev-auth.mdc_…` subprotocol | Watch and control any device of the Mac |
| The account in the dashboard | "Live" next to a device opens `/live?space=…&mac=…&device=…` | Watch and control its own Macs' devices |
| Anyone with a share link | `mobdev.sh/live/mds_…`, no account | One device or every device of one Mac, view only or with control, until the link expires or is revoked |

Browsers never get a key. Before each connection the page asks a server function for a ticket;
the website checks who may watch what and asks the relay over the `RelayAdmin` service binding
(`liveTicket`), which keeps the SHA-256 hash of a random secret with that grant in the space's
Durable Object for 60 s. The browser presents `mdv_<space><secret>` as a subprotocol; the relay uses
it once. So no secret is shared between the workers.

Share links are created and revoked on the live page and listed in the dashboard. D1 keeps them in
`live_shares` with the token's SHA-256 hash, a label, the Mac (and device, or all of them), the
mode and the expiry (an hour, a day or a week; at most 20 per account). Revoking deletes the row and
calls `RelayAdmin.endShare`, which closes its viewers at once (4005); if that call fails, the
space's alarm finds the link gone within 30 s. A link ends its views when it expires (4004), and it
only works while its Mac still belongs to the account that made it. Forgetting the Mac or deleting
the account deletes its links.

Metering: a Mac with at least one viewer is busy, so watching counts as active time like a request
in flight, and each input counts as one request. Frames count as neither. Opening a view counts
once against the key's `AGENT_LIMIT`. Viewers are refused (429) and closed (4029) when the
account's allowance is used up. The space's alarm runs every 30 s while someone watches: it renews
each stream on the Mac (`live_start`) and ends views whose Mac left, whose link expired or was
revoked, or whose viewer went silent.

Tested in `test/live.test.ts` against the relay worker and D1. The website's pages and server
functions (`src/routes/live.*.tsx`, `src/server/live.ts`, `src/components/live.tsx`) have no unit
tests; check them in the browser (Local development).

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
access with a real Mac. To test billing, put an Autumn sandbox key in `AUTUMN_SECRET_KEY` of
both `.dev.vars` and `relay/.dev.vars`.

```sh
bun run typecheck
bun run test        # relay worker, Durable Object, D1 and a fake Autumn in the Workers runtime
bun run build
```

## Languages

The website and dashboard are in English and German. English pages live at `/docs`, their German
copies at `/de/docs`: the router maps `/de/…` onto the same routes (`src/router.tsx`). Request
middleware (`src/start.ts`) sends a visitor on an English page to the German copy when
[General Translation](https://generaltranslation.com/docs/react/tanstack-start) resolves German for
them, from the language they last chose or visited (its `generaltranslation.locale` cookie), else
from `Accept-Language`. Crawlers send neither, so search engines see each language under its own
URL; `pageHead()` in `src/lib/meta.ts` links the two with `hreflang`, and `public/sitemap.xml`
lists both.

Text is marked with General Translation's `<T>`, `useGT()` and `msg()` and translated by hand,
without its translation API:

```sh
bun run translations   # gt generate: updates src/_gt/en.json and adds new text to src/_gt/de.json in English
```

Then translate the new entries in `src/_gt/de.json`, keeping their structure. `test/i18n.test.ts`
fails while an entry is still English or misses a link or variable of the source. Page titles and
descriptions are in `src/lib/meta.ts`. Output that shows the English-only Mac app and its tools
(tool names and results, the app mock) stays English.

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

Keep this order: the website calls the relay's `RelayAdmin` methods and reads tables that the
migrations add (live view needs `0005_live_shares.sql` and a relay with `liveTicket` and
`endShare`).

Secrets of `mobdev-web` (`bunx wrangler secret put <name>`): `WORKOS_API_KEY` (Production secret
key), `WORKOS_COOKIE_PASSWORD` (set) and `AUTUMN_SECRET_KEY`. Without the API key the public pages
work and the dashboard says accounts are being set up. Without the Autumn key the dashboard shows
no plan. `mobdev-relay` needs `AUTUMN_SECRET_KEY` too.
