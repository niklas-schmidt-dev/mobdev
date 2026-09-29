# Verification

Performed locally on macOS (Apple Silicon), 2026-09-06.

## Automated checks

- `bun run typecheck`: passed.
- `bun run test`: **26 tests passed**, including a freshly bundled MCP process over stdio, Appium protocol requests, scripted device interaction, screenshots/failure logs, parameter safety, cancellation, nested includes, cross-device suites, shared hardware queues, pixel baselines, missing metrics, Host/Origin/token validation and a bounded agent using a local fake model endpoint.
- `bun run build`: passed with Vite 7.3.6, React plugin 5.2.0 and the locked dependency versions. Produces renderer, Electron main/preload and standalone Node CLI/MCP bundles. Vite 7.3 is a [supported release line](https://vite.dev/releases). Only used Lucide icon modules are imported.

The complete suite passed under Node 24 LTS and Node 26. The configured command is `bun run test` (Node's runner); `bun test` is not supported because Bun 1.3 does not implement the nested `node:test` API used by the suite. An earlier TypeScript-loader-based MCP process test started inconsistently on this host; it now tests a freshly bundled executable, matching distribution behavior.

## Runtime checks

The production web UI was opened in a real browser at localhost with an isolated `.mobdev/verification` workspace. Verified:

- Token entry and device/inspector rendering.
- Six-step demo sign-in test initiated in the editor, all steps passed, artifact persisted.
- Home key, an actual click on the mirrored screen at logical device coordinate `(195, 615)`, typing a fictitious email, selecting the Continue element and tapping it.
- Successful navigation to the welcome screen after both automated and manual input.
- Connection settings and MCP configuration display.
- Layout at 1440×1024 and 940×720.

The **real Electron app** was then launched from the built main/preload files with a separate demo-only workspace. An automated desktop smoke check confirmed:

- Automatic local-daemon connection through the preload bridge.
- `contextIsolation: true`, `sandbox: true`, `nodeIntegration: false`, and no renderer `require`.
- A passing six-step test and an intentional failed assertion displayed in the run history.
- Unsaved test edits survived switching to Connections and back.
- No renderer JavaScript errors during the tested flow.

An **unsigned macOS ARM64 app bundle** was then produced with `bun node_modules/electron-builder/out/cli/cli.js --dir --publish never -c.mac.identity=null`. The same desktop smoke check passed against `release/mac-arm64/Mobdev.app/Contents/MacOS/Mobdev`, exercising the packaged renderer and daemon. The bundle includes standalone CLI/MCP files under `Contents/Resources/cli`. Packaging dependencies loaded unusually slowly with Node on this host; invoking the installed builder with Bun completed successfully. DMG/ZIP creation, signing and notarization were not tested.

Screenshots from this checkout are in `output/playwright/` (ignored by Git). `desktop.png` shows the built desktop app; `test-run.png` shows the successful test evidence. Temporary browser and daemon processes were stopped after verification; the desktop smoke check closes the app itself.

## Not established by these checks

No personal phone, live hosted model account or paid cloud device was operated. ADB and simulator parsing, Appium HTTP contracts and virtual-device behavior are tested; actual Android hardware, physical iOS, video recording on a device and real Appium driver versions still need acceptance tests. No Windows/Linux desktop runtime or signing/notarization was performed here. The CI matrix is configured for those operating systems but has not been executed remotely.

Do not interpret a passed demo or mocked protocol test as proof of full real-device support or full feature parity. See the [feature matrix](feature-matrix.md).
