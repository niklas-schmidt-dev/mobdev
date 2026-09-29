# Mobdev

Give your AI agent a real iPhone. Free and open source.

Mobdev is a small native Mac app. It reads the iPhone screen over the USB cable and taps and types
through Bluetooth, posing as a keyboard and pointer. Nothing is installed on the phone: no
developer mode, no jailbreak, no simulator. Claude Code, Codex, Cursor or any MCP client can then
take screenshots, tap, type, open apps and tap visible text.

```
   iPhone ──USB screen──▶ Mobdev.app ◀── MCP / HTTP ── agents on this Mac
          ◀─Bluetooth HID─     │
                               └── WebSocket ──▶ relay ◀── agents anywhere (optional)
```

## Repository

| Folder | What | Stack |
|---|---|---|
| [`macos/`](macos/README.md) | The Mac app, MCP server, HTTP API and stdio bridge | SwiftUI, macOS 26+, no dependencies |
| [`relay/`](relay/README.md) | Self-hosted relay for remote access | Go, one binary or Docker image |
| [`cloud/`](cloud/README.md) | mobdev.sh: website, dashboard and hosted relay | TanStack Start, Cloudflare Workers, Durable Objects, D1, WorkOS |

## Get started

```sh
cd macos
scripts/build-app.sh
open build/Mobdev.app
```

Then plug in the iPhone, pair it over Bluetooth and turn on AssistiveTouch. The app walks through
it; details are in [`macos/README.md`](macos/README.md).

Remote access is optional. Create an access token at [mobdev.sh](https://mobdev.sh/dashboard) and
click “Open in Mobdev”, or run [your own relay](relay/README.md).

## Development

```sh
cd macos && swift test && scripts/build-app.sh      # Mac app
cd relay && go vet ./... && go test -race ./...    # self-hosted relay
cd cloud && bun install && bun run typecheck && bun run test && bun run build
```

The Swift tests build and start the Go relay to test remote access end to end. Everything runs
without an iPhone: a fake phone renders real text so OCR, `tap_text` and coordinates are covered.

## Status

Early release. Verified on hardware: USB screen capture, Bluetooth pairing, MCP, OCR and remote
access through both relays. Tapping with AssistiveTouch, swipes and typing on a phone still need
broader hands-on testing. One iPhone per Mac for now.

MIT licensed. Independent project; not affiliated with Apple, TapKit or MobAI.
