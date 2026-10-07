---
name: mobdev-dev-loop
description: Build an iOS or Android app, install it on a real iPhone, an iOS simulator or an Android emulator or phone, run it, drive its UI and read its logs and crash reports with Mobdev. Use when developing or debugging a mobile app on a device - "run it on my iPhone", "try it in the simulator", "test it on Android", "why does it crash", "check the logs", deep links, push notifications, permissions, location, or verifying a fix end to end.
---

# Build, run and debug on a real iPhone

Mobdev's developer tools close the loop: you build with `xcodebuild`, Mobdev installs the build,
launches it with its output captured, you drive the UI with the usual Mobdev tools, then read logs
and crash reports. Read the `mobdev` skill for driving the UI.

## Requirements

- Xcode on the Mac, Developer Mode on the iPhone (Settings > Privacy & Security > Developer Mode).
  `list_apps` is a quick check; its error says what is missing.
- The project signs for devices: a development team with automatic signing. Pass
  `-allowProvisioningUpdates` so Xcode registers the iPhone and creates the profile.
- Simulators and Android devices need neither. Pick the target with `device` (from
  `list_devices`) and build for it, see "Simulators and Android" below.

## Loop

1. **Build for a device.** A Simulator build cannot be installed; `install_app` refuses it.

   ```sh
   xcodebuild -scheme MyApp -configuration Debug -destination 'generic/platform=iOS' \
     -derivedDataPath build/device -allowProvisioningUpdates build
   ```

   Use `-workspace MyApp.xcworkspace` or `-project MyApp.xcodeproj` when needed. The app is at
   `build/device/Build/Products/Debug-iphoneos/MyApp.app`. Its bundle ID:
   `/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' <app>/Info.plist`.

2. **Install:** `install_app` with the absolute path of the `.app` (or an `.ipa`). A newer build
   replaces the old one and keeps its data. When you build somewhere else than the Mac that runs
   Mobdev (a cloud agent, a CI job) and reach it through a relay, upload the build first with
   `scripts/mobdev-upload.sh` (curl only) or `Mobdev upload`, then `install_app` with `upload` set
   to the id it prints.

3. **Launch:** `launch_app` with `bundle_id`. It restarts a running copy and captures everything the
   app prints: `print`, `NSLog`, `Logger` and `os_log`. Pass `arguments` (for example
   `["-UITestMode", "YES"]`) and `environment` when the app reads them.

4. **Drive and check the UI** with `observe` and `tap_mark`, `tap_element`, `type_text` and
   `scroll_until_visible`. Wait with `wait_for_element` or `wait_for_text` for what should appear,
   or `wait_for_idle` for the screen to settle, never a fixed sleep. Use `open_url` for deep links
   (`myapp://orders/42`) and universal links.

5. **Read the output:** `logs` with `bundle_id`. Keep the returned `cursor` and pass it as `after`
   next time to see only new lines. `contains` filters. Temporary markers such as
   `print("CHECK cart total", total)` plus `contains: "CHECK"` make assertions easy.

6. **Change code, rebuild, `install_app`, `launch_app`.** Repeat until the behaviour is right.

`stop_app` stops the app. `uninstall_app` removes it with its data, which gives a true first launch
on the next install. It only removes apps installed for development. On simulators and Android,
`reset_app` deletes the data without reinstalling.

## Set up the scenario

Put the device in the state the feature needs before you launch, instead of tapping through
Settings or waiting for a real event. Simulators and Android take all of these; iPhones with
Developer Mode and Xcode 27 some (the `mobdev` skill lists them):

- First launch or onboarding: `reset_app`, then `launch_app`.
- Permission prompts: `set_permission` with `reset` so the app asks again, or `grant` to skip the
  prompt, or `revoke` to test the denied path.
- Push handling: `send_push` with `title`, `body` and `data` (or a whole `payload`) on a simulator,
  as if it came from APNs.
- Location features: `set_location` with a coordinate, or a `route` to move along.
- Localization and accessibility: `set_language` (then `launch_app` again), `set_appearance` with
  `dark`, `text_size`, `increase_contrast` or `reduce_motion`, `set_orientation`.
- Face ID or fingerprint: `biometrics` with `match` or `fail` while the prompt shows.
- Paste flows: `clipboard` with `text`; `clipboard` alone reads what the app copied.

## Simulators and Android

The loop is the same; only the build differs.

- **iOS Simulator:** build for the simulator and install the `.app` from `Debug-iphonesimulator`.
  `install_app` refuses device builds on a simulator and simulator builds on an iPhone.

  ```sh
  xcodebuild -scheme MyApp -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath build/simulator build
  ```

  Crash reports come from the Mac, so `crash_reports` works right away.
- **Android:** build a debug APK, e.g. `./gradlew assembleDebug`, and install
  `app/build/outputs/apk/debug/app-debug.apk`. `bundle_id` is the package name (`applicationId`).
  `logs` follows the app's logcat lines; `crash_reports` reads the crash buffer and shows the Java
  exception and stack, or the signal of a native crash. `launch_app` ignores `arguments` and
  `environment`.

## When it crashes

1. `logs` shows how the app ended, e.g. `crashed: signal 5 (SIGTRAP)`. Lines just before it often
   name the cause, such as `Fatal error: Unexpectedly found nil`.
2. `crash_reports` with `app` (name or bundle ID) lists reports, newest first.
3. `crash_reports` with `name` returns the exception, the reason and the crashed thread, and saves
   the full `.ips` on the Mac.
4. Frames of your own code may come without symbols, as
   `MyApp.debug.dylib  0x0000000104a8f2c4  (MyApp.debug.dylib + 12996, loaded at 0x104a8c000)`.
   Debug builds from Xcode 16 on keep the app's code in `MyApp.debug.dylib`; other builds in
   `MyApp`. Resolve the address with that file from the same build (or its dSYM) and the load
   address:

   ```sh
   atos -arch arm64 -o build/device/Build/Products/Debug-iphoneos/MyApp.app/MyApp.debug.dylib \
     -l 0x104a8c000 0x0000000104a8f2c4
   ```

   Then read that source line, fix, and run the loop again.

## Good habits

- Verify on the device, not only by compiling: a passing build is not a working feature.
- Show it: `start_recording` before the steps that prove a fix and `stop_recording` after, and give
  the user the video's path.
- Check what the app sends: `start_network_capture` with the `bundle_id`, use the app, then
  `network_log` (keep its `cursor` for `after`) and `stop_network_capture`. iOS lists method, host,
  status, size and time but hides paths; Android shows plain HTTP in full and HTTPS as host and bytes.
  Always stop it on Android, which otherwise keeps the proxy until Mobdev quits.
- Report what you checked on the phone and what you could not, such as push notifications on an
  iPhone (a simulator takes `send_push`) or purchases that need real accounts.
- Once a path works, offer to keep it as a test with `save_test` (see the `mobdev` skill), so the
  next change is checked without an agent.
- Leave the phone as you found it: undo state you changed (`set_status_bar` with `preset: "clear"`,
  `set_location` with `clear: true`, the appearance and language), and uninstall test builds only
  if the user wants that.
