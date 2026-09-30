---
name: mobdev
description: Drive a real iPhone connected to a Mac with Mobdev's MCP tools - look at the screen, tap, swipe, type, open apps and read on-screen text. Use when the user wants an agent to use, test, check or automate something on their iPhone, see how an app behaves on a real device, or when Mobdev tools such as screenshot, tap_text or read_screen are available.
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
  match Settings > General > Keyboard > Hardware Keyboard on the iPhone. Tell the user. Emoji cannot
  be typed.
- Taps do nothing: AssistiveTouch is off, or the phone locked itself. Suggest Auto-Lock: Never while
  agents work.
- `swipe` fails because the pointer snaps to items, or a swipe opened something instead of
  scrolling: Snap to Item is on in AssistiveTouch. Ask the user to turn it off, then swipe again.

## Safety

This is the user's own phone, signed in to their accounts. Ask before anything that sends a
message, posts, pays, subscribes, deletes, changes settings or accepts terms. Do not open unrelated
private content. Never try to get past the lock screen.

## Building your own app

With Developer Mode on the iPhone and Xcode on the Mac, Mobdev also installs and launches builds and
reads their logs and crash reports: `list_apps`, `install_app`, `launch_app`, `stop_app`,
`open_url`, `logs`, `crash_reports`. Use the `mobdev-dev-loop` skill for that workflow.
