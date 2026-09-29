# Architecture

```text
Electron renderer (React)          External AI tools / CI / Python
          │                                  │
  sandboxed preload                     MCP stdio / CLI
          │                                  │
          └──────── authenticated HTTP ────────┘
                            │
                    local Node daemon
                            │
             validation / per-hardware queue
                            │
                  script and agent runner
                            │
          ┌─────────────────┼─────────────────┐
       direct ADB       macOS simctl        Appium
          │                 │                 │
      Android        iOS Simulator     iOS / Android
                                     local or remote
```

`src/shared/schema.ts` defines the shared validated action union, devices, capabilities, tests and run results. The UI, HTTP API, CLI and MCP use the same contract. `.mob` is parsed into that union by `src/server/dsl.ts`; variables expand into existing string fields after parsing.

`src/server/providers/provider.ts` is the boundary for device transports. A provider implements observations, input and lifecycle methods; optional recording, metrics and web methods correspond to advertised capabilities. Native simulator preview does not claim input support. The demo is an explicitly opted-in stateful fixture, not substitute hardware.

`Devices.exclusive` serializes actions and complete scripts using platform + hardware ID where known. Appium `appium:udid` links aliases to their native ADB/simctl queue. Each run owns an abort controller. The runner stores step outcomes, extracted values and artifact references, finalizes recordings and captures failure evidence. Included scripts share parameters but have recursion/step limits.

Persistence is plain files, written via a temporary file and atomic rename. Interrupted run records are marked cancelled at startup. There is no database or migration framework in this initial version. Existing saved scripts are not overwritten during startup. Results are loaded locally; a future database should be introduced with an explicit storage format/version migration if history size warrants it.

The agent is a bounded client of a user-selected model. It receives current native UI text and prior steps, chooses validated actions and produces a final report. Model output is not a shell or executable program. Draft/repair source is syntax-checked and shown for review; it does not overwrite the original test. A proposed repair has not been verified until the user runs it.

Electron disables Node integration, enables context isolation and sandboxing, denies new windows/navigation, and exposes only a bootstrap IPC call restricted to the owning main frame. The daemon provides production static assets with a restrictive CSP. Browser use requires the local API token. Development explicitly permits only the selected Vite origin.

## Cloud extension boundary

Keep test semantics independent of reservations, credentials and transport. A later cloud provider should implement the same device actions and add an explicit reservation lifecycle: catalog → reserve → connect → release. Store vendor credentials using an OS secret store and represent remote session expiry/failure as capability/device state. Add cost consent at reservation time; never provision paid devices merely during discovery.

A distributed farm also needs cross-process leases, heartbeat/expiry, encrypted authenticated worker connections and durable job ownership. The current local promise queue is not a distributed locking solution. A generic Appium URL is useful today but is not equivalent to a complete BrowserStack, Sauce Labs or AWS Device Farm integration.
