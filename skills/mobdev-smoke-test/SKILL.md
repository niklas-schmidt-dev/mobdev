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
- Start from a known state. On simulators and Android: `reset_app` for a fresh start, and
  `set_permission` with `grant` for what the paths need, so system prompts do not get in the way
  (or `reset` when the prompt is part of a path).
- Make a folder for evidence, e.g. `smoke/<date>/`, and save full-size screenshots into it with
  `save_screenshot` and an absolute `path` such as `<folder>/smoke/<date>/01-launch` (it adds
  `.png`). A relative `path` goes into the project's versioned `screenshots/` instead, which is for
  pictures meant to be kept, such as store screenshots. `Mobdev screenshot --image
  smoke/01-launch.jpg` saves the smaller JPEG the tool returns. The same test can run on a
  simulator or an Android emulator by passing its id as `device`, which is a cheap way to cover
  more screen sizes and both platforms.
- `start_recording` records the whole run, into the project's `output/recordings` or to an
  absolute `path` such as `smoke/<date>/run.mp4`; `stop_recording` at the end says where it is.
  The video shows what happened between screenshots.

## 3. Run each path

For every step: act, wait for the expected screen with `wait_for_element` or `wait_for_text`
(`wait_for_idle` when the screen only has to settle), confirm with `observe` or `screenshot`, save
a screenshot, and note what you saw. `scroll_until_visible` finds rows further down a list. A step
fails when the expected text or screen does not appear within a reasonable wait, an error message
shows, the app leaves the foreground, or `logs` reports that it exited or crashed.

After each path, check `logs` with the last `cursor` for errors and warnings. When the app crashed,
call `crash_reports` for it and read the newest report. Relaunch and continue with the next path.

On simulators, Android and iPhones with the UI tree on, act with `tap_element` (or `observe` and
`tap_mark`) and check with `wait_for_element` where the app has accessibility identifiers. When a path passes, offer to save
it as a test with `save_test` into the app's project (`list_projects` says which one your calls
use; without one, ask before `create_project` with `mobdev/` in the repository, see the `mobdev`
skill), so the next smoke test runs it with `run_tests`, and CI with `Mobdev test`, without an
agent.

## 4. Report

Write `smoke/<date>/report.md` (or HTML if the user prefers):

- Build, device, iOS version (`list_devices`), date.
- A table: path, expected, actual, result (pass, fail or blocked), evidence file.
- For each failure: the steps to reproduce, the screenshot, the video and about when in it the
  failure shows, relevant log lines and the crash summary.
- What you did not test and why.

End with a one-line verdict: ready or not, and the most important failure.
