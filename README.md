# Mobdev

Mobile development, all in one app. Free and open source.

Mobdev is a small native Mac app that puts your iPhones, iOS simulators and Android devices in one
list and gives you and your AI agent everything to work with them. Claude Code, Codex, Cursor or
any MCP client get the same 47 tools on every device, and scripts get them on the command line.

| | |
|---|---|
| AI control | Screenshots, taps, swipes, typing, opening apps, tapping visible text (on-device OCR); the UI tree and tapping by accessibility identifier on simulators, Android and Developer Mode iPhones. `observe` lists the screen as numbered marks to tap; agents scroll until something shows and wait until the screen settles instead of guessing |
| Device state | Location and routes, permissions, push notifications, dark mode and text size, language, a clean status bar, Face ID, an app's data, the clipboard and orientation, set by a tool instead of in Settings (simulators and Android, some on iPhones) |
| Build and run | Install builds, launch apps with arguments and environment, open deep links, by agent or in the app's Apps area |
| Debug | Logs and crash reports of the apps you launch, screen recordings on demand; Diagnose checks and fixes an iPhone's connection |
| Tests and flows | A project folder with your app's tests: agents write and run them, the app shows the results, CI runs them with `Mobdev test` or the [GitHub Action](actions/test/README.md), with JUnit output and a Markdown summary for the job and the pull request. Record what you or an agent do and replay it as a flow |
| Command line | `Mobdev <tool> key=value` runs any tool from a terminal or script, for agents without MCP |
| Test and research | [Skills](skills/README.md) for the dev loop, smoke tests, bug reproduction, store screenshots, onboarding audits and competitor research |
| Guard rails | Agents cannot open or launch the apps you block, such as banking or mail |
| Live mirror | Click, swipe and type on any device from the Mac |
| Remote | Agents on other machines reach your devices through a hosted or self-hosted relay |

The iPhone needs nothing installed. Mobdev reads its screen over the USB cable and taps and types
through Bluetooth, posing as a keyboard and pointer: no developer mode, no jailbreak, and every app
works. Turn on Developer Mode only to install and debug your own builds, or for the UI tree. Booted simulators need
Xcode, Android emulators and phones need adb. Keep building with Xcode, Gradle or XcodeBuildMCP;
Mobdev takes over once there is a build.

```
   iPhone ──USB screen──▶ Mobdev.app ◀── MCP / HTTP ── agents on this Mac
          ◀─Bluetooth HID─     │
                               └── WebSocket ──▶ relay ◀── agents anywhere (optional)
```

## Repository

| Folder | What | Stack |
|---|---|---|
| [`macos/`](macos/README.md) | The Mac app, MCP server, HTTP API and stdio bridge | SwiftUI, macOS 26+, Sparkle for updates |
| [`relay/`](relay/README.md) | Self-hosted relay for remote access | Go, one binary or Docker image |
| [`cloud/`](cloud/README.md) | mobdev.sh: website, dashboard and hosted relay | TanStack Start, Cloudflare Workers, Durable Objects, D1, WorkOS |
| [`skills/`](skills/README.md) | Agent skills: dev loop, smoke tests, bug reproduction, store screenshots, onboarding audits, competitor research; with [`.claude-plugin/`](.claude-plugin/plugin.json) also a Claude Code plugin | Markdown (`SKILL.md`) |
| [`actions/test/`](actions/test/README.md) | GitHub Action that runs Mobdev tests and flows on a simulator | Composite action, Bash |
| [`packaging/homebrew/`](packaging/homebrew/mobdev.rb) | Homebrew cask, for a tap that does not exist yet | Ruby |

## Get started

[Download Mobdev](https://mobdev.sh/download) (signed, notarized, updates itself), or build it:

```sh
cd macos
MOBDEV_VARIANT=release scripts/build-app.sh
open build/Mobdev.app
```

Then plug in the iPhone, pair it over Bluetooth and turn on AssistiveTouch with Snap to Item off.
The app walks through it; details are in [`macos/README.md`](macos/README.md). Without an iPhone,
choose **Simulators and Android Only** on the welcome page.

Remote access is optional. Create an access token at [mobdev.sh](https://mobdev.sh/dashboard) and
click “Open in Mobdev”, or run [your own relay](relay/README.md).

Give your agent the workflows too. In Claude Code, the Mobdev plugin adds the MCP server and the
[skills](skills/README.md) in one go:

```
/plugin marketplace add niklas-schmidt-dev/mobdev
/plugin install mobdev@mobdev
```

Other agents get the skills with `npx skills add niklas-schmidt-dev/mobdev` and the MCP server as
shown in [`macos/README.md`](macos/README.md).

In GitHub Actions, `uses: niklas-schmidt-dev/mobdev/actions/test@main` runs your app's tests or a
flow on an iOS simulator and puts the results in the job summary; see
[`actions/test`](actions/test/README.md).

## Homebrew (once the tap exists)

[`packaging/homebrew/mobdev.rb`](packaging/homebrew/mobdev.rb) is a cask for a tap that does not
exist yet. To publish it, the maintainer creates the public repository
`niklas-schmidt-dev/homebrew-tap`, runs `packaging/homebrew/update-cask.sh <version>` after a
release (it downloads that release's DMG and fills in version and sha256), and commits the result
there as `Casks/mobdev.rb`. Then:

```sh
brew install --cask niklas-schmidt-dev/tap/mobdev
```

installs Mobdev.app into `/Applications` and a `mobdev` command. The app keeps updating itself
through Sparkle, so `brew upgrade` leaves it alone unless run with `--greedy`; the cask still
needs the script and a commit for each release to install the newest version.

## Development

```sh
cd macos && swift test && scripts/build-app.sh      # Mac app: builds "Mobdev Dev"
cd relay && go vet ./... && go test -race ./...    # self-hosted relay
cd cloud && bun install && bun run typecheck && bun run test && bun run build
claude plugin validate .                            # Claude Code plugin and marketplace
shellcheck actions/test/action.sh packaging/homebrew/update-cask.sh   # GitHub Action, cask script
```

The Swift tests build and start the Go relay to test remote access end to end. Everything runs
without an iPhone: a fake phone renders real text so OCR, `tap_text` and coordinates are covered.

## Shipping

Every push to `main` ships what changed, through GitHub Actions:

| Change in | Workflow | Result |
|---|---|---|
| `cloud/` | `cloud.yml` | Tests, D1 migrations, deploy of mobdev.sh; relay.mobdev.sh only when the relay changed |
| `macos/` | `macos.yml` | Tests, universal build, Developer ID signature, notarization, DMG with a designed install window (`macos/scripts/dmg-settings.py`), GitHub release `mac-v<version>`. `mobdev.sh/appcast.xml` then offers it and installed apps update through Sparkle |
| `relay/` | `relay.yml` | Tests, `ghcr.io/niklas-schmidt-dev/mobdev-relay` for amd64 and arm64 |

The app version is `macos/VERSION` plus the workflow run number. The update window and the GitHub
release show what's new, collected from `Release-Note:` lines in the commit messages since the
previous release:

```
Release-Note: New: All Devices shows every iPhone connected to your Macs.
```

Start a note with `New:`, `Improved:` or `Fixed:`; commits without one are not listed. Repository secrets:
`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`,
`APPLE_API_KEY` (base64 `.p8`), `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `SPARKLE_PRIVATE_KEY`.
The Sparkle key's backup is the "mobdev" item in the maintainer's keychain; losing it means
installed apps can no longer be updated.

## Status

Early release. Verified on hardware: USB screen capture, Bluetooth pairing, MCP, OCR and remote
access through both relays, taps, swipes and scrolling with AssistiveTouch, and typing with the
German layout, on iOS 27. Several iPhones on one Mac each get their own Bluetooth connection, which
has not been tried with two iPhones at once yet. Every tool is verified on
an iOS 27 simulator (Xcode 27) and an Android 16 emulator; Android phones use the same adb path but
have not been tried yet.

MIT licensed. Independent project; not affiliated with Apple, TapKit or MobAI.
