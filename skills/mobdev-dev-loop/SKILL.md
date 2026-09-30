---
name: mobdev-dev-loop
description: Build an iOS or Android app, install it on a real iPhone, an iOS simulator or an Android emulator or phone, run it, drive its UI and read its logs and crash reports with Mobdev. Use when developing or debugging a mobile app on a device - "run it on my iPhone", "try it in the simulator", "test it on Android", "why does it crash", "check the logs", deep links, or verifying a fix end to end.
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
   replaces the old one and keeps its data.

3. **Launch:** `launch_app` with `bundle_id`. It restarts a running copy and captures everything the
   app prints: `print`, `NSLog`, `Logger` and `os_log`. Pass `arguments` (for example
   `["-UITestMode", "YES"]`) and `environment` when the app reads them.

4. **Drive and check the UI** with `read_screen`, `tap_text`, `type_text`, `screenshot` and
   `wait_for_text`. Use `open_url` for deep links (`myapp://orders/42`) and universal links.

5. **Read the output:** `logs` with `bundle_id`. Keep the returned `cursor` and pass it as `after`
   next time to see only new lines. `contains` filters. Temporary markers such as
   `print("CHECK cart total", total)` plus `contains: "CHECK"` make assertions easy.

6. **Change code, rebuild, `install_app`, `launch_app`.** Repeat until the behaviour is right.

`stop_app` stops the app. `uninstall_app` removes it with its data, which gives a true first launch
on the next install. It only removes apps installed for development.

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
- Report what you checked on the phone and what you could not, such as push notifications or
  purchases that need real accounts.
- Leave the phone as you found it. Uninstall test builds only if the user wants that.
