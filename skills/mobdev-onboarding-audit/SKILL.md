---
name: mobdev-onboarding-audit
description: Audit a mobile app's first-run onboarding on a real iPhone with Mobdev - walk every screen from first launch to first value, capture each one, and report friction with concrete fixes. Use for "onboarding audit", "first-run experience", "new user flow", "FTUE review", or before changing an app's onboarding.
---

# Onboarding audit on a real iPhone

Walk the app exactly as a new user would, from first launch until they get the first real value,
and report where people will drop off. Read the `mobdev` skill first for driving the phone.

## 1. Get a true first launch

A first launch needs a fresh install, and deleting an app removes its data. Ask the user first.

- Your own app with Developer Mode: once the user agrees, `uninstall_app`, `install_app` the build,
  then `launch_app`.
- An App Store app: ask the user to delete and reinstall it, or to confirm you may do it through the
  App Store.
- Note the device, iOS version and app version.

## 2. Walk and record every screen

For each screen, save a screenshot (see the `mobdev-smoke-test` skill for saving full-size PNGs)
and `read_screen` its text, then note:

- **Purpose:** what the screen asks or tells, in one line.
- **Effort:** taps and fields it needs, and whether it can be skipped.
- **Asks:** permission prompts (notifications, tracking, location, contacts), sign-up walls,
  paywalls, and whether the value was explained before the ask.
- **Clarity:** unclear copy, jargon, tiny or crowded tap targets, missing back or skip.

Take the path most new users would take. Stop before creating an account with real personal data,
starting a trial or paying, unless the user provides a test account or explicitly allows it. Record
that you stopped there.

## 3. Report

Write a report (Markdown or HTML) with:

- The flow at a glance: screens in order with thumbnails, and taps until the first value.
- Per screen: the notes above and a score from 1 (blocks people) to 5 (effortless).
- The top 3 to 5 problems, each with the evidence and a concrete fix, such as "ask for
  notifications after the first saved item, not on screen 2".
- What you could not see, for example flows behind real sign-up or payment.
