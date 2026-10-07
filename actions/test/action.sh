#!/bin/bash
# The steps of the Mobdev GitHub Action (action.yml), one command each:
#   prepare    checks the inputs, picks the artifacts directory, finds or downloads Mobdev
#   simulator  creates and boots a simulator, or boots the one given
#   install    installs the app on it
#   run        runs Mobdev test or Mobdev flow and records its exit code
#   summary    appends summary.md and a link to the run to the job summary
#   comment    posts the same as a pull request comment, or updates the earlier one
#   cleanup    deletes the simulator the action created and ejects the DMG
#   finish     exits with Mobdev's exit code
# Inputs arrive as INPUT_* environment variables and earlier steps' outputs as plain ones, so no
# input ever becomes part of a script. Outputs go to $GITHUB_OUTPUT.
set -euo pipefail

# Releases come from here, whichever repository uses the action.
readonly RELEASES="https://github.com/niklas-schmidt-dev/mobdev/releases"

fail() {
  echo "::error title=Mobdev::$*"
  exit 1
}

output() {
  echo "$1=$2" >> "$GITHUB_OUTPUT"
}

# The non-empty lines of $1, without surrounding spaces.
lines() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -n "$line" ]]; then printf '%s\n' "$line"; fi
  done <<< "$1"
}

absolute() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$PWD/$1" ;;
  esac
}

step_prepare() {
  [[ "$(uname -s)" == Darwin ]] || fail "Mobdev needs a macOS runner, such as runs-on: macos-26."
  local project="${INPUT_PROJECT:-}" flow="${INPUT_FLOW:-}"
  if [[ -n "$project" && -n "$flow" ]] || [[ -z "$project" && -z "$flow" ]]; then
    fail "Set either project (a folder for Mobdev test) or flow (a file for Mobdev flow)."
  fi
  if [[ -n "$project" ]]; then
    [[ -e "$project" ]] || fail "project $project does not exist."
  else
    [[ -f "$flow" ]] || fail "flow $flow is not a file."
    if [[ -n "${INPUT_TESTS:-}" || -n "${INPUT_VARIABLES:-}" || -n "${INPUT_LANGUAGES:-}" ]]; then
      fail "tests, variables and languages work with project only."
    fi
  fi
  local variable
  while IFS= read -r variable; do
    # Not printed: the value may be a secret.
    [[ "$variable" == *=* ]] || fail "variables takes one NAME=value per line, and one line has no =."
  done < <(lines "${INPUT_VARIABLES:-}")

  local artifacts="${INPUT_ARTIFACTS:-}"
  if [[ -z "$artifacts" ]]; then artifacts="$RUNNER_TEMP/${INPUT_ARTIFACT_NAME:-mobdev-results}"; fi
  artifacts="$(absolute "$artifacts")"
  mkdir -p "$artifacts"
  output artifacts "$artifacts"

  local mobdev
  if [[ -n "${INPUT_MOBDEV:-}" ]]; then
    mobdev="$(absolute "$INPUT_MOBDEV")"
    [[ -f "$mobdev" && -x "$mobdev" ]] || fail "mobdev $INPUT_MOBDEV is not an executable file."
    echo "Using $mobdev"
  else
    local version="${INPUT_VERSION:-latest}" url work
    version="${version#mac-v}"
    version="${version#v}"
    if [[ "$version" == latest ]]; then
      url="$RELEASES/latest/download/Mobdev.dmg"
    elif [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
      url="$RELEASES/download/mac-v$version/Mobdev.dmg"
    else
      fail "version must be latest or a release such as 0.2.27."
    fi
    work="$(mktemp -d "$RUNNER_TEMP/mobdev-dmg.XXXXXX")"
    echo "Downloading $url"
    curl -fsSL --retry 3 -o "$work/Mobdev.dmg" "$url" || fail "Could not download $url. Is $version a Mobdev release?"
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$work/mount" "$work/Mobdev.dmg"
    output mount "$work/mount"
    mobdev="$work/mount/Mobdev.app/Contents/MacOS/Mobdev"
    [[ -x "$mobdev" ]] || fail "The DMG from $url has no Mobdev.app."
    echo "Mobdev $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$work/mount/Mobdev.app/Contents/Info.plist")"
  fi
  output mobdev "$mobdev"
}

step_simulator() {
  local udid
  if [[ -n "${INPUT_SIMULATOR:-}" ]]; then
    udid="$INPUT_SIMULATOR"
    local state
    state="$(xcrun simctl list devices --json | jq -r --arg udid "$udid" \
      '[.devices[][] | select(.udid == $udid) | .state] | first // empty')"
    [[ -n "$state" ]] || fail "There is no simulator $udid; xcrun simctl list devices lists them."
    output udid "$udid"
    output created false
    echo "Using simulator $udid ($state)"
    boot "$udid"
    return
  fi

  # The newest iOS runtime, or the one asked for by identifier, name or version.
  local runtime
  runtime="$(xcrun simctl list runtimes available --json | jq -r --arg wanted "${INPUT_RUNTIME:-}" '
    [.runtimes[] | select(.isAvailable != false and ((.platform // "") == "iOS" or (.name | startswith("iOS "))))]
    | if $wanted == "" then sort_by(.version | split(".") | map(tonumber? // 0)) | last
      else map(select(.identifier == $wanted or .name == $wanted or .version == $wanted)) | first end
    | .identifier // empty')"
  if [[ -z "$runtime" ]]; then
    xcrun simctl list runtimes available || true
    if [[ -n "${INPUT_RUNTIME:-}" ]]; then fail "No installed iOS runtime matches runtime $INPUT_RUNTIME."; fi
    fail "No iOS simulator runtime is installed."
  fi
  local device="${INPUT_DEVICE:-iPhone 17}"
  if ! udid="$(xcrun simctl create "Mobdev action" "$device" "$runtime")"; then
    xcrun simctl list devicetypes || true
    fail "Could not create a simulator of type \"$device\" with $runtime."
  fi
  # Recorded before booting, so the cleanup deletes it even when the boot fails.
  output udid "$udid"
  output created true
  echo "Created $device ($runtime): $udid"
  boot "$udid"
}

# Boots the simulator if needed and waits until it is ready, with simctl's progress folded away
# in the log.
boot() {
  echo "::group::Booting $1"
  local status=0
  xcrun simctl bootstatus "$1" -b || status=$?
  if [[ "$status" != 0 ]]; then
    # A busy Mac sometimes fails a boot ("launchd failed to respond"); the next one works.
    echo "The boot failed; trying once more."
    xcrun simctl shutdown "$1" 2> /dev/null || true
    status=0
    xcrun simctl bootstatus "$1" -b || status=$?
  fi
  echo "::endgroup::"
  [[ "$status" == 0 ]] || fail "Simulator $1 did not boot."
}

step_install() {
  local app
  app="$(absolute "$INPUT_APP")"
  [[ -d "$app" ]] || fail "app $INPUT_APP is not a .app folder."
  echo "Installing $app"
  xcrun simctl install "$UDID" "$app"
}

step_run() {
  local args=() item
  if [[ -n "${INPUT_PROJECT:-}" ]]; then
    args=(test "$INPUT_PROJECT")
    while IFS= read -r item; do args+=(--test "$item"); done < <(lines "${INPUT_TESTS:-}")
    while IFS= read -r item; do args+=(--var "$item"); done < <(lines "${INPUT_VARIABLES:-}")
    while IFS= read -r item; do args+=(--language "$item"); done < <(lines "${INPUT_LANGUAGES:-}")
  else
    args=(flow "$INPUT_FLOW")
  fi
  args+=(--device "$UDID" --artifacts "$ARTIFACTS")
  # A summary left from an earlier run in the same folder must not stand in for this one.
  rm -f "$ARTIFACTS/summary.md"
  local code=0
  "$MOBDEV_PATH" "${args[@]}" || code=$?
  output exit-code "$code"
  if [[ "$code" == 0 ]]; then output passed true; else output passed false; fi
}

# summary.md, or why there is none, and where the videos and logs are.
report() {
  local summary="${ARTIFACTS:-}/summary.md"
  if [[ -n "${ARTIFACTS:-}" && -f "$summary" ]]; then
    cat "$summary"
  elif [[ -z "${EXIT_CODE:-}" ]]; then
    printf '### ❌ Mobdev did not run\n\nAn earlier step of the action failed; its log says why.\n'
  else
    printf '### ❌ Mobdev could not run\n\nIt exited with code %s before writing results; the log of the step "Run Mobdev" says why.\n' "$EXIT_CODE"
  fi
  local run="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  if [[ -n "${INPUT_ARTIFACT_NAME:-}" ]]; then
    # Markdown backticks, not a command substitution:
    # shellcheck disable=SC2016
    printf '\nVideos, screenshots and logs: artifact `%s` of [this run](%s).\n' "$INPUT_ARTIFACT_NAME" "$run"
  else
    printf '\n[The run](%s)\n' "$run"
  fi
}

step_summary() {
  report >> "$GITHUB_STEP_SUMMARY"
}

step_comment() {
  local pr
  pr="$(jq -r '.pull_request.number // empty' "${GITHUB_EVENT_PATH:-/dev/null}" 2>/dev/null || true)"
  if [[ -z "$pr" ]]; then
    echo "::notice title=Mobdev::comment: true needs a pull request event; ${GITHUB_EVENT_NAME:-this event} has none, so there is no comment."
    return
  fi
  # One comment per job and artifact, found again by this marker on the next run.
  local key="${GITHUB_JOB:-job}/${INPUT_ARTIFACT_NAME:-mobdev}"
  while [[ "$key" == *--* ]]; do key="${key//--/-}"; done
  local marker="<!-- mobdev-action $key -->"
  local body payload existing
  body="$(mktemp "$RUNNER_TEMP/mobdev-comment.XXXXXX")"
  { echo "$marker"; report; } > "$body"
  payload="$(jq -n --rawfile body "$body" '{body: $body}')"
  rm -f "$body"
  local repo="$GITHUB_REPOSITORY"
  local failed="Could not comment on pull request #$pr. The job needs permissions: pull-requests: write; pull requests from forks get a read-only token."
  if ! existing="$(gh api --paginate "repos/$repo/issues/$pr/comments" \
    | jq -rs --arg marker "$marker" '[.[][] | select(.body | contains($marker)) | .id] | first // empty')"; then
    echo "::warning title=Mobdev::$failed"
    return
  fi
  if [[ -n "$existing" ]]; then
    if gh api --method PATCH "repos/$repo/issues/comments/$existing" --input - <<< "$payload" > /dev/null; then
      echo "Updated the comment on pull request #$pr."
    else
      echo "::warning title=Mobdev::$failed"
    fi
  elif gh api --method POST "repos/$repo/issues/$pr/comments" --input - <<< "$payload" > /dev/null; then
    echo "Commented on pull request #$pr."
  else
    echo "::warning title=Mobdev::$failed"
  fi
}

step_cleanup() {
  if [[ "${CREATED:-}" == true && -n "${UDID:-}" ]]; then
    echo "Deleting simulator $UDID"
    xcrun simctl shutdown "$UDID" 2> /dev/null || true
    xcrun simctl delete "$UDID" || echo "::warning title=Mobdev::Could not delete simulator $UDID."
  fi
  if [[ -n "${MOUNT:-}" && -d "$MOUNT" ]]; then
    hdiutil detach -quiet "$MOUNT" || hdiutil detach -quiet -force "$MOUNT" || true
  fi
}

step_finish() {
  [[ -n "${EXIT_CODE:-}" ]] || fail "Mobdev did not run."
  case "$EXIT_CODE" in
    0) ;;
    1) echo "::error title=Mobdev::A test or step failed; the job summary shows which." ;;
    2) echo "::error title=Mobdev::Mobdev could not start the run; the log of the step \"Run Mobdev\" says why." ;;
    *) echo "::error title=Mobdev::Mobdev exited with code $EXIT_CODE." ;;
  esac
  exit "$EXIT_CODE"
}

case "${1:-}" in
  prepare | simulator | install | run | summary | comment | cleanup | finish) "step_$1" ;;
  *) fail "Unknown step ${1:-}." ;;
esac
