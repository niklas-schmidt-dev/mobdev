---
name: mobdev-react-native
description: Run, reload and debug React Native, Expo and Flutter apps on an iOS simulator, an Android emulator or an iPhone with Mobdev - open a project in Expo Go or a development build, reload the JavaScript, open the developer menu, read Metro's logs, find elements by testID or Semantics, and check performance. Use when the app is built with React Native, Expo or Flutter, or the user mentions Metro, Expo Go, a dev client, Fast Refresh, hot reload, testID or the developer menu.
---

# React Native, Expo and Flutter with Mobdev

The loop is the one of the `mobdev-dev-loop` skill; these frameworks add a dev server on the Mac
(Metro for React Native and Expo, the Flutter tool for Flutter) that serves the code and reloads
it without a new build. Read the `mobdev` skill for driving the UI.

## Start Metro and open the app

Run Metro on the Mac that runs Mobdev, in its own terminal or in the background with its output in
a file you can read:

```sh
npx expo start                  # Expo; add --dev-client for a development build
npx react-native start          # React Native without Expo
npx expo start > /tmp/metro.log 2>&1 &   # in the background, logs in a file
```

Metro listens on port 8081 unless you pass `--port`; pass the same `port` to `reload_app` and
`dev_menu`.

- **Expo Go** (no native build): install Expo Go once on the simulator (`npx expo start --ios`, or
  press `i` in Metro's terminal), then `open_url` with `exp://127.0.0.1:8081`. On an Android
  emulator use `exp://10.0.2.2:8081`, which is the Mac as the emulator sees it. On an iPhone use the
  `exp://192.168.…:8081` address Metro prints, with the iPhone on the same network. With
  `npx expo start --localhost`, Metro may listen on IPv6 only and `exp://127.0.0.1` then fails with
  "Could not connect to the server": use `exp://localhost:8081` or start without `--localhost`.
- **Development build** (`expo-dev-client`): build and install it like any app (`install_app`, then
  `launch_app`), then open the project with `open_url` and
  `<scheme>://expo-development-client/?url=http%3A%2F%2F127.0.0.1%3A8081`. The scheme is `scheme`
  from app.json, or `exp+<slug>` when it has none; `npx expo start --dev-client` prints the full URL.
- **React Native without Expo**: a Debug build loads its JavaScript from Metro on `localhost:8081` by
  itself. Install and start it with `install_app` and `launch_app`.

The first time Expo Go opens a project it shows its developer menu with "This is the developer
menu…": tap Continue (`tap_text`), then Close (`tap_element` with id `xmark`).

## Reload and the developer menu

- **Fast Refresh** applies saved changes on its own while Metro watches the files; there is nothing
  to call. Check the result with `screenshot` or `wait_for_text`.
- **`reload_app`** reloads the whole JavaScript bundle and resets its state, as pressing `r` in
  Metro's terminal does: Metro tells every app connected to it to reload. When no app is connected,
  Mobdev opens the developer menu and taps Reload instead. Use it after changing something Fast
  Refresh cannot apply, or to start a screen from scratch.
- **`dev_menu`** opens the developer menu: a shake on a simulator, the Menu key on Android. On an
  iPhone Mobdev cannot shake the phone, so it asks Metro to open the menu. Expo Go also has a gear
  button on screen (id `gearshape.fill`) that opens it.
- Native changes (new native modules, app.json plugins, Info.plist) need a new build: rebuild,
  `install_app`, `launch_app`.

## Logs

- Expo CLI prints the app's `console.log` lines in its own output as ` LOG  …`. Start Metro with its
  output in a file and read the file, e.g. `grep "LOG" /tmp/metro.log`.
- `logs` shows what an app started with `launch_app` prints natively: crashes, native modules, and
  for some React Native versions JavaScript lines as `[javascript] …`. An app opened in Expo Go with
  `open_url` is not captured.
- A red error screen ("RedBox") shows the JavaScript error and its stack; `read_screen` or
  `ui_tree` reads it, and its buttons have ids such as `redbox-reload` and `redbox-dismiss`.
- `crash_reports` covers native crashes, as for any app.

## Finding elements

- React Native `testID` becomes the accessibility identifier on iOS and the resource id on Android,
  so `tap_element` and `wait_for_element` take it as `id`. Put it on the touchable (`Pressable`,
  `TouchableOpacity`, `Button`) or a `View`: on a plain `<Text>` iOS may not show it, so find text by
  its label instead.
- `accessibilityLabel` becomes the label; it wins over the text inside the element.
- **Flutter**: the UI tree comes from Flutter's semantics. `Semantics(identifier: 'checkout')`
  (Flutter 3.19 and later) becomes the id; `Semantics(label: …)` and text become labels. Widget
  `Key`s are not visible to Mobdev. When `ui_tree` shows one big element for the whole app, the
  semantics tree is off; `SemanticsBinding.instance.ensureSemantics()` in a debug build turns it on.

## Flutter hot reload

Flutter has no Metro. Run the app with `flutter run` (or attach to one already running with
`flutter attach`) in a terminal on the Mac, then press `r` there for hot reload and `R` for hot
restart. To do it from a script, start it with a pid file and send signals:

```sh
flutter run -d <device id> --pid-file /tmp/flutter.pid > /tmp/flutter.log 2>&1 &
kill -USR1 "$(cat /tmp/flutter.pid)"   # hot reload
kill -USR2 "$(cat /tmp/flutter.pid)"   # hot restart
```

`flutter run`'s output holds the app's `print` and `debugPrint` lines.

## Performance

Measure in a release or profile build when the numbers matter: a debug build runs the JavaScript or
Dart in a slower mode and talks to the dev server.

- `performance` with `bundle_id` samples CPU and memory for a few seconds, and on Android frames
  (janky share and frame times). Expo Go's bundle ID is `host.exp.Exponent`, so the numbers include
  Expo Go itself.
- `measure_launch` times cold launches. On a simulator it reports iOS's own first-frame time; for a
  React Native app that is the native first frame, often a splash screen. `method: "screen"` with
  `stable` longer than the splash times until the screen settles on the real first screen.
- Budgets (`max_cpu`, `max_memory_mb`, `max_janky_percent`, `max_ms`) make the call fail, so a saved
  test can hold the app to them.
