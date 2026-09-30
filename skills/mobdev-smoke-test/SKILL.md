---
name: mobdev-smoke-test
description: Smoke-test a mobile app on a real iPhone, an iOS simulator or an Android device with Mobdev - walk its critical paths, capture evidence at each step, catch crashes and errors, and write a pass/fail report. Use for "smoke test", "quick test on device", "does the app still work", "sanity check before release" or checking a build after a change.
---

# Smoke test on a real iPhone

A smoke test answers one question fast: do the app's most important paths still work on a real
device? It is not an exhaustive test. Read the `mobdev` skill first for driving the phone.

## 1. Plan

- Pick 3 to 6 critical paths: launch, sign-in (only with a test account the user provides), the
  core action, navigation between main tabs, settings. Ask the user when unsure what matters.
- For each path write the expected result in one sentence before you start, such as "the cart
  shows 2 items and the total".
- Skip anything that pays, sends messages to real people or deletes real data unless the user
  explicitly allows it.

## 2. Prepare

- `status` must say Ready.
- Your own app with Developer Mode: `install_app` the build, then `launch_app` so `logs` captures
  its output. Any other app: `open_app` by name.
- Make a folder for evidence, e.g. `smoke/<date>/`. On the Mac that runs Mobdev, save full-size
  screenshots with:

  ```sh
  TOKEN=$(cat ~/Library/Application\ Support/dev.mobdev.mac/token)
  curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:4686/v1/screenshot?format=png" -o smoke/01-launch.png
  ```

  Add `&device=<id>` when several devices are connected. The same test can run on a simulator or
  an Android emulator by passing its id as `device`, which is a cheap way to cover more screen
  sizes and both platforms.

## 3. Run each path

For every step: act, wait for the expected screen with `wait_for_text`, confirm with `read_screen`
or `screenshot`, save a screenshot, and note what you saw. A step fails when the expected text or
screen does not appear within a reasonable wait, an error message shows, the app leaves the
foreground, or `logs` reports that it exited or crashed.

After each path, check `logs` with the last `cursor` for errors and warnings. When the app crashed,
call `crash_reports` for it and read the newest report. Relaunch and continue with the next path.

## 4. Report

Write `smoke/<date>/report.md` (or HTML if the user prefers):

- Build, device, iOS version (`list_devices`), date.
- A table: path, expected, actual, result (pass, fail or blocked), evidence file.
- For each failure: the steps to reproduce, the screenshot, relevant log lines and the crash
  summary.
- What you did not test and why.

End with a one-line verdict: ready or not, and the most important failure.
