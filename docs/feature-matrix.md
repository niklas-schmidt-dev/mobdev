# Feature matrix and parity work

Reference: [MobAI's publicly described functionality](https://mobai.run/), reviewed 2026-09-06. The goal is comparable functionality in an independent open-source product. `0.1` is not a drop-in replacement for MobAI, its undocumented API or its full `.mob` grammar.

| Area | Mobdev 0.1 | Remaining work |
|---|---|---|
| Desktop shell | Electron, React, local Node service; build targets for all three OSes | Signed installers, notarization, update delivery; full Windows/Linux runtime checks |
| Android | ADB discovery, screenshots, UI tree, taps, swipes, keys, ASCII text, packages, installation, logs | Bundled tooling, Unicode helper/IME, more device/version acceptance coverage |
| iOS Simulator | macOS simctl discovery, screenshots, apps, installation, logs, recording | Direct native input bridge; input currently requires Appium |
| Physical iOS | Appium XCUITest session adapter | Automatic WDA provisioning/signing, direct non-macOS USB support |
| Device mirroring | Polling screenshots; logical-coordinate input; selected element overlay | Low-latency streaming, richer multi-device grid, rotation controls |
| MCP / CLI / HTTP | Implemented with shared action contracts | Broader compatibility wrappers and distribution as independently published packages |
| Built-in agent | User-configured model, observe/act loop, max 30 turns and 10 minutes, report and script export | Vision input, provider-native protocols, resumable conversations, richer bug reports |
| Test creation | Model draft from current UI, validated syntax, editable before saving | Multi-screen planning and stronger test-intent preservation |
| Test repair | Proposed replacement based on failure and current UI; full original script retained | Automatic rerun/diff verification and repair acceptance workflow |
| Scripts | Tap/type/swipe/keys/lifecycle/waits/assertions/extraction/includes/parameters | Full MobAI DSL compatibility, predicates, conditional branches, retries, spatial queries |
| Suites | Multiple devices in parallel; one queue per known hardware identity | Crash-resilient distributed leases, schedule/retry policy, advanced result aggregation |
| App flows as APIs | Saved flow → synchronous HTTP call with extracted values | Schema publication and per-flow permissions |
| Web automation | Appium context listing and scoped JS execution via HTTP/MCP | First-class selector actions and a web inspector in the UI |
| Screenshots | Evidence files, explicit PNG baseline capture and pixel comparison | Masking, device-specific baseline groups, review UI |
| Video | Native ADB/simctl/Appium recording to MP4, max 180 seconds on ADB/Appium | Phone frames, tap effects, captions, cropping/export presets, recording recovery |
| Animation testing | Not implemented | Frame-by-frame video baselines and timing analysis |
| Performance | ADB PSS memory and cumulative Android graphics jank percentage | FPS/frame times, startup timing, CPU, iOS metrics and trends |
| Debugging | Device logs and failure evidence | Persistent LLDB sessions, breakpoints, stack/variables/expression UI |
| Distributed/cloud devices | Generic remote Appium sessions; provider interface | Remote workers, leases, cloud catalogs, BrowserStack/Sauce/AWS adapters, credentials, quotas |
| Python harness | HTTP API is usable from Python; a small standard-library client example is included | Packaged Python SDK and richer harness |

## Validation boundaries

Backend tests drive an explicit virtual fixture and a fake Appium protocol server. They prove the local control path, persistence, parsing and protocol requests; they do not prove device compatibility with every driver/iOS/Android release. Consult [verification](verification.md) for actual commands and runtime checks performed.

Input selectors prefer case-insensitive exact text, label or resource ID, then substring matches. Separate matches fail as ambiguous; nested duplicate labels resolve to the smallest enclosing hit target. This is deterministic native-tree matching, not OCR or AI semantic targeting.

Android jank is the percentage reported by `dumpsys gfxinfo` for the app's current accumulated stats. It is not instantaneous FPS, and native game engines may not expose it. Missing metrics fail explicitly. Video capture and log availability depend on host/device tools and Appium driver support.

Hardware serialization uses a shared platform/UDID key when known. Supply `appium:udid` for Appium connections. Aliases without a known common hardware identifier cannot be recognized as the same device. There is no cross-process or distributed lease protocol yet.

## Next milestones

1. Accept on physical Android and iOS devices, package on each target OS, strengthen device reconnect and recording recovery.
2. Reduce iOS setup with managed WDA sessions; add low-latency streaming and richer keyboard input.
3. Complete test repair verification, missing DSL semantics and visual-baseline review.
4. Add a persistent debugger bridge and accurate performance/video analysis with device-based acceptance tests.
5. Add remote workers and cloud reservations behind the existing provider interface, with explicit account/cost controls.
