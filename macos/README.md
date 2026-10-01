# Mobdev for Mac

The Mobdev app: your iPhones, iOS simulators and Android devices in one window, for you and your AI
agent. Free, open source, about 2 MB, no account.

Mobdev reads the iPhone screen over the USB cable and taps and types through Bluetooth, posing as a
keyboard and pointer. Nothing is installed on the phone: no developer mode, no jailbreak. (Only the
optional UI tree on iPhones runs a small UI test there.) Booted simulators and Android devices take the
same tools. Agents get an MCP server and a small HTTP API.
An optional relay lets agents elsewhere reach the devices.

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
it again with **Mobdev › Set Up iPhone…**. Without an iPhone, choose **Simulators and Android
Only** on the welcome page: nothing asks for camera or Bluetooth access until you set one up.

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

iOS hides its on-screen keyboard while a Bluetooth keyboard is connected, with or without the
cable. After five minutes without input Mobdev lets go of Bluetooth, so the iPhone shows its own
keyboard again; the next tap or key from Mobdev connects again within a few seconds
(`MOBDEV_BLUETOOTH_REST_SECONDS` changes the five minutes).

The mirror in the app is live: click to tap, drag to swipe, scroll, and type while it has focus.
⌘V types the Mac clipboard on the phone. The inspector on the right shows what is still missing,
Activity lists every agent action, and Settings (⌘,) holds the keyboard layout and API token.

- **Apps** (in the inspector) lists the apps installed for development, or all of them. Drop an
  `.app`, `.ipa` or `.apk` on it to install; launch, stop and remove apps; follow an app's console
  live, open its crash reports and try deep links. It uses the same tools as agents, so it needs
  Developer Mode and Xcode for an iPhone, and nothing for simulators and Android.
- **Diagnose…** (under the setup steps and in the device info) checks the cable, the picture, the
  iPhone's USB screen interface, macOS's screen capture helper, Bluetooth, AssistiveTouch and
  Developer Mode, and offers the fix for each, such as restarting a stuck capture helper.
- **Record** and **Run Flow…** (in the activity header) record and replay flows; see below.

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
Actions return a fresh screenshot over MCP unless `screenshot` is `false`. With more than one
device, pass `device` (an id or name from `list_devices`) to pick one. Without it, Mobdev uses the
only device, or the connected iPhone when simulators or Android devices run next to it.

| Tool | Arguments | |
|---|---|---|
| `list_devices` | | iPhones, booted simulators and Android devices: id, name, model, system version, ready |
| `status` | | Screen and input readiness, screenshot size |
| `screenshot` | | JPEG of the screen |
| `tap` | `x`, `y` | |
| `long_press` | `x`, `y`, `seconds` | |
| `swipe` | `from_x`, `from_y`, `to_x`, `to_y`, `duration` | |
| `scroll` | `direction` (`up`/`down`), `amount`, `x`, `y` | Mouse wheel |
| `type_text` | `text`, `submit` | Into the focused field, at most 1000 characters per call |
| `press_key` | `key`, `modifiers` | e.g. `space` + `cmd` for Spotlight |
| `home` | | |
| `open_app` | `name` | Through Spotlight on an iPhone; by name or bundle ID on simulators and Android |
| `read_screen` | | All visible text with positions (on-device OCR) |
| `find_text` | `text` | |
| `tap_text` | `text`, `index` | Taps a visible label |
| `wait_for_text` | `text`, `timeout`, `gone` | |
| `ui_tree` | `contains`, `all` | Elements from the accessibility tree: role, label, identifier, value, position. Simulators, Android, and iPhones with the UI tree on |
| `tap_element` | `id`, `text`, `index`, `timeout` | Taps an element by identifier or label, waiting up to 5 s for it |
| `wait_for_element` | `id`, `text`, `timeout`, `gone` | Like `wait_for_text`, from the tree |
| `run_flow` | `path`, `steps`, `video` | Replays a flow and stops at the first failing step; `video` saves a recording (.mp4) |
| `list_apps` | `all` | Apps installed for development, or every app |
| `install_app` | `path` | A build from a path on this Mac: `.app`/`.ipa` for iPhone, `.app` for simulators, `.apk` for Android |
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
  in Xcode. `devicectl` attaches the console a moment after launch, so lines printed in the first
  milliseconds can be missing. `logs` returns a `cursor`; pass it as `after` to get only newer lines. When the app
  exits or crashes, `logs` says so, and `crash_reports` lists the report.
- `crash_reports` with `name` copies the report to `~/Library/Application Support/dev.mobdev.mac/crash-reports`
  and returns the exception, the reason and the crashed thread. Frames of your own code carry
  addresses for `atos` when the report has no symbols.
- `install_app` reads the path on the Mac that runs Mobdev, also when the agent connects through a
  relay. `uninstall_app` refuses App Store and system apps.

### Simulators and Android

Booted iOS simulators and Android emulators and phones appear next to your iPhones, in the app and
in `list_devices`, and take the same tools. Nothing needs to be set up on them: no cable, no
Bluetooth, no Developer Mode. Turn them off in Settings › General if you only want iPhones.

- **iOS Simulator** (needs Xcode): Mobdev reads the screen from the simulator's framebuffer and
  sends touches, keys and the Home button through Xcode's SimulatorKit, the way Simulator.app and
  idb do, so there is no helper app and no window to keep open. Keys follow the simulator's own
  keyboard layout. Apps go through `devicectl`, `stop_app` through `simctl`; crash reports come
  from `~/Library/Logs/DiagnosticReports`. `install_app` takes an `.app` built for the simulator:
  `xcodebuild -scheme MyApp -destination 'generic/platform=iOS Simulator' build`.
- **Android** (needs the Android SDK's adb, e.g. from Android Studio): emulators and phones with
  USB debugging appear while the adb server runs; Mobdev never starts it. Screenshots are raw
  `screencap` frames, input goes through `input`, `type_text` types ASCII text as a whole,
  `press_key` with `escape` is Back. `open_app` matches launchable package names ("Settings" opens
  `com.android.settings`). `launch_app` follows the app's logcat, `crash_reports` reads the crash
  buffer, `install_app` takes an `.apk`; `arguments` and `environment` are ignored.

### UI tree

On simulators and Android, `ui_tree` lists the elements on screen from the accessibility tree:
role, label, identifier, value and position in screenshot pixels. `tap_element` and
`wait_for_element` find an element by identifier (`accessibilityIdentifier`, or the resource id on
Android, whole or its last part) or by label. That is steadier than OCR and finds buttons that show
only an icon. Simulators are read through macOS's accessibility translation, as idb does; Android
through `uiautomator dump`, which takes about two seconds. An iPhone needs the UI tree turned on
(below); until then the tools say how, and `read_screen` and `tap_text` work instead.

### UI tree on iPhones

iOS shows an app's accessibility tree only to a UI test running on the phone. With **Developer Mode**
on the iPhone and **Xcode** on the Mac, open the iPhone's info in Mobdev, pick a team under **UI
Tree** and click **Turn On**. Mobdev builds Mobdev Runner, a small XCUITest (`Runner/`), signs it
with your team and keeps it running on the iPhone, the way WebDriverAgent does. `ui_tree`,
`tap_element` and `wait_for_element` then work as on simulators, and Record names clicked elements.

- **Team**: Mobdev lists the teams of the Apple Development certificates in your keychain (the
  certificate's organizational unit, not the ID in parentheses in its name) and picks the newest.
  Xcode must be signed in to that team's Apple Account (Xcode's Settings) to make the provisioning
  profile and register the iPhone. The runner's bundle ID is `dev.mobdev.runner.<team>`.
- **First start**: the build takes a minute or two; later starts a few seconds. With a free Apple
  Account, iOS asks you once to trust the developer: Settings › General › VPN & Device Management.
  A failed start shows xcodebuild's reason and the usual fix under UI Tree, such as turning on
  Settings › Developer › Enable UI Automation; **Try Again** builds again.
- **While it runs**: Mobdev keeps `xcodebuild test-without-building` running and starts it again
  when it ends, stops it when the iPhone is unplugged or Mobdev quits, and starts it when the iPhone
  is back. The runner appears on the iPhone as MobdevRunner-Runner. Build, logs and the copy of the
  project are in `~/Library/Application Support/dev.mobdev.mac/runner/<udid>`.
- The runner answers HTTP on port 47270 on the iPhone's loopback interface only. Mobdev reaches it
  through usbmuxd over the USB cable, and every request carries a token made for that start, so
  other apps on the phone cannot use it. Taps still go through Bluetooth; text the keyboard layout
  has no keys for, such as emoji, is typed by the runner.

### Flows and CI

A flow is a list of tool calls saved as JSON, one step per line; a bare name is a tool without
arguments:

```json
{
  "name": "Sign in",
  "steps": [
    {"install_app": {"path": "build/Build/Products/Debug-iphonesimulator/MyApp.app"}},
    {"launch_app": {"bundle_id": "com.example.MyApp", "restart": true}},
    {"tap_element": {"id": "email"}},
    {"type_text": {"text": "me@example.com", "submit": true}},
    {"wait_for_element": {"text": "Welcome"}},
    "home"
  ]
}
```

- **Record** in a device's activity collects every call an agent or you make on it, and clicks,
  drags and keys in the app's window. On simulators and Android, a click on an element with a
  unique identifier or label is saved as `tap_element`, so the flow survives layout changes;
  anything else as `tap` at the same point. **Save…** writes the file.
- **Run Flow…**, the `run_flow` tool (`path` to a file on the Mac, or `steps` inline) and
  `Mobdev flow` replay it, stop at the first step that fails and say which. `tap_element` waits up
  to 5 s for its element, so a flow rarely needs explicit waits.
- Every run can keep a video. **Run Flow…** records one, and its result offers **Show Video**; the
  app keeps the newest 20 in `~/Library/Application Support/dev.mobdev.mac/flow-videos`.
  `run_flow` writes one when `video` names an .mp4 file on the Mac. The video has about
  10 frames a second on simulators and iPhones; on Android, as many as `screencap` allows, one to
  three. It ends on the screen the flow left, held for a moment, so a failure is easy to see.
- `Mobdev flow` runs without the app, for scripts and CI, on booted simulators and Android devices:

  ```sh
  /Applications/Mobdev.app/Contents/MacOS/Mobdev flow sign-in.json --device <udid> --artifacts out
  ```

  It prints a line per step and exits 0 when every step passed, 1 when one failed and 2 when the
  flow could not start. `--artifacts` keeps a video of the run (`run.mp4`), the activity log,
  copied crash reports and, after a failure, `failure.png`; `--no-video` skips the video. Ctrl-C
  stops the flow and still finishes the video. iPhones need the running app: call `run_flow` over
  MCP or the HTTP API.

[`examples/flows`](../examples/flows) has a flow and a small app to try it with, and
[`.github/workflows/flows.yml`](../.github/workflows/flows.yml) runs them on GitHub's free
`macos-26` runners. A GitHub Actions job for your app:

```yaml
- name: Boot a simulator
  run: |
    UDID=$(xcrun simctl create ci "iPhone 17")
    xcrun simctl bootstatus "$UDID" -b
    echo "UDID=$UDID" >> "$GITHUB_ENV"
- name: Build
  run: xcodebuild -scheme MyApp -destination "id=$UDID" -derivedDataPath build build
- name: Run flows
  run: |
    curl -fsSL -o Mobdev.dmg https://github.com/niklas-schmidt-dev/mobdev/releases/latest/download/Mobdev.dmg
    hdiutil attach -nobrowse -mountpoint /tmp/mobdev Mobdev.dmg
    /tmp/mobdev/Mobdev.app/Contents/MacOS/Mobdev flow flows/sign-in.json --device "$UDID" --artifacts flow-artifacts
- uses: actions/upload-artifact@v4
  if: failure()
  with: { name: flow-artifacts, path: flow-artifacts }
```

When a flow fails, the uploaded artifact has `run.mp4`, a video of the run that ends on the failing
screen, next to `failure.png` and the activity log. Use `if: always()` to keep the video of passing
runs too.

In CI, prefer `tap_element` and `wait_for_element` to the OCR tools: Vision text recognition does
not return on GitHub's virtualized Macs, and Mobdev gives up on it after 90 seconds.

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

- Several iPhones on one Mac each get their own Bluetooth connection: matched by name, then by
  model, and when that does not tell (two of the same model that both call themselves "iPhone"),
  by moving each connection's pointer and looking which screen shows it, which needs AssistiveTouch.
  This has not been tried with two iPhones at once yet.
- Verified on hardware so far: screen capture from an iPhone over USB, Bluetooth pairing, the API,
  OCR, MCP, the relay, taps, swipes and the scroll wheel with AssistiveTouch, and typing with the
  German layout (letters, umlauts, ß and symbols), on iOS 27.
- Typing supports the U.S. and German hardware layouts, including common accents. Emoji and other
  characters without a key need the UI tree on: Mobdev Runner types them.
- Portrait orientation is the tested case. Coordinates follow the current screenshot size.
- The phone must stay unlocked. Mobdev cannot enter the passcode.
- Simulator input uses Xcode's private SimulatorKit; tested with Xcode 27 and 26.6. A later Xcode
  can change it, as it did for idb and AXe. Simulator screens show the main display only.
- Before Xcode 27, `devicectl` does not know simulators, so their apps go through `simctl`. Then
  iOS asks before `open_url` opens an app's own URL scheme ("Open in …?"); tap its Open button,
  e.g. with `tap_element`.
- Android types ASCII text only (`input text`), and adb does not know app names, so `open_app`
  matches package names.
- `ui_tree` reads the simulator through macOS's private accessibility translation; tested with
  Xcode 27 on macOS 27. `Mobdev flow` is tested on a Mac, not yet on GitHub's hosted runners.
- Recording does not capture the scroll wheel; drag to scroll while recording.
- Mobdev Runner finds the app in front through XCTest's private API, as WebDriverAgent does; tested
  with Xcode 27 on simulators. Its frames assume portrait. It is built with your Xcode, so a new
  Xcode can break it until Mobdev catches up.

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

Simulators and Android are tested with fake devices and parsers fed real `adb` output. The
opt-in `EmulatorIntegration` tests drive a booted simulator and a running emulator through every
tool. The simulator one uses the fixture app in [`../examples/flows/fixture`](../examples/flows):
it prints each tap as `fixture: tap <x> <y> fraction <fx> <fy>`, echoes typed text and crashes
when launched with the argument `crash`. Build it with its `build.sh`:

```sh
../examples/flows/fixture/build.sh
MOBDEV_TEST_SIMULATOR=<udid> MOBDEV_TEST_SIMULATOR_APP=../examples/flows/fixture/MobdevFixture.app swift test --filter EmulatorIntegration
MOBDEV_TEST_ANDROID=emulator-5554 MOBDEV_TEST_ANDROID_APK=/path/to/any.apk swift test --filter EmulatorIntegration
```

The Android tests crash the Settings app with `am crash` and install, remove and reinstall the
.apk; run the emulator with `-read-only` to throw those changes away.

Mobdev Runner is tested against usbmuxd and runner answers from fakes. The opt-in `RunnerIntegration`
test builds it for a simulator (no signing; the runner listens on the Mac's 127.0.0.1), drives Settings
through `/tree`, `/tap` and `/type` and then `ui_tree`, `tap_element` and `wait_for_element`, and
checks that stopping ends it. Two read-only checks help on an iPhone: one asks usbmuxd for its
device list, the other reads the tree of a runner started by hand with
`TEST_RUNNER_MOBDEV_RUNNER_TOKEN=<token> xcodebuild test-without-building …`, through usbmuxd:

```sh
UDID=$(xcrun simctl create "Mobdev Runner Test" "iPhone 17")
MOBDEV_TEST_RUNNER_SIMULATOR=$UDID swift test --filter RunnerIntegration
xcrun simctl delete "$UDID"
MOBDEV_TEST_USBMUXD=<iPhone udid> swift test --filter usbmuxdListsTheConnectedIPhone
MOBDEV_TEST_RUNNER_DEVICE=<iPhone udid> MOBDEV_TEST_RUNNER_TOKEN=<token> swift test --filter runnerOnAnIPhoneAnswersOverUSB
```

`MobdevCore` contains everything testable: HID reports and gestures (`HID/`), screen capture and
text recognition (`Capture/`), tools (`Phone/`), `devicectl` for the developer tools
(`Developer/`), simulators and Android (`Emulators/`), building Mobdev Runner and reaching it through
usbmuxd (`Runner/`; its Xcode project is `Runner/` next to `Sources/`), HTTP, MCP and the stdio
bridge (`Server/`) and the relay client (`Relay/`). The `Mobdev` target is the SwiftUI app: a
`NavigationSplitView` with Liquid Glass controls, an inspector for setup, a `Table` for activity and
a Settings scene. Tests use a fake phone that renders real text, so OCR, `tap_text` and coordinates
are exercised without hardware. `scripts/make-icon.swift` packages the Imagegen artwork from
`../assets/branding/` on the macOS 26 icon grid; `--dev` selects the amber development variant. See
[`../assets/branding/README.md`](../assets/branding/README.md) to regenerate all branding exports.

## Credits

The idea comes from [TapKit](https://tapkit.ai). The Bluetooth LE HID approach (long-form `1812`
UUID, encrypted report attributes, Report Reference descriptors, Service Changed for stale caches,
absolute pointer for AssistiveTouch) is documented by [iphone-use](https://github.com/xhoantran/iphone-use)
(MIT) and [sryo/clak](https://github.com/sryo/clak). Independent implementation; not affiliated
with TapKit or MobAI.
