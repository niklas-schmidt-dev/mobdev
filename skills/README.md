# Mobdev skills

Agent skills that turn Mobdev's tools into complete workflows. They work with Claude Code, Codex,
Cursor and other agents that read `SKILL.md` files.

```sh
npx skills add niklas-schmidt-dev/mobdev                          # all of them
npx skills add niklas-schmidt-dev/mobdev --skill mobdev-dev-loop  # one
```

Or copy a folder into your agent's skills directory, e.g. `~/.claude/skills/`.

| Skill | For |
|---|---|
| [`mobdev`](mobdev/SKILL.md) | Driving the iPhone reliably: seeing the screen, tapping, typing, safety |
| [`mobdev-dev-loop`](mobdev-dev-loop/SKILL.md) | Build, install, launch, read logs and crash reports of your own app |
| [`mobdev-smoke-test`](mobdev-smoke-test/SKILL.md) | A quick pass/fail check of an app's critical paths, with evidence |
| [`mobdev-onboarding-audit`](mobdev-onboarding-audit/SKILL.md) | A first-run walkthrough with friction scores and fixes |
| [`mobdev-competitor-research`](mobdev-competitor-research/SKILL.md) | App Store listings, onboarding and paywalls of competing apps |

Each skill keeps a human in the loop for anything that pays, sends, deletes or uses real accounts.
