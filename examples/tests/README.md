# Example test project

A project is a folder with `tests/*.json` and a `mobdev.json` naming the app. This one tests the
small app in [`../flows/fixture`](../flows/fixture): `mobdev.json` says which build to install
on a simulator and that every test starts with a fresh launch, and each file in `tests/` is one
test, a list of Mobdev tool calls ending in a check. It uses no OCR, so it also runs on GitHub's
virtualized Macs.

```sh
../flows/fixture/build.sh                           # needs Xcode; no project, no signing team
xcrun simctl boot "iPhone 17"                       # or any booted simulator
/Applications/Mobdev.app/Contents/MacOS/Mobdev test . --device "iPhone 17" --artifacts out
```

The Mobdev app runs the same project under **Tests** (open this folder), and agents through
`list_tests`, `save_test`, `run_tests` and `test_result`. `--artifacts` keeps `results.json`,
`junit.xml`, a video of every test and a screenshot of each failure.
[`.github/workflows/flows.yml`](../../.github/workflows/flows.yml) runs it on every change to the
app and after every release. See "Tests" in [`macos/README.md`](../../macos/README.md).
