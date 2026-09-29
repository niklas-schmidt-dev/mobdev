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
| [`macos/`](macos/README.md) | The Mac app, MCP server, HTTP API and stdio bridge | SwiftUI, macOS 26+, Sparkle for updates |
| [`relay/`](relay/README.md) | Self-hosted relay for remote access | Go, one binary or Docker image |
| [`cloud/`](cloud/README.md) | mobdev.sh: website, dashboard and hosted relay | TanStack Start, Cloudflare Workers, Durable Objects, D1, WorkOS |

## Get started

[Download Mobdev](https://mobdev.sh/download) (signed, notarized, updates itself), or build it:

```sh
cd macos
MOBDEV_VARIANT=release scripts/build-app.sh
open build/Mobdev.app
```

Then plug in the iPhone, pair it over Bluetooth and turn on AssistiveTouch. The app walks through
it; details are in [`macos/README.md`](macos/README.md).

Remote access is optional. Create an access token at [mobdev.sh](https://mobdev.sh/dashboard) and
click “Open in Mobdev”, or run [your own relay](relay/README.md).

## Development

```sh
cd macos && swift test && scripts/build-app.sh      # Mac app: builds "Mobdev Dev"
cd relay && go vet ./... && go test -race ./...    # self-hosted relay
cd cloud && bun install && bun run typecheck && bun run test && bun run build
```

The Swift tests build and start the Go relay to test remote access end to end. Everything runs
without an iPhone: a fake phone renders real text so OCR, `tap_text` and coordinates are covered.

## Shipping

Every push to `main` ships what changed, through GitHub Actions:

| Change in | Workflow | Result |
|---|---|---|
| `cloud/` | `cloud.yml` | Tests, D1 migrations, deploy of mobdev.sh; relay.mobdev.sh only when the relay changed |
| `macos/` | `macos.yml` | Tests, universal build, Developer ID signature, notarization, DMG with a designed install window (`macos/scripts/dmg-settings.py`), GitHub release `mac-v<version>`. `mobdev.sh/appcast.xml` then offers it and installed apps update through Sparkle |
| `relay/` | `relay.yml` | Tests, `ghcr.io/niklas-schmidt-dev/mobdev-relay` for amd64 and arm64 |

The app version is `macos/VERSION` plus the workflow run number. The update window and the GitHub
release show what's new, collected from `Release-Note:` lines in the commit messages since the
previous release:

```
Release-Note: New: All Devices shows every iPhone connected to your Macs.
```

Start a note with `New:`, `Improved:` or `Fixed:`; commits without one are not listed. Repository secrets:
`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`,
`APPLE_API_KEY` (base64 `.p8`), `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `SPARKLE_PRIVATE_KEY`.
The Sparkle key's backup is the "mobdev" item in the maintainer's keychain; losing it means
installed apps can no longer be updated.

## Status

Early release. Verified on hardware: USB screen capture, Bluetooth pairing, MCP, OCR and remote
access through both relays. Tapping with AssistiveTouch, swipes and typing on a phone still need
broader hands-on testing. One iPhone per Mac for now.

MIT licensed. Independent project; not affiliated with Apple, TapKit or MobAI.
