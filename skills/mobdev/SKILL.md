---
name: mobdev
description: Drive a real iPhone, an iOS simulator or an Android emulator or phone from a Mac with Mobdev's MCP tools or its command line - look at the screen, tap, swipe, type, open apps, read on-screen text, set the device's state and record the screen. Use when the user wants an agent to use, test, check or automate something on their iPhone, a simulator or Android, see how an app behaves on a device, or when Mobdev tools such as observe, screenshot, tap_text or read_screen are available.
---

# Driving an iPhone with Mobdev

Mobdev gives you a real iPhone. The screen comes to the Mac over USB; taps and keys go to the phone
as a Bluetooth keyboard and pointer. Nothing is installed on the phone, so any app works, including
App Store apps.

## Start

1. Call `status`. Work only when it says `Ready.`
   - Screen missing: the phone is locked, asleep or unplugged. Ask the user to unlock it. You
     cannot enter the passcode.
   - Bluetooth not connected: ask the user to open Settings > Bluetooth on the iPhone, tap the Mac,
     and turn on Settings > Accessibility > Touch > AssistiveTouch with Snap to Item off.
   - `Pointer: snaps to items`: swipes would become taps. Ask the user to turn off Snap to Item in
     Settings > Accessibility > Touch > AssistiveTouch and keep Perform Touch Gestures on.
2. With several iPhones, call `list_devices` and pass `device` (id or name) to every tool.

## See the screen

Use the cheapest view that answers your question:

- `observe` lists what is on screen as numbered marks: the UI tree's elements where there is one,
  else the lines of recognized text, each with role, label, identifier and position. Orient with
  it first, then act with `tap_mark`. `contains` filters the list; `image: true` adds a screenshot
  with the numbered boxes drawn on it.
- `screenshot` when layout, icons, images or colors matter. `tap` and `swipe` coordinates are pixels
  of this image (long edge 1280 px, origin top-left).
- `read_screen` returns every visible line of text with its position, from text recognition.
- `ui_tree` returns every element with role, label, identifier and value, for when you need the
  identifiers, e.g. to write a test. Simulators, Android and iPhones with the UI tree on.
- Actions return a screenshot by default. Pass `"screenshot": false` when you will call `observe`
  next anyway.

## Act

| Goal | Tool |
|---|---|
| Press something `observe` listed | `tap_mark` with its number. Marks are where things were at that `observe`; after the screen changed, `observe` again |
| Press a labelled button or row | `tap_text` with its label. If it appears more than once, the error lists matches; pass `index`. |
| Press an icon without text | `observe` (it lists icon buttons from the UI tree), or `screenshot` and `tap` its center |
| Open an app | `open_app` with its name (Spotlight). For your own builds, `launch_app` |
| Enter text | `tap` the field, then `type_text`; `submit: true` presses Return |
| Find a row further down | `scroll_until_visible` with its `text` or `id`; it stops at the end of the list |
| Scroll a list down | `swipe` from a larger y to a smaller y, or `scroll` with `direction: "down"` |
| Scroll sideways | `scroll` with `direction: "right"` or `"left"`, or `swipe` horizontally |
| Go back | `tap_text` the back button's label, or `tap` the chevron at the top left |
| Home screen | `home` |
| Wait for something | `wait_for_text` or `wait_for_element` (or `gone: true`) for a particular thing; `wait_for_idle` when the screen only has to settle after an animation or loading. Never sleep a fixed time |
| Keyboard shortcut | `press_key`, e.g. `{"key": "space", "modifiers": ["cmd"]}` for Spotlight |

## Check every step

After each action, confirm the screen changed as intended: look at the returned screenshot or call
`observe` or `find_text`. If it did not, re-read the screen before trying again. A sheet, alert or
keyboard may be in the way, or the tap hit a neighbour. Do not repeat the same tap blindly.

## Common problems

- `tap_text` says the text is not visible: OCR may split or merge labels. `read_screen` shows the
  exact text; pass a shorter part of it.
- A text tool says text recognition failed in macOS: look with `screenshot` and tap by coordinates.
  Where there is a UI tree, the text tools read it instead and say so.
- Typed text comes out wrong (y and z swapped, wrong symbols): the keyboard layout in Mobdev does not
  match Settings > General > Keyboard > Hardware Keyboard on the iPhone. Tell the user. Emoji type
  only with the UI tree on (below).
- Taps do nothing: AssistiveTouch is off, or the phone locked itself. Suggest Auto-Lock: Never while
  agents work.
- `swipe` fails because the pointer snaps to items, or a swipe opened something instead of
  scrolling: Snap to Item is on in AssistiveTouch. Ask the user to turn it off, then swipe again.
- `wait_for_idle` says the screen kept changing: a video, an animation or a spinner never stops.
  Wait for the element or text you need instead.

## Simulators and Android

`list_devices` also lists booted iOS simulators and Android emulators and phones. Pass their id or
name as `device`; without it Mobdev picks the connected iPhone when there is one. They need no
setup, and the same tools work, with these differences:

- Simulators take keys in their own keyboard layout; Mobdev handles that.
- On Android, `press_key` with `escape` is Back, `type_text` types ASCII only, and `open_app` matches
  package names ("Settings" opens com.android.settings; `list_apps` with `all: true` lists them).
- An app reopens where it was left. `stop_app` first when you need its first screen.
- `ui_tree` lists the elements on screen with role, label, accessibility identifier and position.
  Prefer `observe` and `tap_mark`, or `tap_element` (by `id` or `text`) and `wait_for_element`, to
  OCR here: they find icon-only buttons and fields, and `tap_element` waits up to 5 s for its element.
- On an iPhone they need the UI tree turned on in Mobdev (Developer Mode on the iPhone, Xcode on the
  Mac): Mobdev then runs a small UI test there, Mobdev Runner. Without it `ui_tree` says how to turn
  it on, and `observe` lists recognized text instead; do not ask the user to set it up unless the
  task needs it.

## Set the device's state

Put the device in the state a scenario needs with a tool instead of tapping through Settings:

| Need | Tool |
|---|---|
| A place, or a route the device follows | `set_location` (`clear: true` stops it) |
| A permission granted, revoked or asked again | `set_permission` (simulators and Android) |
| A push notification | `send_push` (simulators; on Android a plain notification the app does not receive) |
| Dark mode, text size, Increase Contrast, Reduce Motion | `set_appearance` |
| Another language and region | `set_language`, then `launch_app` again; on Android pass `bundle_id` |
| A clean status bar for screenshots | `set_status_bar` with `preset: "screenshot"`; `"clear"` undoes it |
| A Face ID, Touch ID or fingerprint prompt answered | `biometrics` with `match` or `fail` |
| The app as if just installed | `reset_app` (simulators and Android; on an iPhone `uninstall_app` and `install_app`) |
| Text to paste, or what the app copied | `clipboard` (not Android) |
| Landscape | `set_orientation` |

Simulators and Android take all of these; iPhones some, with Developer Mode and Xcode 27. Each
tool's error says when a device cannot do it. They change the whole device, so on the user's
iPhone ask first, and put back what you changed when you are done.

## Record evidence

`start_recording` records the screen to an .mp4 on the Mac that runs Mobdev, in Mobdev's
recordings folder unless you pass `path`; `stop_recording` ends it and says where the file is.
Record a bug you reproduce or the proof that a fix works, and name the file in your report.
A recording stops by itself after 30 minutes.

## From a terminal

Agents without MCP, and scripts, call the same tools with the `Mobdev` command, which is
`/Applications/Mobdev.app/Contents/MacOS/Mobdev` (`mobdev` when installed with Homebrew):

```sh
Mobdev tools                                     # every tool, one line each
Mobdev observe                                   # Mobdev <tool> key=value …
Mobdev tap_mark mark=3
Mobdev type_text text="hello world" submit=true
Mobdev call launch_app '{"bundle_id": "com.example.MyApp", "arguments": ["-UITestMode", "YES"]}'
Mobdev screenshot --image screen.jpg --device "iPhone 17"
```

Values are JSON where they parse as JSON (numbers, `true`, arrays) and text otherwise. `--json`
prints the whole result and `--image` saves the screenshot a tool returns (a JPEG). The exit code
is 0 when the tool succeeded, 1 when it reported an error and 2 when it could not run. Calls go
through the running app, so they reach iPhones too. Without the app they run on a booted simulator
or Android device, where `tap_mark` and the recording tools are not available, since every call is
a process of its own.

## Flows

`run_flow` replays a saved list of tool calls (`path` to a JSON file, or `steps` inline) on one
device and stops at the first failing step, saying which. Users record flows in the app with
**Record**. To turn a session you just drove into a flow, write the calls that mattered as steps,
for example `{"steps": [{"tap_element": {"id": "login"}}, {"type_text": {"text": "hi"}}, "home"]}`,
preferring `tap_element` and `wait_for_element` over coordinates so it survives layout changes.
Never save `observe` or `tap_mark`: a mark's number is only valid for one look at the screen, so
write `tap_element` with the mark's identifier or label. Pass `video` (an absolute .mp4 path on the
Mac) to keep a recording of the run; it ends on the screen where the flow stopped.
`Mobdev flow <file> --device <id> --artifacts <dir>` runs one without the app, in CI, and writes
`run.mp4` and `summary.md` to the directory.

## Tests

A project folder holds an app's tests: `tests/*.json`, each a flow with a `name`, a `description`
and the `platforms` it runs on, and `mobdev.json` with the app's `bundle_id`, `builds` per
platform, `before_each` steps (usually `launch_app` with `restart: true`), `variables` and
`secrets`. `list_tests` shows a project with its newest results, `save_test` writes a test and
creates the project when there is none, `run_tests` runs the tests on a device and returns every
result with the first failure's screen, and `test_result` returns the newest results again.

To add a test, drive the app with the tools above until the path works, then save the calls that
mattered: `tap_element` and `wait_for_element` over coordinates, `${NAME}` for data such as an
account from `mobdev.json`, and a final wait that proves the result. When a test fails, read the
failing step and the screen, then fix the test or report the bug. `Mobdev test <folder> --device
<id> --artifacts <dir>` runs a project in CI and writes `junit.xml` and `summary.md`; the GitHub
Action `niklas-schmidt-dev/mobdev/actions/test` does that on a simulator and puts the results in
the job summary.

## Safety

This is the user's own phone, signed in to their accounts. Ask before anything that sends a
message, posts, pays, subscribes, deletes, changes settings or accepts terms. Do not open unrelated
private content. Never try to get past the lock screen.

The user can block apps for agents, such as a banking app: `open_app` and `launch_app` then refuse
them. Respect that. Do not reach a blocked app another way, through its home screen icon, Spotlight
or a link; tell the user what you needed it for.

## Building your own app

With Developer Mode on the iPhone and Xcode on the Mac, Mobdev also installs and launches builds and
reads their logs and crash reports: `list_apps`, `install_app`, `launch_app`, `stop_app`,
`open_url`, `logs`, `crash_reports`. Use the `mobdev-dev-loop` skill for that workflow,
`mobdev-bug-repro` to reproduce a reported bug, and `mobdev-store-screenshots` for App Store and
Google Play screenshots.
