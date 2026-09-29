# Mobdev

> **Native app:** [`macos/`](macos/README.md) contains a SwiftUI Mac app (about 2 MB, no JS/TS) that lets agents control a real iPhone over USB + Bluetooth, with MCP, a local HTTP API and an optional self-hostable [relay](relay/README.md). The Electron/TypeScript workbench described below is the earlier 0.1 foundation.

An open-source workbench for mobile devices, automation and AI-assisted testing.

**Status: working 0.1 foundation; not full MobAI feature parity.** Desktop builds target macOS, Windows and Linux. Android connects through ADB; iOS automation uses Appium XCUITest, with native simulator discovery on macOS. Cloud-specific services are planned. See the [feature matrix](docs/feature-matrix.md) for implemented behavior, limitations and remaining work.

No account, license server or telemetry. MIT licensed. Independently implemented; not affiliated with MobAI. No MobAI application code or assets are included.

## Start locally

Install [Node.js 22.12 or newer](https://nodejs.org/) and [Bun](https://bun.sh/), then:

```sh
bun install --frozen-lockfile
bun run build
bun run start
```

The desktop app starts its own authenticated loopback daemon. The renderer receives its connection through a narrow Electron preload bridge. **Try demo phone** lets you exercise the workbench without using a real phone or AI account. It is clearly labeled as a virtual fixture.

For frontend development:

```sh
bun run dev
```

This starts Vite and Electron and shuts both down on exit. Renderer edits reload automatically; restart for daemon or Electron edits. To isolate development data, set `MOBDEV_HOME` to an absolute directory before starting. POSIX: `export MOBDEV_HOME="$PWD/.mobdev/dev"`; PowerShell: `$env:MOBDEV_HOME = "$PWD/.mobdev/dev"`.

For headless use or a browser UI:

```sh
bun run build
bun run daemon --demo
# In another terminal, get the token for the browser login:
bun run cli token
```

Open `http://127.0.0.1:4686`. Do not run the desktop app and daemon against the same port/data directory at the same time. The demo flag adds a fixture; without it no demo devices are created. `--no-discovery` avoids invoking host device tools, useful for isolated checks.

## Device support

| Device | macOS host | Windows / Linux host |
|---|---|---|
| Android USB or ADB Wi-Fi | Direct ADB or Appium | Direct ADB or Appium |
| Android emulator | Direct ADB or Appium | Direct ADB or Appium |
| iOS Simulator | Native preview/apps/logs/video; Appium for input/tree | Remote Appium server on a Mac |
| Physical iPhone / iPad | Appium XCUITest with signed WebDriverAgent | Remote Appium server on a Mac |

iOS Simulator and Xcode do **not** run locally on Windows or Linux. Native iOS USB control on those hosts is not implemented. Device drivers and USB authorization remain operating-system prerequisites.

**Android:** install [SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools), enable USB debugging and authorize your computer. Mobdev checks `MOBDEV_ADB`, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, common SDK locations, then `PATH`. Windows may require the manufacturer's USB driver; Linux may require udev rules. Wi-Fi devices already paired through `adb` appear automatically on refresh.

**iOS:** install Xcode on a Mac and boot a simulator. For full interaction, install [Appium](https://appium.io/docs/en/latest/quickstart/) and its [XCUITest driver](https://appium.github.io/appium-xcuitest-driver/latest/). Start Appium and add a connection in **Connections** using your device's UDID. Physical iOS devices require Developer Mode, trust and WebDriverAgent signing according to the driver's documentation. Mobdev does not silently install drivers or modify signing settings.

For a remote Mac, forward its Appium port with SSH and connect to the forwarded localhost URL:

```sh
ssh -L 4723:127.0.0.1:4723 your-mac
```

Use `http://127.0.0.1:4723` with capabilities such as:

```json
{
  "appium:deviceName": "iPhone",
  "appium:udid": "YOUR_EXACT_DEVICE_UDID"
}
```

Select iOS or Android in the connection form. Mobdev supplies XCUITest or UiAutomator2 and `noReset: true`. Additional capabilities remain under your control. Saved remote connections reconnect only when requested.

## What works

- Device discovery, screenshots, point-and-click input, swipes, typing, native UI inspection and app launch.
- Recording manual interactions into editable `.mob` files, plus native video capture where supported.
- Validated test scripts, parameters, composition, assertions, extracted values, cancellation and suites across devices.
- Persistent run evidence, failure screenshots/logs, explicit PNG baselines, Android PSS memory and jank assertions.
- A local HTTP API, Node CLI and stdio MCP server for coding agents.
- A bounded built-in agent using a model endpoint you configure; test drafts and proposed repairs are reviewable before replacing tests.
- Appium web contexts and JavaScript execution through the API/MCP.

Preview uses periodic screenshots, not a low-latency video stream. ADB's direct text input supports printable ASCII (except literal `%s`); use Appium for Unicode. Appium driver-specific features may require additional driver configuration. See [limitations](docs/feature-matrix.md).

## Tests and CLI

```mob
launch "your.app.package"
tap "Sign in"
type "Email" "${email}"
tap "Continue"
wait_for "Welcome" 10000
assert_not "Error"
screenshot "welcome"
```

```sh
bun run cli devices
bun run cli run examples/demo-sign-in.mob --device demo:android --wait
bun run cli tree demo:android
```

The demo command requires a daemon with the demo phone enabled. For real devices, use the exact ID from `devices`. Add `--params '{"email":"user@example.com"}'` to supply script parameters (adapt quoting to your shell). `--wait` returns a nonzero exit code on a failed/cancelled run. Built CLI entry points are `dist/cli/mobdev.js` and `dist/cli/mobdev-mcp.js`; they run with Node without Bun or tsx.

See the [script reference](docs/scripts.md) and [HTTP API](docs/api.md).

## AI integrations

**Connections** provides a ready-to-copy MCP configuration with the actual local paths. A generic configuration is:

```json
{
  "mcpServers": {
    "mobdev": {
      "command": "node",
      "args": ["/absolute/path/to/mobdev/dist/cli/mobdev-mcp.js"]
    }
  }
}
```

If using a custom data directory, pass `MOBDEV_HOME` in `env`. Set `MOBDEV_URL` for a non-default port. The MCP process reads the daemon's token locally; tokens need not be placed in the MCP configuration. The daemon must be running.

The built-in agent supports OpenAI-compatible `POST /chat/completions` endpoints, including locally running Ollama. Configure an installed model's exact ID. No provider account or paid API calls are made automatically. Starting an agent or drafting/repairing a test sends **visible UI text and action history** to the configured model. A hosted model therefore receives device data and may charge for requests. Screenshots are currently not sent by the built-in agent. External MCP clients control their own model/data handling.

## Storage and access

Default data directories:

- macOS: `~/Library/Application Support/Mobdev`
- Windows: `%APPDATA%\Mobdev`
- Linux: `$XDG_CONFIG_HOME/Mobdev` or `~/.config/Mobdev`

Contains `tests/*.mob`, `runs/*.json`, `artifacts/`, `baselines/`, `settings.json` and `token`. Set `MOBDEV_HOME` to override. Secrets and artifacts are written with restrictive permissions where supported; model keys are currently stored in a local file, **not** an OS keychain. On Windows, access follows the user's profile ACLs. Tests, typed values, logs and screenshots can contain private app data; exclude the data directory from shared repositories.

The daemon binds only `127.0.0.1`, requires a bearer token for all device APIs, validates Host/Origin headers and does not expose an arbitrary shell endpoint. Do not expose the daemon directly to the public internet. Remote provider networking is explicit. Device automation still operates with your developer permissions.

## Development and packaging

```sh
bun run typecheck
bun run test
bun run build
bun run package
```

Electron Builder creates packages for the current OS in `release/`. The CI matrix builds and tests on macOS, Windows and Linux and produces unsigned package artifacts. Public release, code signing, notarization, auto-update delivery and production hardware validation are separate work; no release has been published from this checkout.

See [architecture](docs/architecture.md), [verification](docs/verification.md) and [contributing](CONTRIBUTING.md).
