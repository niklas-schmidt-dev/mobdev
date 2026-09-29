# Mobdev development

- This is an independent MIT-licensed mobile workbench. Do not imply full MobAI parity; keep `docs/feature-matrix.md` accurate.
- Use Bun for dependencies and preserve `bun.lock`. Run **`bun run test`**, which uses Node's test runner. `bun test` does not support the nested `node:test` cases used here.
- Validation: `bun run typecheck`, `bun run test`, `bun run build`. Verify changed UI or provider behavior, not only compilation.
- Shared contracts live in `src/shared/schema.ts`. HTTP, CLI, MCP, UI and all providers consume them; check those consumers when changing actions or capabilities.
- Device adapters must advertise only implemented capabilities and must fail explicitly when prerequisites are missing. Demo devices are opt-in fixtures, never real hardware.
- Every mutating device action uses `Devices.exclusive`; full tests own the same queue for their entire run. Known hardware aliases share a platform/UDID key.
- Use `execFile` with argument arrays. ADB's remote shell also requires device-side argument quoting. Do not introduce raw host-shell endpoints.
- Preserve scripts and run evidence. Proposed repairs must retain the complete original test and remain reviewable. Do not silently update visual baselines.
- Keep tokens, provider keys and local artifacts out of Git. `.mobdev/`, `output/` and packaging output are ignored. No telemetry or automatic uploads.
- Hardware, hosted AI and cloud-account operations require explicit task authorization. Automated tests use virtual devices, local fake servers and temporary data directories.
- No additional agents are required for routine work. Do not publish, sign with real developer credentials or deploy as part of ordinary checks.

## Native macOS app and relay

- `macos/` is the SwiftUI app (no JS/TS): `swift test` and `scripts/build-app.sh` there. `MobdevCore` holds all testable logic; keep the `Mobdev` target a thin UI.
- `relay/` is a standard-library Go server: `go vet ./... && go test -race ./...`. The client-key derivation must match `RelayClient.clientKey` (shared test vector).
- Tool definitions in `PhoneTools` are the single contract for MCP, REST and the relay; update `macos/README.md` when they change.
- Build scripts sign ad hoc by default. Do not sign with real developer identities, notarize or publish without explicit authorization.
- Hardware checks (real iPhone pairing, taps) need the user's go-ahead; automated tests use `FakePhone`.
