# Mobdev relay

Lets agents anywhere reach a Mac running Mobdev without opening a port on that Mac. The Mac keeps
a few outgoing long-poll requests open; the relay hands each agent request to one of them and
returns the answer. Requests and screenshots pass through memory only. Nothing is stored and
there are no accounts.

One Go binary, standard library only.

## Run

```sh
go run .                                    # listens on :8080
RELAY_ADDR=127.0.0.1:9000 go run .
RELAY_HOST_ACCESS_TOKEN=secret go run .     # only Macs that know the token may connect
```

Put it behind HTTPS (Caddy, a load balancer, Cloudflare Tunnel). Mobdev refuses plain-http
relays except on localhost.

```sh
docker build -t mobdev-relay .
docker run -p 8080:8080 -e RELAY_HOST_ACCESS_TOKEN=secret mobdev-relay
```

| Variable | Default | |
|---|---|---|
| `RELAY_ADDR` | `:8080` | Listen address |
| `RELAY_HOST_ACCESS_TOKEN` | empty | If set, Macs must send it as `X-Relay-Access`. Use it on a public relay so strangers cannot use yours. |

## Keys

The Mac generates a secret `mdh_…` that never leaves it except to authenticate at the relay.
Agents use a client key derived from it: `mdc_` + hex(HMAC-SHA256(secret, "mobdev-relay-client-v1")).
The relay computes the same key when a Mac connects and matches agents to Macs by its hash, so it
keeps no database. A client key cannot be used to act as a Mac. Rotating the secret in the app
revokes the client key.

## Protocol

| Who | Request | |
|---|---|---|
| Mac | `GET /v1/host/poll?name=<mac>` with `Bearer mdh_…` | Waits up to 25 s. `200` with a request envelope or `204`. `wait=0` answers at once. |
| Mac | `POST /v1/host/respond` with `Bearer mdh_…` | The response envelope for a request id |
| Agent | `POST /mcp`, `GET/POST /v1/...` with `Bearer mdc_…` | Forwarded to the only connected Mac |
| Agent | `/h/<mac>/mcp`, `/h/<mac>/v1/...` or header `X-Mobdev-Host` | Pick a Mac when several share a key |
| Agent | `GET /v1/relay/hosts` | Connected Macs for this key |
| Anyone | `GET /healthz` | |

Envelopes are JSON: `{"id", "method", "path", "query", "status", "headers", "body"}` with a
base64 body. Only `/mcp` and `/v1/...` are forwarded, and only the headers MCP needs
(`Content-Type`, `Accept`, `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, `Mcp-Param-*`).
Cookies and the agent's `Authorization` header are never forwarded.

Limits: 16 MB bodies, 90 s per request, 64 queued requests and 32 Macs per key. Logs contain
method, path, status and duration only.

## Test

```sh
go vet ./... && go test -race ./...
```

`macos/Tests/MobdevCoreTests/RelayTests.swift` also builds this relay and drives a fake phone
through it end to end.
