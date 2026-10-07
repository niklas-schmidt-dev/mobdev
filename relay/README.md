# Mobdev relay

Lets agents anywhere reach a Mac running Mobdev without opening a port on that Mac. The Mac keeps
one outgoing WebSocket open; the relay sends each agent request over it and returns the answer.
Requests and screenshots pass through memory only. Nothing is stored and there are no accounts.

One Go binary; its only dependency is [coder/websocket](https://github.com/coder/websocket). The
hosted relay at `relay.mobdev.sh` (see [`../cloud`](../cloud)) speaks the same protocol.

## Run

```sh
go run .                                    # listens on :8080
RELAY_ADDR=127.0.0.1:9000 go run .
RELAY_HOST_ACCESS_TOKEN=secret go run .     # only Macs that know the token may connect
```

Put it behind HTTPS (Caddy, a load balancer, Cloudflare Tunnel). Mobdev refuses plain-http
relays except on localhost.

On SIGTERM or Ctrl-C the relay stops accepting connections, gives requests in flight 5 s to
finish and then closes the Macs' WebSockets with code 1001 (going away); Mobdev reconnects on
its own.

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
| Mac | WebSocket `GET /v1/host/connect?name=<mac>` with `Bearer mdh_…` | Carries requests to the Mac and responses back. A newer connection with the same key and name replaces the older one (close code 4000). |
| Agent | `POST /mcp`, `GET/POST /v1/...` with `Bearer mdc_…` | Forwarded to the only connected Mac |
| Agent | `/h/<mac>/mcp`, `/h/<mac>/v1/...` or header `X-Mobdev-Host` | Pick a Mac when several share a key |
| Agent | `GET /v1/relay/hosts` | Connected Macs for this key |
| Agent | `GET /v1/relay/devices` | Connected Macs for this key with their iPhones (see below) |
| Viewer | WebSocket `GET /v1/live?device=<id>&fps=<1-10>`, also `/h/<mac>/v1/live` | Watch a device's screen and tap and type on it ([Live view](#live-view)) |
| Anyone | `GET /healthz` | |

Messages are JSON text frames: the relay sends `{"type":"request","id","method","path","query","headers","body"}`
and the Mac answers `{"type":"response","id","status","headers","body"}`, bodies in base64. When
the relay gives up on a request it has sent (the Mac did not answer within 90 s, or the agent
went away), it sends `{"type":"cancel","id"}` so the Mac can stop working on it; a response
that still comes is dropped. Macs that do not know the frame ignore it. The
Mac sends `ping` every 20 s and the relay answers `pong`; a connection silent for 75 s is closed. Only `/mcp` and `/v1/...` are forwarded, and only the headers MCP needs
(`Content-Type`, `Accept`, `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, `Mcp-Param-*`).
Cookies and the agent's `Authorization` header are never forwarded. Answers keep `Content-Type`,
`Allow`, `Retry-After`, `X-Image-Width` and `X-Image-Height`. Frames of an unknown `type`
are ignored.

Any method and any body pass byte for byte, since bodies travel as base64. That carries builds
that agents upload for `install_app`: `PUT /v1/uploads/<id>?offset=…` with an
`application/octet-stream` chunk of up to 8 MiB, about 11 MB in the frame (see
[Install builds from anywhere](../macos/README.md#install-builds-from-anywhere)). The relay holds
each chunk in memory only while it forwards it.

### Devices

Right after connecting, and whenever its iPhones or their state change (at most about once a
second), the Mac sends the list of its devices:

```json
{"type":"devices","devices":[{"id":"00008120-000639440C13C01E","name":"iPhone von Niklas","model":"iPhone15,2",
  "model_name":"iPhone 14 Pro","os_version":"27.0","device_class":"iPhone","screen":true,"bluetooth":true,"ready":true}]}
```

`id` is the UDID or another stable ID and must not be empty; `screen` means the Mac has the
picture over USB, `bluetooth` that its keyboard and mouse are connected. An empty array is valid.
The relay keeps the first 32 devices, cuts strings to 100 characters and drops unknown fields;
it ignores the whole frame if it is larger than 16 KB or malformed (not JSON, no `devices`
array, an entry without `id`, a field of the wrong type). It keeps the latest list per Mac in
memory until the Mac disconnects.

`GET /v1/relay/devices` with the client key returns the connected Macs, newest connection first:

```json
{"macs":[{"name":"studio","online":true,"connected_at":1790700000000,"disconnected_at":null,"devices":[…]}]}
```

A Mac that has not sent a list yet has `"devices":[]`. The hosted relay answers the same request
and also lists every Mac of an account, including offline ones, at `GET /v1/account/devices`
(see [`../cloud`](../cloud)).

### Live view

A viewer (a browser, an agent, a script) watches a device's screen and taps and types on it. It
opens `GET /v1/live?device=<id or name>&fps=<1-10>` as a WebSocket with the client key, as
`Authorization: Bearer mdc_…` or, from a browser, which cannot set headers on a WebSocket, as the
subprotocols `mobdev-live` and `mobdev-auth.mdc_…`; the relay then answers with `mobdev-live`.
Without `device` the Mac picks the device as its tools do; `fps` is 5 unless given, at most 10. The
relay asks the Mac for the stream, and every viewer of the same device shares it.

| Frame | Direction | |
|---|---|---|
| `{"type":"live","mac","device","mode","fps"}` | relay → viewer | Once, first. `mode` is `control` (`view` for view-only share links on the hosted relay). |
| `{"type":"live_frame","id","seq","width","height","jpeg"}` | Mac → relay → viewer | JPEG in base64, 800 px on the long edge, quality 0.5, passed on unchanged. An unchanged screen is sent again every 2 s. |
| `{"type":"ack","seq"}` | viewer → relay | For every frame shown. A viewer with 2 frames unacknowledged gets no more until it acknowledges: slow viewers skip frames, nothing queues. |
| `{"type":"input","action",…}` | viewer → relay | `tap` `{x,y}`, `long_press` `{x,y,seconds}`, `swipe` `{from_x,from_y,to_x,to_y,duration}`, `scroll` `{x,y,direction,amount}`, `text` `{text}`, `key` `{key,modifiers}` or `home`. Points are fractions of the screen from its top left, 0 to 1. At most 10 a second. |
| `{"type":"live_error","message"}` | relay → viewer | An input was refused. |
| `{"type":"live_end","code","reason"}` | relay → viewer | Right before the relay closes the view. |
| `"ping"`, `"pong"` | viewer ⇄ relay | Every 20 s; a viewer silent for 75 s is closed. |
| `{"type":"live_start","id","device","fps","viewers"}` | relay → Mac | Starts a stream, tells the Mac its viewers (`[{"kind","label","control"}]`, kind `key`, `owner` or `share`) and the highest fps any of them asked for, and is repeated every 30 s while someone watches. |
| `{"type":"live_stop","id"}` | relay → Mac | The last viewer left. |
| `{"type":"live_input","id","input"}` | relay → Mac | A checked input, which the Mac runs as the matching tool (`tap`, `swipe`, `type_text`, `press_key`, `home`, …). |
| `{"type":"live_end","id","code","reason"}` | Mac → relay | The Mac ended the stream: `disabled` (live view is off in the app), `no_device`, `stopped` (stopped in the app) or `timeout` (not renewed for 75 s). |

Close codes for viewers: 4002 the Mac disconnected, 4003 the Mac ended the stream (the `live_end`
before says why), 4008 the viewer went silent; the hosted relay adds 4004 (share link expired),
4005 (link revoked) and 4029 (allowance used up). At most 10 viewers per Mac (429); frames larger
than 2 MB are dropped; text has at most 1000 characters. Mobdev streams only after "Allow live
view" is turned on under Remote Access; until then it answers `live_end` with `disabled`.

Limits: 16 MB bodies, 90 s per request, 32 Macs per key and, as on the hosted relay, 4 requests
in flight per Mac (more get 429 with `Retry-After: 1`). An agent's request headers must arrive
within 10 s and the whole request within 30 s; a body that takes longer gets 408, and Mobdev's
upload clients then send smaller chunks. At most 256 MB of request bodies are held at once:
each request reserves its `Content-Length`, or 16 MB without one, before its body is read and
gets 503 when that does not fit. Logs contain method, path, status and duration only.

## Test

```sh
go vet ./... && go test -race ./...
```

`macos/Tests/MobdevCoreTests/RelayTests.swift` also builds this relay and drives a fake phone
through it end to end.
