# .mob scripts (Mobdev v1)

One command per line. Arguments containing spaces use double-quoted JSON strings; `\"`, `\\`, `\n` and Unicode are supported. `#` starts a comment outside a quoted string. Names such as `login.mob`, artifact names and baseline names use letters, numbers, hyphens, underscores and dots; subdirectories and `..` are not accepted in v1.

| Command | Behavior |
|---|---|
| `tap "Sign in"` | Resolve text/label/resource ID and tap its center |
| `tap 100 240` | Tap absolute device coordinates |
| `type "Email" "user@example.com"` | Focus the matched field, then type (append; no implicit clear) |
| `type "hello"` | Type into the currently focused field |
| `swipe 200 650 200 200 400` | Drag start→end over 400 ms; duration defaults to 400 |
| `key home` | `home`, `back` or `enter`; iOS does not have a system Back key |
| `launch "app.package"` | Activate an installed app by package/bundle ID |
| `stop "app.package"` | Terminate that app |
| `install "/absolute/path/app.apk"` | Install APK via ADB; .app directory via simctl; APK/IPA/ZIP via Appium |
| `wait 500` | Wait in milliseconds; maximum 60 seconds |
| `wait_for "Welcome" 10000` | Poll for a matching element, default timeout 10 seconds |
| `assert "Welcome"` | Fail unless a matching element is present |
| `assert_not "Error"` | Fail if a matching element is present or ambiguous |
| `extract greeting "welcome-label"` | Store its text (or label) as a named string |
| `screenshot "welcome"` | Save screenshot to the artifact directory |
| `run "login.mob"` | Include a saved test with shared parameters/values |
| `record_start` | Start native screen recording; requires device support |
| `record_stop "demo"` | Finalize and save an MP4 artifact |
| `measure_perf "app.package"` | Obtain supported metrics (currently direct Android ADB) |
| `assert_perf memory_mb < 220` | Compare an actually measured metric |
| `assert_perf jank_percent <= 5` | Assert cumulative Android graphics jank percentage |
| `assert_baseline "home" 0.01` | Compare PNG screenshot to an explicitly saved baseline; allow 1% changed pixels |

Parameters use `${name}` inside string arguments. Supply them as a JSON object at run time. Substitution happens **after** tokenization, so a parameter containing newlines or quotes cannot inject script commands. Extracted values can be used by later commands and included scripts. Numeric-coordinate parameters are not implemented; use JSON actions for computed coordinates.

`assert_baseline` uses Pixelmatch's per-pixel threshold `0.1`, then compares the changed pixel ratio against the command's threshold (default `0.01`). It never creates/updates a baseline implicitly. The baseline must have the exact same pixel dimensions as the device screenshot. Capture through `POST /api/v1/devices/:id/baseline` with `{"name":"home"}`. Review baseline updates yourself.

Screen dimensions returned by Appium are logical device coordinates, even when iOS screenshots contain more physical pixels. The UI handles that scale automatically. Direct ADB uses screenshot pixels.

Runs have a 10-minute deadline, at most 500 top-level commands, 1,000 expanded steps and 10 levels of includes. Cyclic includes fail. Scripts stop on the first failed step. Assertions and unavailable capabilities fail explicitly; there are no false success fallbacks. Cancelling a run aborts supported child commands/waits and does not enqueue subsequent actions. Device-side actions already dispatched may finish. In-progress recordings are finalized in run cleanup when possible.

Typed data is preserved in scripts/run evidence for reproducibility. Avoid committing real passwords or private device data. Parameter values also appear in local run evidence.
