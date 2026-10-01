---
name: mobdev
description: Drive a real iPhone, an iOS simulator or an Android emulator or phone from a Mac with Mobdev's MCP tools - look at the screen, tap, swipe, type, open apps and read on-screen text. Use when the user wants an agent to use, test, check or automate something on their iPhone, a simulator or Android, see how an app behaves on a device, or when Mobdev tools such as screenshot, tap_text or read_screen are available.
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

- `read_screen` returns every visible line of text with its position. It is cheaper than a
  screenshot, so orient with it first.
- `screenshot` when layout, icons, images or colors matter. `tap` and `swipe` coordinates are pixels
  of this image (long edge 1280 px, origin top-left).
- Actions return a screenshot by default. Pass `"screenshot": false` when you will call
  `read_screen` next anyway.

## Act

| Goal | Tool |
|---|---|
| Press a labelled button or row | `tap_text` with its label. If it appears more than once, the error lists matches; pass `index`. |
| Press an icon without text | `screenshot`, then `tap` its center |
| Open an app | `open_app` with its name (Spotlight). For your own builds, `launch_app` |
| Enter text | `tap` the field, then `type_text`; `submit: true` presses Return |
| Scroll a list down | `swipe` from a larger y to a smaller y, or `scroll` with `direction: "down"` |
| Go back | `tap_text` the back button's label, or `tap` the chevron at the top left |
| Home screen | `home` |
| Wait for something | `wait_for_text` (or `gone: true`) instead of sleeping |
| Keyboard shortcut | `press_key`, e.g. `{"key": "space", "modifiers": ["cmd"]}` for Spotlight |

## Check every step

After each action, confirm the screen changed as intended: look at the returned screenshot or call
`find_text`. If it did not, re-read the screen before trying again. A sheet, alert or keyboard may be
in the way, or the tap hit a neighbour. Do not repeat the same tap blindly.

## Common problems

- `tap_text` says the text is not visible: OCR may split or merge labels. `read_screen` shows the
  exact text; pass a shorter part of it.
- Typed text comes out wrong (y and z swapped, wrong symbols): the keyboard layout in Mobdev does not
  match Settings > General > Keyboard > Hardware Keyboard on the iPhone. Tell the user. Emoji type
  only with the UI tree on (below).
- Taps do nothing: AssistiveTouch is off, or the phone locked itself. Suggest Auto-Lock: Never while
  agents work.
- `swipe` fails because the pointer snaps to items, or a swipe opened something instead of
  scrolling: Snap to Item is on in AssistiveTouch. Ask the user to turn it off, then swipe again.

## Simulators and Android

`list_devices` also lists booted iOS simulators and Android emulators and phones. Pass their id or
name as `device`; without it Mobdev picks the connected iPhone when there is one. They need no
setup, and the same tools work, with these differences:

- Simulators take keys in their own keyboard layout; Mobdev handles that.
- On Android, `press_key` with `escape` is Back, `type_text` types ASCII only, and `open_app` matches
  package names ("Settings" opens com.android.settings; `list_apps` with `all: true` lists them).
- An app reopens where it was left. `stop_app` first when you need its first screen.
- `ui_tree` lists the elements on screen with role, label, accessibility identifier and position.
  Prefer `tap_element` (by `id` or `text`) and `wait_for_element` to OCR here: they find icon-only
  buttons and fields, and `tap_element` waits up to 5 s for its element.
- On an iPhone they need the UI tree turned on in Mobdev (Developer Mode on the iPhone, Xcode on the
  Mac): Mobdev then runs a small UI test there, Mobdev Runner. Without it `ui_tree` says how to turn
  it on; use `tap_text` meanwhile, and do not ask the user to set it up unless the task needs it.

## Flows

`run_flow` replays a saved list of tool calls (`path` to a JSON file, or `steps` inline) on one
device and stops at the first failing step, saying which. Users record flows in the app with
**Record**. To turn a session you just drove into a flow, write the calls that mattered as steps,
for example `{"steps": [{"tap_element": {"id": "login"}}, {"type_text": {"text": "hi"}}, "home"]}`,
preferring `tap_element` and `wait_for_element` over coordinates so it survives layout changes.
Pass `video` (an absolute .mp4 path on the Mac) to keep a recording of the run; it ends on the
screen where the flow stopped. `Mobdev flow <file> --device <id> --artifacts <dir>` runs one
without the app, in CI, and writes `run.mp4` to the directory.

## Safety

This is the user's own phone, signed in to their accounts. Ask before anything that sends a
message, posts, pays, subscribes, deletes, changes settings or accepts terms. Do not open unrelated
private content. Never try to get past the lock screen.

## Building your own app

With Developer Mode on the iPhone and Xcode on the Mac, Mobdev also installs and launches builds and
reads their logs and crash reports: `list_apps`, `install_app`, `launch_app`, `stop_app`,
`open_url`, `logs`, `crash_reports`. Use the `mobdev-dev-loop` skill for that workflow.
