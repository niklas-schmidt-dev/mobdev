# Contributing

Mobdev is early, independent and MIT licensed. Start with a bounded issue or an item in the feature matrix.

1. Use Bun and preserve `bun.lock`.
2. Keep the TypeScript action/provider contract strict. Advertise only capabilities the adapter implements.
3. Add meaningful tests for parser semantics, protocol behavior, persistence or execution changes. Use the explicit demo/fake servers in automated tests; never operate personal devices or paid accounts in CI.
4. Run `bun run typecheck`, `bun run test` and `bun run build`.
5. Exercise the actual UI or affected adapter when possible. State hardware/OS validation gaps in the PR.
6. Update the feature matrix when behavior or support boundaries change.

Do not commit workspace tokens, model keys, device screenshots, private logs or `.mobdev` data. Do not label mocked protocol tests as real-device validation. Preserve unrelated user changes. Cloud integrations must not reserve or bill devices during discovery.

Packaging uses Electron Builder. Unsigned CI artifacts are for development. Release signing/notarization credentials belong in a release owner's secret store, not this repository.
