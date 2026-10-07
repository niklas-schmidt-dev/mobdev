---
name: mobdev-store-screenshots
description: Make App Store and Google Play screenshots of your own app on iOS simulators and Android emulators with Mobdev - a clean status bar, light or dark appearance, every locale, every required device size, the screen settled before each capture, PNGs named by locale and device. Use for "App Store screenshots", "store screenshots", "localized screenshots", "screenshots for every language", "Play Store screenshots" or updating them for a release.
---

# App Store and Google Play screenshots

Screenshots for the stores, made from the real app on simulators and emulators: the same screens
in every locale and device size, with a clean status bar, and files named so they are easy to
upload. Read the `mobdev` skill first for driving the device, and `mobdev-dev-loop` for building
and installing the app.

## 1. Plan

- **Screens:** agree on 3 to 10 screens and their order with the user, each with how to reach it
  and the content it should show. Stores show the first two or three most, so lead with the core.
- **Locales:** the languages the listing supports, as tags such as `en-US`, `de-DE`, `ja-JP`.
- **Appearance:** light, dark or both.
- **Devices:** check the current sizes in App Store Connect's screenshot specifications and Play
  Console. At the time of writing, App Store Connect takes the 6.9-inch iPhone size (a Pro Max
  simulator, e.g. iPhone 17 Pro Max, 1320 × 2868) and scales it for smaller iPhones, plus
  13-inch iPad (an iPad Pro 13-inch simulator) if the app runs on iPad. Google Play takes 2 to 8
  phone screenshots, PNG or JPEG, each side between 320 and 3840 px.
- **Content:** realistic demo data, not test strings or personal data. Ask how the app gets it: a
  launch argument such as `-DemoMode YES`, a seeded account, or a fixture build.

## 2. Prepare each device

Boot one simulator or emulator per size (`xcrun simctl boot "iPhone 17 Pro Max"`; Android
emulators from Android Studio), and find their ids with `list_devices`. Then, on each, with
`device` set:

1. `install_app` the build, `reset_app` for a clean start, and `set_permission` with `grant` for
   what the screens use, so no system prompt is captured.
2. `set_status_bar` with `preset: "screenshot"`: 9:41, full battery and signal. On Android this is
   demo mode.
3. `set_appearance` with `dark: false` (or `true` for the dark set) and the default `text_size`
   (`large`).
4. `set_orientation` with `portrait`, unless the screens are landscape.

## 3. Capture every locale

For each locale:

1. `set_language` with the tag. On a simulator it changes the whole device; on Android pass
   `bundle_id` (Android 13 and later). On iOS, `launch_app` with
   `arguments: ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]` sets it for one launch instead.
2. `launch_app` with `restart: true` and the demo arguments, so the app starts in that language.
3. For each screen: navigate there with `tap_element`, `observe` and `tap_mark`, or a deep link
   with `open_url`; wait for its content with `wait_for_element`, then `wait_for_idle` so no
   animation, spinner or keyboard is caught mid-way; check the content with `observe` (truncated
   or untranslated text is a finding to report, not to hide); then save the screenshot.
4. Save it with `save_screenshot`, which writes a PNG at the device's native resolution, as the
   stores need, into the project's `screenshots/` folder (see Projects in the `mobdev` skill; call
   `list_projects` first, and ask before creating a project):

   ```json
   {"save_screenshot": {"path": "de-DE/iphone-6.9/01-home", "device": "<id>"}}
   ```

Name files `<locale>/<device>/<NN>-<screen>` inside `screenshots/`, numbered in the store's order,
with the device as its size (`iphone-6.9`, `ipad-13`, `android-phone`). Do a whole locale on every
device before the next one, so a missing translation shows early.

To make the set again for a release, save the steps as a test in the project with `save_test`
and `${LANGUAGE}` in the paths, such as `{"save_screenshot": {"path": "${LANGUAGE}/iphone-6.9/01-home"}}`.
`Mobdev test mobdev/ --simulator "iPhone 17 Pro Max" --language en-US --language de-DE --test
"Store screenshots"` then runs it in every language, on a simulator made for the run.

## 4. Check and finish

- Open a few PNGs and check their pixel size against the store's list (`sips -g pixelWidth -g
  pixelHeight <file>`), and that no status bar, keyboard, alert or debug overlay is wrong.
- Put the devices back: `set_status_bar` with `preset: "clear"`, `set_language` with the original
  language, and the appearance as it was.
- Report a table of locale × device with the files, and any screen with clipped or untranslated
  text, so the user can fix the app before uploading. The `screenshots/` folder is meant to be
  committed with the project, so the user sees what changed between releases.

Uploading to App Store Connect or Play Console is the user's step, or a tool such as fastlane
`deliver` and `supply` that they run. Do not upload or submit for review without being asked.
