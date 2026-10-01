# Example flow

A flow is a list of Mobdev tool calls saved as JSON. `smoke.json` installs the small app in
`fixture/`, launches it, finds its controls by accessibility identifier and label, types, checks
the result, opens a deep link and removes the app again. It uses no OCR, so it also runs on
GitHub's virtualized Macs, where Vision text recognition does not answer.

```sh
fixture/build.sh                                   # needs Xcode; no project, no signing team
xcrun simctl boot "iPhone 17"                      # or any booted simulator
/Applications/Mobdev.app/Contents/MacOS/Mobdev flow smoke.json --device "iPhone 17" --artifacts out
```

A path in `install_app` is relative to the flow file. `--artifacts` keeps a video of the run
(`run.mp4`), the activity log, crash reports and, after a failure, a screenshot of the screen it
failed on.
[`.github/workflows/flows.yml`](../../.github/workflows/flows.yml) runs this flow on every change
to the app and after every release. See "Flows and CI" in [`macos/README.md`](../../macos/README.md).
