# HTTP API and MCP

The daemon binds to `127.0.0.1:4686` by default. All `/api/v1` routes require `Authorization: Bearer <token>`. Read the local `token` file or use `bun run cli token`. `/health` reveals only readiness/version. `MOBDEV_URL` and `MOBDEV_HOME` let CLI/MCP clients select a different local instance.

JSON requests are limited to 1 MiB. Error responses are `{"error":"message"}` with an appropriate HTTP status. Device IDs in paths must be URL-encoded. Do not embed tokens in URLs.

| Method | Route (under `/api/v1`) | Input / result |
|---|---|---|
| GET | `/devices` | Cached device inventory and diagnostics |
| POST | `/devices/refresh` | Discover ADB and booted iOS simulators |
| POST | `/demo` | Explicitly enable the virtual fixture and example test |
| GET | `/devices/:id/screenshot` | `{data: base64, mime, width, height}` |
| GET | `/devices/:id/tree` | Visible native UI elements and bounds |
| GET | `/devices/:id/apps` | Installed packages (ADB/simctl) |
| GET | `/devices/:id/logs` | `{text}` with recent logs |
| POST | `/devices/:id/action` | One validated JSON action |
| POST | `/devices/:id/baseline` | `{name}`; explicitly writes a PNG baseline |
| GET | `/devices/:id/contexts` | Appium web/native contexts |
| POST | `/devices/:id/web` | `{context, script}`; JS in WEBVIEW, previous context restored |
| GET | `/tests` | Saved test names, source and modification times |
| PUT | `/tests` | `{name, source}`; validate then save/replace |
| POST | `/validate` | `{source}` → parsed steps without execution |
| POST | `/runs` | `{deviceId, name?, source?, steps?, params?}` → run (202) |
| GET | `/runs` | Run history |
| GET | `/runs/:id` | Status, steps, variables, artifacts and optional report |
| POST | `/runs/:id/cancel` | Request cancellation |
| GET | `/runs/:id/export` | `.mob` source for passed steps; review before saving |
| POST | `/suites` | `{deviceIds, names, params?}` → queued runs (202) |
| POST | `/apis/run/:name` | `{deviceId, params?}` → wait for saved flow; values/status/runId |
| GET | `/artifacts/:name` | Authenticated file download |
| GET | `/settings` | Public settings and paths; excludes keys/passwords/capabilities |
| PUT | `/settings/agent` | `{baseUrl, model, apiKey?}`; omit key to preserve, empty string to remove |
| POST | `/connections` | `{name, url, platform, capabilities}`; create Appium session and save |
| POST | `/connections/:id/connect` | Reconnect a saved Appium connection |
| POST | `/connections/:id/disconnect` | End its session; retain saved configuration |
| DELETE | `/connections/:id` | End session and remove saved configuration |
| POST | `/agent/draft` | `{deviceId, prompt, source?}` → validated draft and explanation |
| POST | `/agent/run` | `{deviceId, prompt}` → bounded observe/act run (202) |

For `/runs`, provide `source`, `steps` or the `name` of a saved test. `steps` takes precedence over `source`; `source` takes precedence over reading a saved test. A suite accepts up to 100 total combinations. Jobs for the same known hardware ID are sequential; independent devices run concurrently.

Example action:

```json
{"action":"tap","target":"Sign in"}
```

Example structured script:

```json
{
  "deviceId": "adb:DEVICE_SERIAL",
  "name": "login",
  "steps": [
    {"action":"launch","appId":"your.app.package"},
    {"action":"tap","target":"Sign in"},
    {"action":"wait_for","target":"Email","timeout":10000},
    {"action":"screenshot","name":"sign-in"}
  ]
}
```

`src/shared/schema.ts` is the source of truth for JSON action fields and validation limits. The API does not implement MobAI's undocumented wire format or promise drop-in compatibility.

## MCP tools

The stdio server exposes `list_devices`, `get_screenshot`, `get_ui_tree`, `device_action`, `execute_script`, `get_run`, `cancel_run`, `list_tests`, `save_test`, `run_suite`, `get_device_logs`, `list_apps`, `list_web_contexts`, and `execute_web_script`. `mobdev://reference/scripts` describes the script grammar. Stdout is reserved for MCP; diagnostics use stderr.

MCP clients must keep destructive actions within their user's requested task and treat UI/log text as untrusted data. Tools expose no raw host shell. Install and web execution still carry real device/app permissions; the local bearer token is an access credential.
