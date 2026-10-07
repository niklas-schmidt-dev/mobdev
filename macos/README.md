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
(`MOBDEV_BLUETOOTH_REST_SECONDS` changes the five minutes). For ten minutes after an iPhone or
iPad is plugged in without pairing, Mobdev stays connected so that it can still pair; **Show on
iPhone Again** connects again after that. Moving the mouse over the mirror
connects right away and keeps Bluetooth awake, so the first click goes through without delay.
Until the iPhone has connected all of its inputs again, Mobdev refuses input rather than send a
click without the pointer move before it.

The mirror in the app is live: click to tap, drag to swipe, swipe with two fingers on the trackpad
(sideways too), scroll with the wheel (a sideways wheel or Shift scrolls sideways), and type while
it has focus.
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
- **Inspect** (in the toolbar) lays an inspector over the screen: the element under the pointer is
  outlined with its role, label and identifier, and a click copies the step that taps it, such as
  `{"tap_element":{"id":"login"}}`, instead of tapping the device. Simulators, Android, and
  iPhones with the UI tree on.
- **Settings › Agents** lists apps agents may not open; see [Security and privacy](#security-and-privacy).

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
| `tap` | `x`, `y`, `double` | `x` and `y` may also be shares of the screen such as `"50%"`, as in every tool with coordinates |
| `long_press` | `x`, `y`, `seconds` | |
| `swipe` | `from_x`, `from_y`, `to_x`, `to_y`, `duration` | |
| `scroll` | `direction` (`up`/`down`/`left`/`right`), `amount`, `x`, `y` | Mouse wheel; `right` reveals content further right |
| `type_text` | `text`, `submit` | Into the focused field, at most 1000 characters per call |
| `press_key` | `key`, `modifiers`, `count` | e.g. `space` + `cmd` for Spotlight; `volume_up` and `volume_down` press the buttons (iPhones, Android) |
| `home` | | |
| `open_app` | `name` | Through Spotlight on an iPhone; by name or bundle ID on simulators and Android |
| `read_screen` | | All visible text with positions (on-device OCR) |
| `find_text` | `text` | |
| `tap_text` | `text`, `index`, `double`, `hold` | Taps a visible label; `double` taps twice, `hold` presses for that many seconds |
| `wait_for_text` | `text`, `timeout`, `gone` | |
| `observe` | `image`, `contains` | The screen as numbered marks: UI tree elements, else recognized text; `image` draws them on a screenshot |
| `tap_mark` | `mark` | Taps a mark from the last `observe` |
| `scroll_until_visible` | `text`, `id`, `direction`, `max_scrolls` | Scrolls until it shows, stops at the end of the list |
| `wait_for_idle` | `timeout`, `stable` | Until the screen stops changing, status bar ignored |
| `ui_tree` | `contains`, `all` | Elements from the accessibility tree: role, label, identifier, value, position. Simulators, Android, and iPhones with the UI tree on |
| `tap_element` | `id`, `text`, `index`, `timeout`, `double`, `hold` | Taps an element by identifier or label, waiting up to 5 s for it |
| `wait_for_element` | `id`, `text`, `timeout`, `gone` | Like `wait_for_text`, from the tree |
| `assert_screenshot` | `name` or `path`, `threshold`, `mask`, `compare_status_bar`, `update` | Compares the screen with a baseline picture and fails with a diff; records the baseline when there is none (see [Checks](#checks)) |
| `accessibility_audit` | `image`, `fail_on`, `ignore` | Missing labels, small tap targets, low text contrast, duplicate and unclear labels, from the UI tree |
| `assert_with_ai` | `question`, `expect` | Asks Apple Intelligence on the Mac a yes/no question about the screen |
| `run_flow` | `path`, `steps`, `variables`, `video` | Replays a flow (JSON or Maestro YAML) and stops at the first failing step; `video` saves a recording (.mp4) |
| `run_tests` | `project`, `tests`, `variables`, `video` | Runs a project's tests on this device: every result, the first failure's screen, results.json and junit.xml |
| `list_tests` | `project` | A project's tests and its newest results |
| `save_test` | `project`, `name`, `steps`, `description`, `platforms`, `file` | Writes a test into the project, creating it when needed |
| `test_result` | `project`, `run` | The newest run's results, with each failure's step, screenshot and video |
| `list_apps` | `all` | Apps installed for development, or every app |
| `install_app` | `path` | A build from a path on this Mac: `.app`/`.ipa` for iPhone, `.app` for simulators, `.apk` for Android |
| `uninstall_app` | `bundle_id` | Only apps installed for development |
| `launch_app` | `bundle_id`, `arguments`, `environment`, `restart` | Captures what the app prints |
| `stop_app` | `bundle_id` | |
| `open_url` | `url` | Deep links, universal links, web pages; confirms iOS's "Open in …?" where there is a UI tree |
| `logs` | `bundle_id`, `after`, `lines`, `contains` | Output of launched apps and how they ended |
| `crash_reports` | `app`, `name`, `limit` | Lists reports; `name` reads one |
| `set_location` | `latitude`, `longitude`, `route`, `speed`, `clear` | A simulated position, or a route the device follows |
| `set_permission` | `bundle_id`, `permission`, `state` | Grant, revoke or reset location, photos, contacts, camera and more without the prompt |
| `send_push` | `bundle_id`, `title`, `body`, `badge`, `data`, `payload` | A push notification to a simulator app |
| `set_appearance` | `dark`, `text_size`, `increase_contrast`, `reduce_motion` | Dark mode, Dynamic Type and accessibility switches |
| `set_language` | `language`, `bundle_id` | e.g. `de-DE`: the simulator's, or one Android app's |
| `set_status_bar` | `preset`, `time`, `battery_level`, `battery_state`, `wifi_bars`, `cellular_bars`, `network` | `screenshot` gives 9:41 and full bars; `clear` resets |
| `biometrics` | `action` (`match`/`fail`/`enroll`/`unenroll`) | Answers a Face ID, Touch ID or fingerprint prompt |
| `reset_app` | `bundle_id`, `keychain` | Deletes an app's data as if just installed |
| `clipboard` | `text` | Reads the clipboard, or sets it to `text` |
| `set_orientation` | `orientation` | `portrait`, `landscape_left`, `landscape_right`, `portrait_upside_down` |
| `start_recording` | `path` | Records the screen to an .mp4 until `stop_recording` |
| `stop_recording` | | Ends the recording and says where it is |
| `recent_steps` | `count`, `clear` | The newest actions that worked, as flow steps for `save_test` |
| `run_shortcut` | `name` | Runs a shortcut from Apple's Shortcuts app |
| `performance` | `bundle_id`, `seconds`, `max_cpu`, `max_memory_mb`, `max_janky_percent` | CPU, memory and (Android) frames of a running app; budgets fail the call. Simulators and Android |
| `measure_launch` | `bundle_id`, `runs`, `method`, `max_ms`, `stable` | Cold launch time over several runs: min, median, max |
| `dev_menu` | `port` | Opens a React Native or Expo app's developer menu |
| `reload_app` | `port` | Reloads a React Native or Expo app through Metro, else through its developer menu |

Text recognition uses Apple's Vision framework on the Mac; no screen content leaves the machine
unless your agent sends it to its model. Each recognition runs in a fresh process (`Mobdev __text`),
and moves to the CPU when the Neural Engine fails. If it fails anyway, the text tools answer from the
UI tree on simulators, Android and iPhones with Mobdev Runner and say so. Without a tree, they say
that recognition failed and suggest `screenshot`.

### From the terminal

`Mobdev call <tool>` runs one tool from a shell, for scripts and for agents that prefer a terminal
to MCP; `Mobdev <tool> key=value …` is short for it and `Mobdev tools` lists the tools. Values are
JSON where they parse as JSON and text otherwise:

```sh
M=/Applications/Mobdev.app/Contents/MacOS/Mobdev
$M observe
$M tap_mark mark=4
$M type_text text="hello world" submit=true
$M screenshot --image screen.png
$M call set_location '{"latitude": 52.52, "longitude": 13.405}' --device "iPhone 17"
```

It goes through the running app, so it reaches iPhones too and shows in Activity; without the app,
or with `--local`, it runs by itself on booted simulators and Android devices, like `Mobdev flow`.
`--json` prints the whole result, `--image` saves a returned screenshot. It exits 0 when the tool
succeeded, 1 when it reported an error and 2 when it could not run. `start_recording`, `tap_mark`
and other calls that build on an earlier one need the app.

### Observe, marks and waits

`observe` is the cheapest way for an agent to see a screen: a numbered list of what can be read or
tapped, from the UI tree where there is one, else from text recognition, such as
`[4] Button "Sign in" id=login (295, 640)`. A tappable row without a label, as Android lists have,
takes the text inside it. `image: true` adds a screenshot with the numbers drawn on it, which helps
models that misjudge coordinates. `tap_mark` taps a mark by its number; call `observe` again once
the screen changed. While a flow is being recorded, a tapped mark is saved as `tap_element` (or
`tap_text`) so the flow does not depend on the numbers.

`scroll_until_visible` scrolls until an element (`id`) or text shows and stops when the list no
longer moves. `wait_for_idle` waits until the screen has not changed for `stable` seconds (the
status bar does not count), instead of a fixed pause after an animation or a load.

### Device state

Tests and agents set up a situation directly instead of tapping through Settings:

| | iOS Simulator | Android | iPhone |
|---|---|---|---|
| `set_location` | `simctl location`, routes too | emulators (`geo fix`); Mobdev moves along routes | `devicectl`, Developer Mode |
| `set_permission` | `simctl privacy`: calendar, contacts, location, photos, microphone, motion, reminders, Siri (no camera or notifications) | `pm grant`/`revoke`, camera and notifications too, or any android.permission name | no |
| `send_push` | `simctl push` with the APNs payload | a notification posted from the shell, not delivered to the app | no; pushes come through your APNs key |
| `set_appearance` | `simctl ui`; Reduce Motion needs Xcode 27 | night mode, font scale, contrast, animations | `devicectl`, Developer Mode |
| `set_language` | the whole simulator; relaunch the app | one app (Android 13 and later) | no |
| `set_status_bar` | `simctl status_bar` | System UI demo mode | `devicectl`, Developer Mode |
| `biometrics` | Face ID and Touch ID, enrolled or not | the emulator's fingerprint sensor (enroll once in Settings) | no |
| `reset_app` | deletes the app's data, optionally the keychain | `pm clear` | no; reinstall instead |
| `clipboard` | `simctl pbcopy`/`pbpaste` | no | `devicectl`, Developer Mode |
| `set_orientation` | Xcode 27 | any | `devicectl`, Developer Mode |

The iPhone column uses Xcode 27's `devicectl` and has been tried on simulators, not yet on an
iPhone. For one launch of an iOS app in another language, `launch_app` with `arguments`
`["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]` works on simulators and iPhones alike. A
language set with `set_language` reaches apps when they start again; system alerts follow after the
simulator restarts. A simulator's screenshot stays upright when it turns: the app shows sideways in
it, and taps use the same picture, so they still land where the agent sees the element.

### Recordings and recent steps

`start_recording` records the screen to an .mp4 (in `recordings/` in Mobdev's folder unless
`path` names one) until `stop_recording`, at about ten frames a second on simulators and iPhones;
it stops by itself after 30 minutes. `recent_steps` returns the newest actions that worked on a
device, by any agent or in the app, as flow steps: looks and failed calls are left out and typing
is merged. Once an agent found a path through the app, it saves those steps with `save_test`.

`run_shortcut` runs a shortcut from Apple's Shortcuts app by name, through a `shortcuts://` link on
simulators and iPhones in Developer Mode, otherwise through Spotlight. Shortcuts can do what no
tool reaches from outside, such as turning on a Focus or changing the brightness.

### Developer tools

The tools from `list_apps` to `crash_reports` close the loop for apps you build: the agent builds
with `xcodebuild`, installs the build, launches it, drives it with the tools above and reads its
output and crash reports. They use Xcode's `devicectl`, so they need Xcode on the Mac and **Developer Mode** on the
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
- `install_app` reads `path` on the Mac that runs Mobdev, also when the agent connects through a
  relay. A build made elsewhere, such as in a cloud agent's container, is uploaded first and
  installed with `upload` (see [Install builds from anywhere](#install-builds-from-anywhere)).
  `uninstall_app` refuses App Store and system apps.

### Performance

`performance` samples a running app for `seconds` (default 5, at most 60) and reports average and
peak CPU as a percent of one core, memory at the start, the end and its peak, and on Android its
frames. `measure_launch` stops the app, starts it again and times it `runs` times (default 3).
Budgets turn both into checks for tests and flows: the call fails, with the numbers, when the app
goes over `max_cpu` (average), `max_memory_mb` (peak), `max_janky_percent` or `max_ms` (median).

- **iOS Simulator**: the app is a process on the Mac. Mobdev finds its pid with `launchctl list`
  inside that simulator and reads CPU time and physical footprint (the memory Xcode's gauge shows)
  with `proc_pid_rusage`. Launch time is iOS's own `ApplicationFirstFramePresentation` signpost,
  streamed with `simctl spawn <udid> log stream`: from SpringBoard taking the launch request to the
  app's first frame, the number Xcode's Organizer and MetricKit report. Simulators have no frame
  times; use Android or Instruments for those. A simulator shares the Mac's CPU, so its numbers say
  how an app compares with itself, not how fast an iPhone is.
- **Android**: one adb shell command reads `/proc/<pid>/stat` and `VmRSS` about once a second,
  resets `dumpsys gfxinfo` before and reads it after (frames, janky share, 50th to 99th percentile
  frame times), and adds the PSS from `dumpsys meminfo`. Launch time is `am start -W`'s `TotalTime`
  after `am force-stop`.
- **iPhone**: CPU and memory need Instruments, so `performance` says how to record them with
  `xcrun xctrace record --template 'Activity Monitor'`. `measure_launch` times the screen instead.
- `method: "screen"` (any device): from the first frame that changes (the launch animation) to the
  last change before the screen stays still for `stable` seconds (default 2). It includes what the
  app loads after its first frame, but a launch or splash screen shown longer than `stable` ends it
  early.
- Over a relay a call has 90 seconds, so keep `seconds`, and `runs` times the launch, below that.

### React Native, Expo and Flutter

- `reload_app` connects to Metro's message socket on this Mac (`ws://localhost:<port>/message`,
  port 8081 by default, also Expo CLI) and sends `reload` to every app connected to it, as `r` in
  Metro's terminal does; Expo CLI accepts it only from the same Mac. When no app is connected, or
  Metro does not answer, Mobdev opens the developer menu and taps its Reload.
- `dev_menu` shakes a simulator (the Darwin notification `com.apple.UIKit.SimulatorShake`, which
  UIKit in the simulator turns into a shake for the frontmost app), presses the Menu key on Android
  (`input keyevent 82`), and on an iPhone, which cannot be shaken from the Mac, sends `devMenu`
  through Metro.
- Open Expo Go projects with `open_url` and `exp://127.0.0.1:8081`, development builds with
  `<scheme>://expo-development-client/?url=…`. `testID` is the `id` for `tap_element`. The
  [`mobdev-react-native`](../skills/mobdev-react-native/SKILL.md) skill covers the loop, logs and
  Flutter.

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
  USB debugging appear while the adb server runs; Mobdev never starts it. The screen and input go
  through [scrcpy](https://github.com/Genymobile/scrcpy)'s server, which Mobdev pushes to
  `/data/local/tmp` and starts over adb on first use (a picture or a tap, about half a second):
  an H.264 stream at 1280 pixels on the long edge, decoded with VideoToolbox, so the window shows
  20 pictures a second and screenshots cost nothing; touches with real timing (a long press holds,
  a swipe moves) and two fingers for a pinch; `type_text` types printable ASCII as key events and
  any other text (umlauts, emoji, CJK) through the clipboard and Paste, so the clipboard holds it
  afterwards; `clipboard` reads and sets the device's clipboard. The server runs as the shell
  user, ends with Mobdev or when the device goes away, deletes its own copy, and starts again
  after it died or the device rebooted. When it cannot run, Mobdev falls back to adb and says why
  in its log: raw `screencap` frames (one to three a second), `input` for touches and keys, ASCII
  text only and no clipboard. `MOBDEV_ANDROID_SCRCPY=0` keeps Mobdev on adb alone. `press_key`
  with `escape` is Back. `open_app` matches launchable package names ("Settings" opens
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
arguments. Maestro's YAML flows run too ([below](#maestro-flows)).

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

#### Control steps

Control steps decide what runs by looking at the screen, so a flow needs no guessed waits. Their
keys are not tool names:

```json
{
  "name": "Check out",
  "steps": [
    {"launch_app": {"bundle_id": "com.example.MyApp"}},
    {"if": {"visible": {"text": "Allow"}, "then": [{"tap_element": {"text": "Allow"}}]}},
    {"repeat": {"until_visible": {"id": "checkout"}, "max": 10, "steps": [{"scroll": {"direction": "down"}}]}},
    {"extract": {"id": "total", "into": "TOTAL"}},
    {"retry": {"times": 2, "steps": [
      {"tap_element": {"id": "checkout"}},
      {"wait_for_element": {"text": "Pay ${TOTAL}", "timeout": 5}}
    ]}},
    {"run": "pay.json"},
    {"tap_element": {"text": "Rate this app", "timeout": 2}, "optional": true}
  ]
}
```

| Step | |
|---|---|
| `{"if": {"visible": {"text": "…"}, "then": […], "else": […]}}` | Runs `then` when the element or text is on screen now, else `else` (optional). `not_visible` is the opposite; `{"platform": "ios"}` or `"android"` decides by the device. Visible means on screen at this moment, from the UI tree where there is one, else by text recognition (text only). Nothing is waited for. |
| `{"repeat": {"times": 3, "steps": […]}}` | Runs the steps 3 times, at most 100. |
| `{"repeat": {"while_visible": {…}, "max": 20, "steps": […]}}` | Runs them while the element is on screen, checked before each round; `until_visible` until it is. `max` (default 20, at most 100) ends the loop without failing it, as Maestro's does: follow it with a wait when the end matters. |
| `{"retry": {"times": 2, "steps": […]}}` | Runs the steps again from the first when one fails, up to 2 more times (default 1, at most 10). Failed attempts show in the results, marked –, and do not fail the flow. |
| `{"run": "sign-in.json"}` | Runs another flow file, JSON or Maestro YAML, relative to the file that names it; in a test project also relative to the project folder. Subflows nest up to 5 deep, and a flow that runs itself is an error. Inline `steps` of `run_flow` need an absolute path. |
| `{"set": {"EMAIL": "me@example.com"}}` | Sets variables for later steps. |
| `{"extract": {"id": "total", "into": "TOTAL"}}` | Reads an element of the UI tree into a variable: its value, or its label when it has none; `"from": "label"` or `"value"` chooses. Waits for the element like `tap_element` (`timeout`, default 5 s); `index` picks one of several. |

- `${NAME}` in a step's strings, conditions included, is a variable: from `set` and `extract`,
  `--var NAME=value` for `Mobdev flow`, `variables` for `run_flow`, and in tests also from
  `mobdev.json`. A name nothing sets fails the flow before its first step, at the step that uses it.
- `"optional": true` next to any step's key lets it fail: the result marks it –, and the flow goes on.
- Results number nested steps: 3.2 is the second step inside step 3 (an `else` counts on from its
  `then`), and a step that a repeat or retry ran again says which round or attempt. A failed flow
  names the innermost failing step, "failed at step 3.2 of 7"; `run_flow`'s data has `failed_step`
  (3) and `failed_at` ("3.2"). `Mobdev flow` prints each step as it finishes, the steps inside a
  control step indented and before it.
- A flow has at most 500 steps, counting those inside control steps and subflows, and one run takes
  at most 2000, counting every round and retry. Cancelling stops at once, also inside a loop.
- Recording saves plain tool calls; add control steps by hand or let an agent write them.

#### Recording, replaying and CI

- **Record** in a device's activity collects every call an agent or you make on it, and clicks,
  drags and keys in the app's window. On simulators and Android, a click on an element with a
  unique identifier or label is saved as `tap_element`, so the flow survives layout changes;
  anything else as `tap` at the same point. **Save…** writes the file.
- **Run Flow…**, the `run_flow` tool (`path` to a .json or Maestro .yaml file on the Mac, or
  `steps` inline) and `Mobdev flow` replay it, stop at the first step that fails and say which.
  `tap_element` waits up to 5 s for its element, so a flow rarely needs explicit waits.
- Every run can keep a video. **Run Flow…** records one, and its result offers **Show Video**; the
  app keeps the newest 20 in `~/Library/Application Support/dev.mobdev.mac/flow-videos`.
  `run_flow` writes one when `video` names an .mp4 file on the Mac. The video has about
  10 frames a second on simulators, iPhones and Android (on Android without scrcpy, as many as
  `screencap` allows, one to three). It ends on the screen the flow left, held for a moment, so a
  failure is easy to see.
- `Mobdev flow` runs without the app, for scripts and CI, on booted simulators and Android devices:

  ```sh
  /Applications/Mobdev.app/Contents/MacOS/Mobdev flow sign-in.json --device <udid> --artifacts out
  ```

  It prints a line per step and exits 0 when every step passed, 1 when one failed and 2 when the
  flow could not start. `--artifacts` keeps a video of the run (`run.mp4`), the activity log,
  copied crash reports, `summary.md` and, after a failure, `failure.png`; `--no-video` skips the
  video, and `--var NAME=value` sets a variable (repeatable). It waits
  up to two minutes for the device to show up, since a simulator booting on a slow CI runner takes
  a while; `--wait <seconds>` changes that. Ctrl-C
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

#### Maestro flows

`Mobdev flow`, `run_flow` (`path`), **Run Flow…** and test projects (`tests/*.yaml`) also take
[Maestro](https://maestro.mobile.dev) flows. Mobdev converts the YAML into the steps above when it
loads the file; a command it cannot do fails the load with its name and line, so a flow never
half-works. What changes on the way (a screenshot left out, a pattern read as text) is printed as a
note. `Mobdev convert` prints a flow in the other format:

```sh
Mobdev convert login.yaml > login.json     # Maestro to Mobdev
Mobdev convert login.json > login.yaml     # Mobdev to Maestro
```

| Maestro | Mobdev |
|---|---|
| config `appId`, `name`, `env`, `onFlowStart` | the app of commands that name none, the flow's name, a `set` step, steps at the start |
| `launchApp` (`appId`, `clearState`, `clearKeychain`, `stopApp`, `arguments`, `permissions`) | `reset_app` (`keychain`), `set_permission`, `launch_app` (`restart`; `arguments` as `-key value`) |
| `stopApp`, `killApp`, `clearState` | `stop_app`, `stop_app`, `reset_app` |
| `tapOn`, `doubleTapOn`, `longPressOn` with text, `id`, `index` or `point` | `tap_element` (`double`, `hold: 1`); at a point `tap` or `long_press`; `tapOn`'s `repeat` a repeat step |
| `inputText`, `eraseText`, `pasteText` | `type_text`; `press_key` backspace with `count` (default 50, at most 100); `type_text` `${COPIED_TEXT}` |
| `pressKey` | `press_key` (Enter, Backspace, Tab, Volume Up and Down, Remote Dpad keys); Home is `home`, Back is `back` below |
| `back` | `{"if": {"platform": "android", "then": [{"press_key": {"key": "escape"}}], "else": [{"tap_element": {"id": "BackButton"}}]}}`: Android's Back key; iOS has no system Back, and escape does not go back there, so on iOS it taps the navigation bar's back button, whose identifier is BackButton |
| `assertVisible`, `assertNotVisible` | `wait_for_element` with `timeout` 7 (and `gone`) |
| `extendedWaitUntil` (`visible`, `notVisible`, `timeout`) | `wait_for_element` with the timeout in seconds, at most 60 |
| `scrollUntilVisible` (`element`, `direction`, `timeout`) | `scroll_until_visible`, one scroll per 2 s of timeout |
| `scroll`, `swipe` (`direction`, or `start` and `end`, `duration`) | `scroll` down, `swipe` between shares of the screen |
| `openLink`, `waitForAnimationToEnd`, `setLocation`, `travel`, `setOrientation`, `setPermissions` | `open_url`, `wait_for_idle`, `set_location` (`travel` as a route, km/h to m/s), `set_orientation`, `set_permission` |
| `runFlow` (a file, or `commands`; `when` with `visible`, `notVisible`, `platform`; `env`) | `run`, or the commands in place; `when` becomes `if`, `env` a `set` |
| `repeat` (`times`, `while`), `retry` (`maxRetries`, `commands` or `file`) | `repeat` (`times`, or `while_visible`/`until_visible` with `times` as `max`), `retry` |
| `copyTextFrom`, `${maestro.copiedText}` | `extract` into `COPIED_TEXT`, `${COPIED_TEXT}` |
| `optional`, `label` | `"optional": true`; labels are left out |
| `hideKeyboard`, `takeScreenshot` | left out with a note: Mobdev types with a hardware keyboard on iOS, and keeps a video of the run |

Limits:

- Mobdev runs no JavaScript: `evalScript`, `runScript`, `assertTrue`, `when: true` and `${…}`
  expressions other than a variable name fail, as do the AI commands, `inputRandom…`, airplane
  mode, `addMedia`, `startRecording`, `clearKeychain` on its own and `onFlowComplete`, which would
  run after a failure.
- Selectors are text, `id`, `index` and `point`. Relative ones (`below`, `childOf`, …) and states
  (`enabled`, `checked`, …) fail. Maestro matches text as a regular expression over the whole label;
  Mobdev looks for the text itself, exact matches first, so anchors, a leading or trailing `.*` and
  escapes go, and a pattern that remains is noted.
- Points in percent carry over exactly. Points in pixels are read as pixels of Mobdev's screenshot
  (long edge 1280), which are not Maestro's, and are noted.
- The YAML may use block and flow mappings and lists, quoted and plain text, comments, `---` and
  `|` or `>` blocks. Anchors, aliases, tags and plain text over several lines fail with the line.

Converting a Mobdev flow to Maestro writes every step that has a Maestro command; the others
(`observe`, a `set` that is not at the start of the flow or of an `if`, `if` on visibility with
`else`, `extract` into another name than COPIED_TEXT, keys with modifiers, …) fail together with
their numbers. A 7-second wait goes back to `assertVisible`, `reset_app` before `launch_app` to
`launchApp` with `clearState`, and a `run` of a .json flow names the .yaml you convert it to.

### Tests

A project is a folder in your repository with the tests of one app: `mobdev.json` names the app,
and each file in `tests/` is one test, a flow with a name, a description and the platforms it
runs on, or a Maestro flow (`.yaml`, named by its config's `name`). A `run` step finds its
subflow next to the test or relative to the project folder, so shared flows can live in, say,
`flows/`.

```json
{
  "name": "My App",
  "app": {
    "bundle_id": "com.example.MyApp",
    "builds": {"simulator": "build/Build/Products/Debug-iphonesimulator/MyApp.app", "android": "app/build/outputs/apk/debug/app-debug.apk"}
  },
  "before_each": [{"launch_app": {"bundle_id": "com.example.MyApp", "restart": true}}],
  "variables": {"EMAIL": "me@example.com"},
  "secrets": ["PASSWORD"]
}
```

```json
{
  "name": "Sign in",
  "description": "A member signs in and sees the welcome screen.",
  "steps": [
    {"tap_element": {"id": "email"}},
    {"type_text": {"text": "${EMAIL}", "submit": true}},
    {"tap_element": {"id": "password"}},
    {"type_text": {"text": "${PASSWORD}", "submit": true}},
    {"wait_for_element": {"text": "Welcome"}}
  ]
}
```

Every key of `mobdev.json` is optional. A run installs the build for the device's platform
(`iphone`, `simulator` or `android`) once, then plays `before_each` and the test's steps. A test
passes when every step does, so end it with a `wait_for_element` or `wait_for_text` that proves the
result; when the launched app crashes during a test, the test fails with the crash. `${NAME}` takes
a variable from the file, the environment or the run; a secret's value comes from the environment
or the run only and never appears in results. A test with `"platforms": ["android"]` is skipped on
iOS, and the other way round.

- **Tests** in the sidebar opens a project folder, runs its tests on a device and shows every
  result with its steps, the screenshot of a failure and the video of the run. The app keeps the
  newest 20 runs per project.
- Agents get the same: `list_tests` shows a project, `save_test` writes a test (and creates the
  project when there is none), `run_tests` runs the tests and returns every result with the first
  failure's screen, and `test_result` returns the newest results again. So an agent drives the
  app with the tools above until a path works, saves the calls that mattered as a test, runs it,
  and fixes it from the failing step.
- `Mobdev test` runs a project without the app, for scripts and CI, on booted simulators and
  Android devices:

  ```sh
  /Applications/Mobdev.app/Contents/MacOS/Mobdev test mobdev/ --device <udid> --artifacts test-artifacts
  ```

  It prints a line per test and exits 0 when every test passed, 1 when one failed and 2 when the
  tests could not start. `--artifacts` gets `results.json`, `junit.xml`, a video and, after a
  failure, a screenshot (and the files of a failed check, such as a screenshot diff) of every test
  in its own folder, the activity log and copied crash reports. A failed test also carries what the
  app printed during it and how the app ended. `--test <name>` runs one test (repeatable), `--var NAME=value` sets a variable,
  `--no-video` and `--wait` work as for `Mobdev flow`. iPhones need the running app: call
  `run_tests` over MCP or the HTTP API.

[`examples/tests`](../examples/tests) is a project for the example app, and
[`.github/workflows/flows.yml`](../.github/workflows/flows.yml) runs it on GitHub's `macos-26`
runners next to the flow; a job for your app looks like the one above with `Mobdev test` in place
of `Mobdev flow`, and `junit.xml` in the artifacts.

### Checks

Three tools judge the screen and fail their step when it does not pass, so a test can check how a
screen looks, not only what is on it:

```json
{
  "name": "Home looks right",
  "steps": [
    {"wait_for_element": {"id": "home.title"}},
    {"assert_screenshot": {"name": "home", "mask": ["home.clock"]}},
    {"accessibility_audit": {"fail_on": "error"}},
    {"assert_with_ai": {"question": "Is any text cut off or drawn over other text?", "expect": "no"}}
  ]
}
```

**`assert_screenshot`** compares the screen with a baseline picture (visual regression).

- `name` resolves to `baselines/<ios|android>/<width>x<height>/<name>.png`: in the project while
  its tests run (`run_tests`, the Tests window, `Mobdev test`), next to the flow file (`run_flow`
  with `path`, `Mobdev flow`), in the current folder for `Mobdev assert_screenshot` without the
  app, and otherwise in Mobdev's folder (`~/Library/Application Support/dev.mobdev.mac/baselines`).
  The size is the device's screen in pixels, so every model and orientation has its own baselines.
  `path` names a PNG instead; a full-resolution screenshot of the same shape works too.
- Without a baseline it waits until the screen is still, records it, passes and says so. **Commit
  the `baselines` folder** with your tests. A CI run without them records them and passes, so
  record them on a run you trust, check them in, and `update: true` replaces one after an
  intended change.
- The comparison works at screenshot size (long edge 1280 px). A pixel counts as changed when its
  color differs by more than about 10% (in YIQ, as pixelmatch measures it), it is not the baseline
  moved by up to a pixel (antialiasing, scaling), and at least three of its neighbors changed too
  (compression noise, one-pixel lines). The step fails when more than `threshold` of the compared
  pixels changed: by default 0.0005, 0.05%, about a 20×20 px square; 0 allows none. Changed text
  or a button moved by a few points fails; the same screen drawn again does not. Before it fails,
  it waits for the screen to settle and compares once more.
- The status bar (the top 7%) is left out unless `compare_status_bar` is true. `mask` leaves out
  more: `[x, y, width, height]` in screenshot pixels, or an element's id or label (recognized text
  where there is no UI tree), e.g. a clock, an avatar or a map.
- A failure writes `<name>-diff.png` (changed pixels red, tolerated differences yellow, masked
  areas blue, a box around each changed region) and `<name>-actual.png`: into the test's folder of
  the run, where `results.json` lists them as the test's `files`, or next to the baseline outside
  a test. The tool returns the diff and the changed regions; a later pass removes the files next
  to the baseline.

**`accessibility_audit`** checks the screen from the UI tree (simulators, Android, iPhones with
Mobdev Runner):

| Rule | Error | Warning |
|---|---|---|
| `missing_label` | Something to tap without a label and without text inside, such as an icon-only button | A field without a label or placeholder |
| `small_target` | Smaller than 24×24 pt or dp, WCAG 2.2's minimum | Smaller than 44×44 pt (iOS) or 48×48 dp (Android) |
| `low_contrast` | Text below 3:1 | Text below 4.5:1, WCAG AA for normal text |
| `duplicate_label` | | Different targets with the same label |
| `unclear_label` | A file name, such as `ic_close.png` | An identifier, such as `close_button`, `btnBack` or `chevron.right`, or just "button" |

- Contrast is measured in the screenshot inside each text and button: the most common color is the
  background, the most different color that still covers a little of the area is the text (or a
  button's icon). Disabled elements and busy backgrounds such as photos are left out.
- Sizes use the screen's scale: `wm density` on Android; on iOS 3 pixels per point for iPhones
  at least 1000 px wide, 2 for iPads and older iPhones.
- Issues come top to bottom, an element's together. `image: true` returns the screenshot with a
  numbered box per element, red when it has an error. `fail_on: "error"` (or `"warning"`) makes the
  call fail when there are such issues, which is what a test wants; `ignore` skips rules.
- Apple's and Google's standard controls do not always reach 4.5:1 or 44 pt (iOS's blue on white
  is about 3.5:1), so take warnings as advice and fail on errors.

**`assert_with_ai`** asks Apple Intelligence on the Mac a yes/no question about the screen and
fails when the answer is not `expect` (default `yes`) or the model is unsure; the reason comes
with the result. On macOS 27 the model looks at the screenshot; where it takes no images (macOS
26), it reads the screen's elements and says so. Nothing leaves the Mac. It needs a Mac with Apple
Intelligence turned on and its model downloaded, and says which is missing otherwise. A call takes
a few seconds. The on-device model is small: ask about one visible thing at a time, and prefer
`wait_for_element` for anything a tree can tell.

A recorded flow keeps the checks; `accessibility_audit` only with `fail_on`, since without it the
call only looks.

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
`/v1/uploads` receives builds for `install_app` (see [Install builds from anywhere](#install-builds-from-anywhere)).

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

### Install builds from anywhere

A cloud agent (Claude Code on the web, Codex cloud, Cursor background agents) or CI builds the app
in its own container, uploads the build to the Mac through the relay and installs it on a device
there with `install_app {"upload": "<id>"}`. The relay forwards the chunks like any other request
and keeps nothing; the build lands in `uploads/` of Mobdev's folder, readable only by you, and is
deleted 24 hours after its last use.

[`scripts/mobdev-upload.sh`](../scripts/mobdev-upload.sh) needs only a shell, curl and `sha256sum`
or `shasum`, so it runs in Linux containers without Mobdev:

```sh
curl -fsSLO https://raw.githubusercontent.com/niklas-schmidt-dev/mobdev/main/scripts/mobdev-upload.sh
export MOBDEV_URL=https://relay.mobdev.sh/h/<mac-name> MOBDEV_KEY=mdc_…
id=$(sh mobdev-upload.sh app/build/outputs/apk/debug/app-debug.apk)
curl -sS -H "Authorization: Bearer $MOBDEV_KEY" -H 'Content-Type: application/json' \
  -d "{\"upload\": \"$id\", \"device\": \"emulator-5554\"}" "$MOBDEV_URL/v1/tools/install_app"
```

An agent connected over MCP calls `install_app` with `{"upload": "<id>"}` instead of the `curl`.
On a Mac, `Mobdev upload <file> --url https://relay.mobdev.sh/h/<mac-name>` (the key in
`MOBDEV_KEY` or `--key`) does the same; without `--url` it sends the build to the Mobdev app on this
Mac. Both zip an `.app` folder first, send chunks of up to 8 MiB, send a failed chunk again from
where the Mac's copy ends, and print the upload's id (`--json`: the finished upload).

An iPhone takes an `.ipa` or an `.app` built for devices, a simulator an `.app` built for the
simulator, Android an `.apk`. An `.app` travels as a zip with the app at its top, as
`ditto -c -k --keepParent MyApp.app MyApp.zip` makes it. `install_app` checks an upload as it checks
a `path`. The protocol, on the relay and on the local API with the API token:

| Request | |
|---|---|
| `POST /v1/uploads` `{"name", "size", "sha256"}` | 201 `{"id", "chunk_size", "received", …}`. `name` ends in `.ipa`, `.apk` or `.zip`; `sha256` is optional |
| `PUT /v1/uploads/<id>?offset=<n>` with the bytes | At most `chunk_size` (8 MiB). `offset` must be what the Mac has, else 409 with `received` |
| `GET /v1/uploads/<id>` | `received` and `state` (`receiving`, `finishing`, `finished`), to resume |
| `POST /v1/uploads/<id>/finish` | Checks size and SHA-256 and unpacks a zip; `{"path", "kind", "sha256"}`. Safe to repeat |
| `DELETE /v1/uploads/<id>` | Removes the upload |

A zip is refused, before or right after unpacking, when it holds `../` or absolute paths, paths
through its own symlinks, symlinks pointing outside the app, anything but one `.app` at its top, or
more than 4 GB unpacked; setuid bits are dropped. Mobdev keeps at most 20 uploads and 4 GB; to make
room, those unused the longest go, never one used in the last 10 minutes. Each upload shows in
Mobdev's log (Console, subsystem `dev.mobdev.mac`), the install in the device's activity.

## Security and privacy

- The API binds only to 127.0.0.1, requires the bearer token, rejects browser requests (`Origin`)
  and foreign `Host` headers.
- The token and relay secret are files readable only by you (mode 0600) in
  `~/Library/Application Support/dev.mobdev.mac`. `MOBDEV_HOME` moves that directory.
- No telemetry, no account. Every agent action appears under **Activity** in the app.
- Agents act on your real phone with your accounts. Keep a human in the loop for anything that
  sends messages, pays or deletes.
- **Blocked apps** (Settings › Agents, or `MOBDEV_BLOCKED_APPS` with comma-separated names and
  bundle IDs for `Mobdev flow`, `test` and `call`): `open_app` and `launch_app` refuse them, in flows
  and tests too. A name also matches a bundle ID that contains it as a part. It prevents mistakes
  and is not a sandbox: an agent can still tap the app's icon.

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
  iOS asks before `open_url` opens an app's own URL scheme ("Open in …?"); `open_url` taps its
  Open button itself where there is a UI tree, so a flow or test needs no step for it.
- Android types text other than printable ASCII by pasting it, which replaces the clipboard and
  needs a field that takes Paste (Android 7 and later). Without scrcpy it types ASCII only. adb
  does not know app names, so `open_app` matches package names.
- scrcpy's server is pinned to 3.3.4, whose protocol Mobdev speaks; tested on an Android 16
  emulator. Phones whose maker blocks injected input over USB debugging (Xiaomi's "USB debugging
  (Security settings)") need that switch for scrcpy as for `input`. Touches the server cannot
  place, e.g. during a rotation, are dropped without an error.
- `ui_tree` reads the simulator through macOS's private accessibility translation; tested with
  Xcode 27 on macOS 27 and with Xcode 26.6 on GitHub's macOS 26 runners, where the example flow
  runs on every change. There the simulator can fall seconds behind typed text, and its app cannot
  be read meanwhile; `tap_element` and `wait_for_element` wait up to 15 s past their timeout for it.
- Recording does not capture the scroll wheel; drag to scroll while recording.
- A double tap (`double`) on Android takes two `input tap` calls through adb, which can be slower
  than an app's double-tap timeout.
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
.apk; run the emulator with `-read-only` to throw those changes away. `androidThroughScrcpy`
measures the stream while a swipe moves Settings (it expects more than 10 new pictures a second),
types "Grüße 👋" into Settings' search and reads it back from the UI tree, sets and reads the
clipboard, kills the server and waits for the next one, and checks that nothing is left on the
device. scrcpy's server is not in git: `scripts/build-app.sh` downloads the pinned release into
the app's Resources (checked against its SHA-256, with scrcpy's license next to it), and builds
run from `swift build` download it into `.build/scrcpy-server-v<version>` on first use. Its
protocol is tested byte for byte against scrcpy's own tests, the decoder with pictures this Mac
encodes, and the session against a fake server and fake adb.

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
with TapKit or MobAI. Android's screen and input go through the server of
[scrcpy](https://github.com/Genymobile/scrcpy) by Genymobile and Romain Vimont (Apache-2.0), which
the app ships unmodified with its license.
