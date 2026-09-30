# Mobdev for Mac

Let an AI agent use a real iPhone from your Mac. Free, open source, about 2 MB, no account.

Mobdev reads the iPhone screen over the USB cable and taps and types through Bluetooth, posing as a
keyboard and pointer. Nothing is installed on the phone: no developer mode, no jailbreak, no
simulator. Agents get an MCP server and a small HTTP API. An optional relay lets agents elsewhere
reach the phone.

```
              USB cable: screen frames (like QuickTime)
   ┌─────────┐ ◀──────────────────────────────────────── ┌────────┐
   │  Mac    │                                           │ iPhone │
   │ Mobdev  │ ────────────────────────────────────────▶ │        │
   └─────────┘   Bluetooth LE: keyboard + pointer (HID)   └────────┘
     ▲     ▲                                     AssistiveTouch turns
     │     └── MCP / HTTP on 127.0.0.1           the pointer into taps
     │
     └── optional outgoing connection to a relay (see ../relay)
```

## Requirements

- A Mac with Bluetooth LE running macOS 26 or later (the interface uses Liquid Glass). Developed on macOS 27 with Swift 6.4.
- An iPhone and a USB **data** cable. Charge-only cables give power and no picture.
- To build: Xcode 26 or later (Swift 6.2+, macOS 26 SDK).

## Build and run

```sh
cd macos
MOBDEV_VARIANT=release scripts/build-app.sh   # builds build/Mobdev.app (ad hoc signature)
open build/Mobdev.app                         # allow Bluetooth and Camera when macOS asks
```

macOS treats the iPhone screen like a camera, hence the Camera prompt. To sign with a certificate,
set `CODESIGN_IDENTITY`; `UNIVERSAL=1` builds for Apple silicon and Intel. With an ad hoc signature
macOS may ask for the permissions again after each rebuild.

Without `MOBDEV_VARIANT=release` the script builds **Mobdev Dev** (`build/Mobdev Dev.app`) for
development. It is a separate app that runs next to an installed Mobdev without changing it:
bundle ID `dev.mobdev.mac.dev`, its own settings and secrets in
`~/Library/Application Support/dev.mobdev.mac.dev`, port 4687, the `mobdev-dev://` URL scheme (so
dashboard links keep opening the installed app), the MCP name `mobdev-dev`, an amber icon and no
automatic updates. Both apps share the Mac's Bluetooth, so quit one before testing touch.

## Set up the iPhone (once)

On first launch a setup assistant walks through these steps. It asks for camera and Bluetooth
access on the page that explains them and checks each step off as soon as the Mac detects it. Open
it again with **Mobdev › Set Up iPhone…**.

1. Plug it in, unlock it and tap **Trust**. If the Mac asks to allow the accessory, click **Allow**.
   The screen appears in Mobdev.
2. On the iPhone open **Settings > Bluetooth** and tap this Mac under **Other Devices** to pair. iOS lists
   it by the Mac's name (System Settings › General › Sharing), not as “Mobdev”. An iPhone on the
   same Apple Account can miss the Mac, because it already knows it from Handoff and trusts the
   Bluetooth services it cached. Until an iPhone pairs, Mobdev rebuilds its Bluetooth services after
   8 seconds and then at doubling intervals up to every 2 minutes, which makes iOS look again.
   **Show on iPhone Again** in the setup does it right away.
3. Turn on **Settings > Accessibility > Touch > AssistiveTouch**. iOS then shows a pointer and
   turns clicks into taps. On the same page turn off **Snap to Item** and keep **Perform Touch
   Gestures** on. With Snap to Item on, iOS moves the pointer onto the nearest item and every swipe
   becomes a tap on it. Mobdev checks this without clicking before the first swipe and after a drag
   in the mirror, shows the result as **Pointer** in the device panel and in `status`, and `swipe`
   refuses while the pointer snaps.
4. In Mobdev pick the **keyboard layout** that matches Settings > General > Keyboard > Hardware
   Keyboard on the iPhone (U.S. or German).
5. Set **Auto-Lock** to Never while agents work. The phone must stay unlocked.

The mirror in the app is live: click to tap, drag to swipe, scroll, and type while it has focus.
⌘V types the Mac clipboard on the phone. The inspector on the right shows what is still missing,
Activity lists every agent action, and Settings (⌘,) holds the keyboard layout and API token.

## Connect an agent

The app shows ready-to-copy configurations with the right paths. The stdio variants need no
token: `Mobdev mcp` reads it locally and starts the app in the background if needed. It reaches
the app over a Unix socket in the app's data directory rather than the TCP port, so another user
on the Mac cannot pose as the app and collect the token.

Claude Code:

```sh
claude mcp add --scope user mobdev -- /Applications/Mobdev.app/Contents/MacOS/Mobdev mcp
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.mobdev]
command = "/Applications/Mobdev.app/Contents/MacOS/Mobdev"
args = ["mcp"]
```

Claude Desktop, Cursor and other clients:

```json
{ "mcpServers": { "mobdev": { "command": "/Applications/Mobdev.app/Contents/MacOS/Mobdev", "args": ["mcp"] } } }
```

Clients that speak Streamable HTTP can also use `http://127.0.0.1:4686/mcp` with
`Authorization: Bearer <token>` (copy it in the app). The server supports MCP 2026-07-28 and the
earlier `initialize`-based versions from 2024-11-05 to 2025-11-25.

### Tools

Coordinates are pixels of the image `screenshot` returns (long edge 1280 px, origin top-left).
Actions return a fresh screenshot over MCP unless `screenshot` is `false`. With more than one iPhone
on the Mac, pass `device` (an id or name from `list_devices`) to pick one.

| Tool | Arguments | |
|---|---|---|
| `list_devices` | | The iPhones on this Mac: id, name, model, iOS version, ready |
| `status` | | Screen and Bluetooth readiness, screenshot size |
| `screenshot` | | JPEG of the screen |
| `tap` | `x`, `y` | |
| `long_press` | `x`, `y`, `seconds` | |
| `swipe` | `from_x`, `from_y`, `to_x`, `to_y`, `duration` | |
| `scroll` | `direction` (`up`/`down`), `amount`, `x`, `y` | Mouse wheel |
| `type_text` | `text`, `submit` | Into the focused field, at most 1000 characters per call |
| `press_key` | `key`, `modifiers` | e.g. `space` + `cmd` for Spotlight |
| `home` | | |
| `open_app` | `name` | Through Spotlight |
| `read_screen` | | All visible text with positions (on-device OCR) |
| `find_text` | `text` | |
| `tap_text` | `text`, `index` | Taps a visible label |
| `wait_for_text` | `text`, `timeout`, `gone` | |
| `list_apps` | `all` | Apps installed for development, or every app |
| `install_app` | `path` | An `.app` or `.ipa` built for iPhone, from a path on this Mac |
| `uninstall_app` | `bundle_id` | Only apps installed for development |
| `launch_app` | `bundle_id`, `arguments`, `environment`, `restart` | Captures what the app prints |
| `stop_app` | `bundle_id` | |
| `open_url` | `url` | Deep links, universal links, web pages |
| `logs` | `bundle_id`, `after`, `lines`, `contains` | Output of launched apps and how they ended |
| `crash_reports` | `app`, `name`, `limit` | Lists reports; `name` reads one |

Text recognition uses Apple's Vision framework on the Mac; no screen content leaves the machine
unless your agent sends it to its model.

### Developer tools

The last eight tools close the loop for apps you build: the agent builds with `xcodebuild`,
installs the build, launches it, drives it with the tools above and reads its output and crash
reports. They use Xcode's `devicectl`, so they need Xcode on the Mac and **Developer Mode** on the
iPhone (Settings > Privacy & Security > Developer Mode). Everything else works without either.

```sh
xcodebuild -scheme MyApp -destination 'generic/platform=iOS' -derivedDataPath build build
# install_app {"path": "/path/to/build/Build/Products/Debug-iphoneos/MyApp.app"}
# launch_app  {"bundle_id": "com.example.MyApp"}
# logs        {"bundle_id": "com.example.MyApp"}      → print, NSLog and os_log lines
```

- `launch_app` sets `OS_ACTIVITY_DT_MODE` so `Logger` and `os_log` messages reach the console, as
  in Xcode. `logs` returns a `cursor`; pass it as `after` to get only newer lines. When the app
  exits or crashes, `logs` says so, and `crash_reports` lists the report.
- `crash_reports` with `name` copies the report to `~/Library/Application Support/dev.mobdev.mac/crash-reports`
  and returns the exception, the reason and the crashed thread. Frames of your own code carry
  addresses for `atos` when the report has no symbols.
- `install_app` reads the path on the Mac that runs Mobdev, also when the agent connects through a
  relay. `uninstall_app` refuses App Store and system apps.

## HTTP API

Everything listens on `127.0.0.1:4686` (`MOBDEV_PORT` overrides it) and needs
`Authorization: Bearer <token>`. The token is in `~/Library/Application Support/dev.mobdev.mac/token`.

```sh
TOKEN=$(cat ~/Library/Application\ Support/dev.mobdev.mac/token)
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:4686/v1/status
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:4686/v1/screenshot -o screen.jpg   # ?format=png, ?full=1
curl -H "Authorization: Bearer $TOKEN" -X POST http://127.0.0.1:4686/v1/tools/tap_text -d '{"text":"Settings"}'
curl -H "Authorization: Bearer $TOKEN" -X POST http://127.0.0.1:4686/v1/tools/type_text -d '{"text":"hello","submit":true}'
```

`POST /v1/tools/<name>` takes the tool's arguments and returns `{"ok", "text", "data"}`; pass
`"screenshot": true` to include one. `GET /v1/tools` lists the tools with their schemas.

## Remote access (optional)

Turn on **Remote Access** to let agents on other computers reach the phone. The Mac keeps one
outgoing WebSocket to a relay; no port is opened on the Mac.

- **Hosted relay:** create an access token at [mobdev.sh/dashboard](https://mobdev.sh/dashboard)
  and click **Open in Mobdev**. The `mobdev://connect` link fills in the relay URL and token after
  you confirm. You can also paste the token under Remote Access.
- **Your own relay:** run [`../relay`](../relay) and enter its URL.

The app then shows the remote MCP URL and a client key:

```sh
claude mcp add --transport http mobdev-remote https://relay.mobdev.sh/h/<mac-name>/mcp \
  --header "Authorization: Bearer mdc_…"
```

Relays forward requests and store nothing. Anyone with the client key can control the phone;
**New Client Key** revokes the old one, and revoking the access token in the dashboard disconnects
the Mac.

## Security and privacy

- The API binds only to 127.0.0.1, requires the bearer token, rejects browser requests (`Origin`)
  and foreign `Host` headers.
- The token and relay secret are files readable only by you (mode 0600) in
  `~/Library/Application Support/dev.mobdev.mac`. `MOBDEV_HOME` moves that directory.
- No telemetry, no account. Every agent action appears under **Activity** in the app.
- Agents act on your real phone with your accounts. Keep a human in the loop for anything that
  sends messages, pays or deletes.

## Limits

- One iPhone per Mac for now. Several can be captured, but a Bluetooth host is not yet matched to
  a USB screen, so input goes to every paired phone.
- Verified on hardware so far: screen capture from an iPhone over USB, Bluetooth pairing, the API,
  OCR, MCP, the relay, and taps, swipes and the scroll wheel with AssistiveTouch on iOS 27. Typing
  still needs a hands-on check.
- Typing supports the U.S. and German hardware layouts, including common accents. Emoji and other
  characters without a key cannot be typed.
- Portrait orientation is the tested case. Coordinates follow the current screenshot size.
- The phone must stay unlocked. Mobdev cannot enter the passcode.

## Development

```sh
swift test                      # unit, HTTP, MCP, OCR and relay end-to-end tests (needs Go for the last)
scripts/build-app.sh            # build/Mobdev Dev.app, the separate development app
```

Vision text recognition never returns on GitHub's virtualized macOS runners, so the OCR tests
are skipped when `CI` is set and only run on real Macs.

The developer tools are tested against scripted `devicectl` answers. Opt-in tests run them against
a real device or simulator (Xcode 27's `devicectl` drives both):

```sh
# Installs the app (it should print after launch), launches it and uninstalls it.
MOBDEV_TEST_DEVICE=<udid> MOBDEV_TEST_APP=/path/to/App.app swift test --filter DeveloperIntegration
# Launches an installed developer app, reads its logs, stops it, reads crash reports. Installs nothing.
MOBDEV_TEST_DEVICE=<udid> MOBDEV_TEST_BUNDLE_ID=<bundle id> swift test --filter DeveloperIntegration
```

`MobdevCore` contains everything testable: HID reports and gestures (`HID/`), screen capture and
text recognition (`Capture/`), tools (`Phone/`), `devicectl` for the developer tools
(`Developer/`), HTTP, MCP and the stdio bridge (`Server/`) and the relay client (`Relay/`). The `Mobdev` target is the SwiftUI app: a `NavigationSplitView` with
Liquid Glass controls, an inspector for setup, a `Table` for activity and a Settings scene. Tests
use a fake phone that renders real text, so OCR, `tap_text` and coordinates are exercised without
hardware. `scripts/make-icon.swift` renders the app icon on the macOS 26 grid.

## Credits

The idea comes from [TapKit](https://tapkit.ai). The Bluetooth LE HID approach (long-form `1812`
UUID, encrypted report attributes, Report Reference descriptors, Service Changed for stale caches,
absolute pointer for AssistiveTouch) is documented by [iphone-use](https://github.com/xhoantran/iphone-use)
(MIT) and [sryo/clak](https://github.com/sryo/clak). Independent implementation; not affiliated
with TapKit or MobAI.
