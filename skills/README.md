# Mobdev skills

Agent skills that turn Mobdev's tools into complete workflows. They work with Claude Code, Codex,
Cursor and other agents that read `SKILL.md` files.

In Claude Code, the Mobdev plugin installs them together with Mobdev's MCP server (the Mobdev app
must be in `/Applications`):

```
/plugin marketplace add niklas-schmidt-dev/mobdev
/plugin install mobdev@mobdev
```

For other agents:

```sh
npx skills add niklas-schmidt-dev/mobdev                          # all of them
npx skills add niklas-schmidt-dev/mobdev --skill mobdev-dev-loop  # one
```

Or copy a folder into your agent's skills directory, e.g. `~/.claude/skills/`.

| Skill | For |
|---|---|
| [`mobdev`](mobdev/SKILL.md) | Driving an iPhone, simulator or Android device reliably: seeing the screen, tapping, typing, device state, recordings, the command line, safety |
| [`mobdev-dev-loop`](mobdev-dev-loop/SKILL.md) | Build, install, launch, read logs and crash reports of your own iOS or Android app |
| [`mobdev-react-native`](mobdev-react-native/SKILL.md) | React Native, Expo and Flutter apps: Expo Go and dev clients, reload, the developer menu, testIDs, performance |
| [`mobdev-smoke-test`](mobdev-smoke-test/SKILL.md) | A quick pass/fail check of an app's critical paths, with evidence |
| [`mobdev-bug-repro`](mobdev-bug-repro/SKILL.md) | Reproduce a bug report: device state, video, logs and crash reports, a minimal reproduction saved as a test |
| [`mobdev-store-screenshots`](mobdev-store-screenshots/SKILL.md) | App Store and Google Play screenshots for every locale and device size |
| [`mobdev-onboarding-audit`](mobdev-onboarding-audit/SKILL.md) | A first-run walkthrough with friction scores and fixes |
| [`mobdev-competitor-research`](mobdev-competitor-research/SKILL.md) | App Store listings, onboarding and paywalls of competing apps |

Each skill keeps a human in the loop for anything that pays, sends, deletes or uses real accounts.
