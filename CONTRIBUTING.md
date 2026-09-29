# Contributing

Mobdev is early, independent and MIT licensed. Start with a bounded issue.

1. Keep the three parts consistent: the Mac app (`macos/`), the self-hosted relay (`relay/`) and mobdev.sh (`cloud/`). Relay protocol changes touch all three.
2. Add tests for protocol, parsing, tool and persistence changes. Tests use the fake phone and fake Macs; never operate personal devices or paid accounts in CI.
3. Run the checks listed in the README for every part you changed.
4. Try UI changes in the running app or site. State what you could not test on real hardware in the pull request.
5. The Mac app follows Apple's macOS 26 design: standard SwiftUI controls, Liquid Glass, no custom chrome.

Do not commit tokens, `.dev.vars`, device screenshots or app data. Release signing, notarization and deployment credentials belong to the release owner, not this repository.
