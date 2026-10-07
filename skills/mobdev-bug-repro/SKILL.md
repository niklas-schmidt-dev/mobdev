---
name: mobdev-bug-repro
description: Reproduce a reported bug of an iOS or Android app on a real iPhone, a simulator or an Android device with Mobdev - set up the device as in the report, drive the app, record a video, read logs and crash reports, cut the steps down to a minimal reproduction, save it as a test and report with evidence. Use for "reproduce this bug", "can you repro", "check this issue on a device", a bug report, crash report or support ticket to confirm, or before fixing a bug.
---

# Reproduce a bug on a device

Turn a bug report into a reproduction anyone can run again: the fewest steps that show the bug on
a known device, a video of it, the logs and crash report behind it, and a test that fails until
the bug is fixed. Read the `mobdev` skill first for driving the device, and `mobdev-dev-loop` for
building and installing your own app.

## Ground rules

- Ask before anything that pays, subscribes, sends messages or email to real people, posts, or
  deletes real data, even when the report says that is how the bug happens. Use a test account if
  the user gives you one; never the user's own accounts without asking.
- Leave the user's iPhone as you found it: undo device state you changed. Prefer a simulator when
  the bug does not need real hardware.
- Do not guess. When the report lacks something that decides the outcome (app version, account
  type, the exact screen), ask once, listing everything you need.

## 1. Read the report

Write down, before touching a device:

- **Expected and actual:** one sentence each. The bug is the difference.
- **Steps** as reported, numbered, and what the user saw at the end.
- **Environment:** app version or build, device, iOS or Android version, language and region, dark
  mode or text size, signed in or not, network, location, permissions granted.
- **Evidence** attached: screenshots, a video, a crash log, a timestamp.

## 2. Set up the device

1. Pick the device: a simulator or emulator matching the reported system version when the bug is in
   the app's own logic; the user's iPhone (ask first) for hardware, real accounts or the App Store
   build. `list_devices` shows what is connected.
2. Install the reported build, or the closest one (`install_app`, see `mobdev-dev-loop`), or
   `open_app` for an App Store app.
3. Recreate the reported state with the device state tools, so the reproduction does not depend on
   tapping through Settings: `reset_app` for a fresh install, `set_permission`, `set_language` and
   `set_appearance` (dark mode, `text_size`), `set_location`, `set_orientation`, `clipboard` for
   pasted content, `send_push` when a notification starts it, `biometrics` for Face ID prompts.
   Note every state you set: it belongs to the reproduction.

## 3. Reproduce

1. `start_recording` with an absolute `path` such as `bugs/<id>/repro.mp4`.
2. `launch_app` your build so its output is captured (or `open_app`), and keep the `cursor` that
   `logs` returns.
3. Follow the reported steps exactly. Orient with `observe`, act with `tap_mark` or `tap_element`,
   find rows with `scroll_until_visible`, and wait with `wait_for_element`, `wait_for_text` or
   `wait_for_idle`, never fixed sleeps, so timing is not mistaken for the bug.
4. When the bug shows, save a screenshot (full-size PNG through the HTTP API as in the
   `mobdev-smoke-test` skill), then `stop_recording`.
5. Read `logs` with the cursor for errors and the lines just before the bug. If the app crashed,
   `crash_reports` with `app`, then with `name` for the exception and the crashed thread;
   `mobdev-dev-loop` shows how to symbolicate your own frames.
6. Run it twice more from the same state. Record how often it happened, e.g. 3 of 3.

If it does not reproduce, vary one thing at a time toward the report: system version, a fresh
install versus an upgrade, language, account state, slower network, a different device size. Stop
after a reasonable number of tries and report what you tried.

## 4. Minimize

Remove steps and state one at a time and run again; keep only what the bug needs. The result is
the minimal reproduction: the state from step 2, a handful of steps, and the moment it fails. Try
it once on another platform or system version when that tells the user how far the bug reaches.

## 5. Save it as a test

Offer to save the minimal reproduction with `save_test` in the app's project folder (ask where;
`mobdev/` in the repository is a good default). Write it as the expected behaviour: the steps,
then a `wait_for_element` or `wait_for_text` for what should happen, so the test fails while the
bug exists and passes once it is fixed. Name the bug or issue in its `description`. Use
`tap_element` and `wait_for_element` rather than coordinates or `tap_mark`, and put state the tools
can set in the steps (for example `set_permission` before `launch_app`). Run it with `run_tests`
once to confirm it fails the way the bug does.

## 6. Report

Write `bugs/<id>/report.md` (or reply in the issue if the user wants that):

- **Summary:** one line, e.g. "Checkout total stays at 0 after removing the last coupon".
- **Environment:** device, system version, app version or build, and the state you set.
- **Steps to reproduce:** the minimal steps, numbered. **Expected** and **actual**.
- **Reproducibility:** e.g. 3 of 3 on iPhone 17 simulator, iOS 27.0; not on Android.
- **Evidence:** the video and screenshot paths, the relevant log lines, the crash summary.
- **The test** you saved, and its failing step.
- **Not reproduced or not tried:** what you could not check and why, such as purchases or flows
  behind real accounts.

When you could not reproduce it, say so plainly with what you tried, and list what you need from
the reporter.
