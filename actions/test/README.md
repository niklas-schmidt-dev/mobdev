# Mobdev GitHub Action

Runs a Mobdev test project (`Mobdev test`) or a flow (`Mobdev flow`) on an iOS simulator on a
GitHub-hosted Mac. The results go into the job summary as a table and, if you want, into a pull
request comment; the videos, failure screenshots, `junit.xml` and logs are uploaded as an artifact.

```yaml
- uses: niklas-schmidt-dev/mobdev/actions/test@main
  with:
    project: mobdev
```

The action:

1. downloads the Mobdev release DMG (or uses the binary in `mobdev`),
2. creates a simulator of type `device` with the newest iOS runtime, and boots it (or boots the
   one in `simulator`),
3. installs `app` if given,
4. runs `Mobdev test <project>` or `Mobdev flow <flow>` with `--artifacts`,
5. appends `summary.md` and a link to the run to the job summary,
6. uploads the artifacts directory and, with `comment: true`, posts the summary on the pull request
   (updating its own comment on later runs),
7. deletes the simulator it created, and fails the step when a test or step failed.

**iOS only.** Mobdev runs on macOS, and GitHub's macOS runners cannot run Android emulators well.
For Android, run `Mobdev test` on a Mac of your own (a self-hosted runner) with an emulator booted.

## Tests on every pull request

A project is a folder with `mobdev.json` and `tests/*.json` (see "Tests" in
[`macos/README.md`](../../macos/README.md)); `builds.simulator` in `mobdev.json` names the build
the run installs.

```yaml
name: UI tests
on: [pull_request]

jobs:
  ui-tests:
    runs-on: macos-26
    permissions:
      contents: read
      pull-requests: write # only for comment: true
    steps:
      - uses: actions/checkout@v4
      - name: Build for the simulator
        run: |
          xcodebuild -scheme MyApp -destination 'generic/platform=iOS Simulator' \
            -derivedDataPath build build
      - uses: niklas-schmidt-dev/mobdev/actions/test@main
        with:
          project: mobdev
          comment: true
        env:
          PASSWORD: ${{ secrets.TEST_PASSWORD }} # a secret named in mobdev.json
```

## A flow

```yaml
- uses: niklas-schmidt-dev/mobdev/actions/test@main
  with:
    flow: flows/sign-in.json
    app: build/Build/Products/Debug-iphonesimulator/MyApp.app
    device: iPhone 17 Pro
```

## Several devices

`artifact-name` must differ per job, and it also keeps each job's pull request comment apart.

```yaml
jobs:
  ui-tests:
    runs-on: macos-26
    strategy:
      fail-fast: false
      matrix:
        device: ["iPhone 17", "iPhone 17 Pro Max"]
    steps:
      - uses: actions/checkout@v4
      - run: xcodebuild -scheme MyApp -destination 'generic/platform=iOS Simulator' -derivedDataPath build build
      - uses: niklas-schmidt-dev/mobdev/actions/test@main
        with:
          project: mobdev
          device: ${{ matrix.device }}
          artifact-name: mobdev-${{ matrix.device }}
```

## Inputs

| Input | Default | |
|---|---|---|
| `project` | | Folder with `mobdev.json` and `tests/`, run with `Mobdev test`. Set `project` or `flow` |
| `flow` | | A flow file, run with `Mobdev flow` |
| `device` | `iPhone 17` | Device type of the simulator the action creates (`xcrun simctl list devicetypes`) |
| `runtime` | newest iOS | `iOS 27.0`, `27.0` or `com.apple.CoreSimulator.SimRuntime.iOS-27-0` |
| `simulator` | | UDID of a simulator to use instead; booted if needed and left as it is |
| `app` | | A simulator `.app` to install first, for flows or projects without `builds.simulator` |
| `tests` | all | Tests to run, one per line: file name without `.json`, or the test's name. Projects only |
| `variables` | | `NAME=value` lines for `${NAME}` in the steps. Projects only |
| `languages` | | Run the tests once per language, one per line, e.g. `de-DE`; steps see it as `${LANGUAGE}`. With more than one, each gets its own folder in the artifacts. Projects only |
| `version` | `latest` | Mobdev release to download, e.g. `0.2.35` |
| `mobdev` | | Path to a Mobdev binary instead of a release, e.g. `macos/.build/debug/Mobdev` |
| `artifacts` | `$RUNNER_TEMP/<artifact-name>` | Where Mobdev writes its results |
| `artifact-name` | `mobdev-results` | Name of the uploaded artifact; empty skips the upload |
| `comment` | `false` | `true` comments on the pull request; needs `pull-requests: write` |
| `github-token` | `github.token` | Token for the comment |

## Outputs

| Output | |
|---|---|
| `passed` | `true` when every test or step passed, else `false` |
| `results` | The artifacts directory: `summary.md`, and for projects `results.json` and `junit.xml` |

For example, a test reporter step with `if: always()` can read
`${{ steps.mobdev.outputs.results }}/junit.xml` when the action's step has `id: mobdev`.

## Notes

- **Secrets:** put them in `env:` on the step and list their names under `secrets` in
  `mobdev.json`; Mobdev reads them from the environment and keeps them out of every result.
  `variables` are passed on Mobdev's command line, so use them for plain values.
- **Text recognition:** Vision does not answer on GitHub's virtualized Macs, so tests there should
  use `tap_element` and `wait_for_element` (the UI tree) rather than `tap_text`, `wait_for_text`
  and `read_screen`.
- **Xcode:** the action uses the runner's selected Xcode and its newest iOS runtime. To use
  another, select it in a step before: `sudo xcode-select -s /Applications/Xcode_27.0.app`.
- **Pull requests from forks** get a read-only token, so `comment: true` only warns there; the
  job summary still has the results.
- **Versions:** `@main` follows this repository. Pin a commit SHA for a fixed version of the
  action, and `version` for a fixed Mobdev.
- Inputs reach the action's scripts as environment variables, never as script text, so a branch
  name or test name cannot inject commands. The steps are in [`action.sh`](action.sh).
