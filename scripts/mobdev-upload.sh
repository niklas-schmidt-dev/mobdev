#!/bin/sh
# Sends a build to a Mac running Mobdev, so install_app can install it on that Mac's iPhone,
# simulator or Android device. For cloud agents and CI that build in a container: it needs only a
# POSIX shell, curl, and sha256sum or shasum. Same protocol as `Mobdev upload`.
#
#   export MOBDEV_URL=https://relay.mobdev.sh/h/<mac-name>   # or your own relay, or a Mac's HTTP API
#   export MOBDEV_KEY=mdc_...                                # the client key the Mac shows
#   id=$(sh scripts/mobdev-upload.sh app/build/outputs/apk/debug/app-debug.apk)
#   curl -sS -H "Authorization: Bearer $MOBDEV_KEY" -H 'Content-Type: application/json' \
#     -d "{\"upload\": \"$id\"}" "$MOBDEV_URL/v1/tools/install_app"
#
# Takes an .ipa, an .apk, a zipped .app, or an .app folder, which it zips with ditto or zip. Prints
# the upload's id (with --json the finished upload). The file goes in chunks of up to 8 MiB
# (MOBDEV_CHUNK_SIZE sends smaller ones, for slow connections); a chunk that fails is sent again
# from where the Mac's copy ends. Relays forward the chunks and store nothing. Exit status: 0
# uploaded, 1 refused or failed, 2 wrong usage.
set -eu

usage() {
    cat >&2 <<'EOF'
Usage: mobdev-upload.sh [--url URL] [--key KEY] [--json] <file>
  --url   the relay URL with the Mac's name, e.g. https://relay.mobdev.sh/h/studio (or MOBDEV_URL)
  --key   the relay's client key, mdc_... (or MOBDEV_KEY, which ps cannot show)
  --json  print the finished upload as JSON instead of its id
EOF
}

say() { printf '%s\n' "$*" >&2; }
die() { say "mobdev-upload: $*"; exit 1; }

url=${MOBDEV_URL:-}
key=${MOBDEV_KEY:-}
json=false
file=
while [ $# -gt 0 ]; do
    case $1 in
        --url) [ $# -ge 2 ] || { usage; exit 2; }; url=$2; shift 2 ;;
        --key) [ $# -ge 2 ] || { usage; exit 2; }; key=$2; shift 2 ;;
        --json) json=true; shift ;;
        -h | --help) usage; exit 0 ;;
        -*) say "Unknown option $1"; usage; exit 2 ;;
        *) [ -z "$file" ] || { say "Upload one file at a time."; exit 2; }; file=$1; shift ;;
    esac
done
[ -n "$file" ] || { usage; exit 2; }
[ -n "$url" ] || { say "Set MOBDEV_URL or pass --url, e.g. https://relay.mobdev.sh/h/<mac-name>."; exit 2; }
[ -n "$key" ] || { say "Set MOBDEV_KEY or pass --key with the client key (mdc_...)."; exit 2; }
command -v curl >/dev/null 2>&1 || die "needs curl"
url=${url%/}

umask 077
tmp=$(mktemp -d "${TMPDIR:-/tmp}/mobdev-upload.XXXXXX") || die "cannot create a temporary folder"
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT TERM
# The key goes to curl in a file, so it never shows in the process list.
printf 'Authorization: Bearer %s\n' "$key" >"$tmp/auth"

# An .app folder is zipped first, keeping symlinks and permissions.
if [ -d "$file" ]; then
    case $file in
        *.app | *.app/) ;;
        *) die "$file is a folder; send an .app folder, an .ipa, an .apk or a zipped .app" ;;
    esac
    app=${file%/}
    zip="$tmp/$(basename "$app").zip"
    if command -v ditto >/dev/null 2>&1; then
        ditto -c -k --norsrc --noextattr --noacl --keepParent "$app" "$zip" || die "could not zip $app"
    elif command -v zip >/dev/null 2>&1; then
        (cd "$(dirname "$app")" && zip -qry "$zip" "$(basename "$app")") || die "could not zip $app"
    else
        die "zipping $app needs ditto or zip; or zip it yourself and send the .zip"
    fi
    file=$zip
fi
[ -f "$file" ] || die "$file does not exist"
case $file in
    *.[iI][pP][aA] | *.[aA][pP][kK] | *.[zZ][iI][pP]) ;;
    *) die "$(basename "$file") is not a build; send an .ipa, an .apk, a zipped .app or an .app folder" ;;
esac

# The Mac keeps a safe version of the name; the script only keeps the JSON valid.
name=$(basename "$file")
name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._+()-' '_')
size=$(wc -c <"$file" | tr -d ' ')
if command -v sha256sum >/dev/null 2>&1; then
    sha=$(sha256sum "$file" | cut -d ' ' -f 1)
elif command -v shasum >/dev/null 2>&1; then
    sha=$(shasum -a 256 "$file" | cut -d ' ' -f 1)
else
    die "needs sha256sum or shasum"
fi

# request METHOD PATH [FILE CONTENT-TYPE]: the answer's body goes to $tmp/body, its status to
# $status (000 when there was none).
request() {
    set -- "$1" "$2" "${3:-}" "${4:-}"
    if [ -n "$3" ]; then
        status=$(curl -sS -o "$tmp/body" -w '%{http_code}' -X "$1" -H "@$tmp/auth" -H "Content-Type: $4" \
            --data-binary "@$3" --connect-timeout 20 --max-time 150 "$url$2" 2>"$tmp/error") || status=000
    else
        status=$(curl -sS -o "$tmp/body" -w '%{http_code}' -X "$1" -H "@$tmp/auth" \
            --connect-timeout 20 --max-time 150 "$url$2" 2>"$tmp/error") || status=000
    fi
    [ -f "$tmp/body" ] || : >"$tmp/body"
}

# Fields of the Mac's answer, which is one line of compact JSON. Escaped quotes in a string, as in
# an error message, are set aside first and put back afterwards.
string_field() {
    sed -n 's/\\"/@q@/g; s/.*"'"$1"'":"\([^"]*\)".*/\1/p' "$tmp/body" | sed 's/@q@/"/g; s/\\\\/\\/g' | head -n 1
}
number_field() { sed -n 's/.*"'"$1"'":\([0-9][0-9]*\).*/\1/p' "$tmp/body" | head -n 1; }
# The start of a file, on one line.
start_of() { dd if="$1" bs=300 count=1 2>/dev/null | tr '\n' ' '; }

reason() {
    message=$(string_field error)
    if [ "$status" = 000 ]; then
        printf 'no answer: %s' "$(start_of "$tmp/error")"
    elif [ -n "$message" ]; then
        printf '%s (HTTP %s)' "$message" "$status"
    else
        printf 'HTTP %s: %s' "$status" "$(start_of "$tmp/body")"
    fi
}

retryable() {
    case $status in 000 | 408 | 425 | 429 | 500 | 502 | 503 | 504) return 0 ;; *) return 1 ;; esac
}

failures=0
# Waits a little longer after each failure, and gives up after eight.
backoff() {
    failures=$((failures + 1))
    [ "$failures" -lt 8 ] || die "gave up after 8 tries: $(reason)"
    say "  $(reason); trying again..."
    delay=$((1 << (failures - 1)))
    [ "$delay" -le 15 ] || delay=15
    sleep "$delay"
}

# call METHOD PATH EXPECTED [FILE CONTENT-TYPE]: asks again while there is no answer or the relay is
# busy. Creating, asking and finishing can be repeated: a finish that outlasted the relay's 90 s
# goes on on the Mac, and asking again waits for it.
call() {
    failures=0
    while :; do
        request "$1" "$2" "${4:-}" "${5:-}"
        [ "$status" != "$3" ] || return 0
        retryable || die "$(reason)"
        backoff
    done
}

say "Uploading $name, $size bytes..."
printf '{"name":"%s","size":%s,"sha256":"%s"}' "$name" "$size" "$sha" >"$tmp/create.json"
call POST /v1/uploads 201 "$tmp/create.json" application/json
id=$(string_field id)
[ -n "$id" ] || die "the Mac sent no upload id: $(start_of "$tmp/body")"
chunk=$(number_field chunk_size)
[ -n "$chunk" ] && [ "$chunk" -gt 0 ] || chunk=8388608
if [ -n "${MOBDEV_CHUNK_SIZE:-}" ] && [ "$MOBDEV_CHUNK_SIZE" -gt 0 ] && [ "$MOBDEV_CHUNK_SIZE" -lt "$chunk" ]; then
    chunk=$MOBDEV_CHUNK_SIZE
fi
offset=$(number_field received)
[ -n "$offset" ] || offset=0

# The largest power of two up to 1 MiB that divides $1, so dd can seek in whole blocks.
block() {
    b=1
    while [ "$b" -lt 1048576 ] && [ $(($1 % (b * 2))) -eq 0 ]; do b=$((b * 2)); done
    echo "$b"
}

# After a chunk failed: wait, then continue from what the Mac has.
resume() {
    backoff
    saved=$failures
    call GET "/v1/uploads/$id" 200
    failures=$saved
    offset=$(number_field received)
    [ -n "$offset" ] || die "the Mac did not say how much it has: $(start_of "$tmp/body")"
}

failures=0
shown=-1
while [ "$offset" -lt "$size" ]; do
    length=$((size - offset))
    [ "$length" -le "$chunk" ] || length=$chunk
    if [ $((offset + length)) -ge "$size" ]; then
        b=$(block "$offset") # The last chunk: dd stops at the end of the file.
    else
        b=$(block $((offset | length)))
    fi
    dd if="$file" of="$tmp/chunk" bs="$b" skip=$((offset / b)) count=$(((length + b - 1) / b)) 2>/dev/null ||
        die "could not read $file"
    [ "$(wc -c <"$tmp/chunk" | tr -d ' ')" -eq "$length" ] || die "$file changed while it was being uploaded"
    request PUT "/v1/uploads/$id?offset=$offset" "$tmp/chunk" application/octet-stream
    case $status in
        200)
            offset=$(number_field received)
            [ -n "$offset" ] || die "the Mac did not say how much it has: $(start_of "$tmp/body")"
            failures=0
            percent=$((offset * 100 / size))
            if [ $((percent / 10)) -ne $((shown / 10)) ]; then
                shown=$percent
                say "  $offset of $size bytes ($percent %)"
            fi
            ;;
        409)
            # The Mac has more or less than this chunk assumed, e.g. after an answer got lost.
            next=$(number_field received)
            [ -n "$next" ] || die "$(reason)"
            offset=$next
            ;;
        *)
            retryable || die "$(reason)"
            # Too slow for the relay (it wants a request within 30 s): smaller chunks from now on.
            if { [ "$status" = 000 ] || [ "$status" = 408 ]; } && [ "$chunk" -gt 1048576 ]; then
                chunk=$((chunk / 2))
                [ "$chunk" -ge 1048576 ] || chunk=1048576
            fi
            resume
            ;;
    esac
done

say "Finishing: the Mac checks the SHA-256 and unpacks a zipped app..."
: >"$tmp/empty"
call POST "/v1/uploads/$id/finish" 200 "$tmp/empty" application/json
say "Uploaded $name. Install it with install_app {\"upload\": \"$id\"}."
if [ "$json" = true ]; then
    cat "$tmp/body"
    echo
else
    printf '%s\n' "$id"
fi
