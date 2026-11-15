#!/usr/bin/env bats
# Tests for lib/release.sh — no network, no real apps: every command is a stub, every path a temp dir.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home" "$T/app/Claude.app/Contents" "$T/state" "$T/zipcontent"
  export HOME="$T/home"
  export CLAUDES_APP_SRC="$T/app/Claude.app"
  export CLAUDES_STATE_DIR="$T/state"
  export CLAUDES_FEED_BASE="https://feed.test"
  export T
  export PATH="$T/bin:$PATH"
  # stub behaviour knobs (read by the stubs below)
  export STUB_OLD_ID=com.anthropic.claudefordesktop STUB_OLD_TEAM=Q6L2SF6YDW
  export STUB_NEW_ID=com.anthropic.claudefordesktop STUB_NEW_TEAM=Q6L2SF6YDW
  unset STUB_VERIFY_FAIL STUB_SPCTL_FAIL STUB_DITTO_FAIL STUB_CURL_FAIL STUB_SHA STUB_TWO_APPS
  source "$REPO/lib/common.sh"
  source "$REPO/lib/procs.sh"
  source "$REPO/lib/update_detect.sh"
  source "$REPO/lib/release.sh"
  mkbundle "$CLAUDES_APP_SRC" 5.11492.5
  NEWV=5.11500.1
  printf 'fake zip bytes' > "$T/fake.zip"
  ZIPSIZE="$(stat -f %z "$T/fake.zip")"
  SHA="a6f33df2aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  export SHA
  mkbundle "$T/zipcontent/Claude.app" "$NEWV"
  write_stubs
  set -euo pipefail   # the real script runs this way
}

# ---- helpers ----
mkbundle() { # dir version
  mkdir -p "$1/Contents"
  rm -f "$1/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $2" "$1/Contents/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $2" "$1/Contents/Info.plist" >/dev/null
}

write_stubs() {
  cat > "$T/bin/curl" <<'EOS'
#!/bin/bash
echo "$*" >> "$T/curl.log"
[ -z "${STUB_CURL_FAIL:-}" ] || exit 22
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift;; -A|--max-time|--proto) shift;; -*) ;; *) url="$1";; esac
  shift
done
case "$url" in
  */api/desktop/*) cp "$T/feed.json" "$out";;
  *) cp "$T/fake.zip" "$out";;
esac
EOS
  cat > "$T/bin/shasum" <<'EOS'
#!/bin/bash
echo "${STUB_SHA:-$SHA}  $3"
EOS
  cat > "$T/bin/ditto" <<'EOS'
#!/bin/bash
echo "$*" >> "$T/ditto.log"
[ -z "${STUB_DITTO_FAIL:-}" ] || exit 1
mkdir -p "$4"
cp -R "$T/zipcontent/." "$4/"
[ -z "${STUB_TWO_APPS:-}" ] || cp -R "$T/zipcontent/Claude.app" "$4/Other.app"
exit 0
EOS
  cat > "$T/bin/codesign" <<'EOS'
#!/bin/bash
case "$1" in
  --verify) [ -z "${STUB_VERIFY_FAIL:-}" ] || { echo "invalid signature" >&2; exit 1; }; exit 0;;
  -dv)
    if [ "$2" = "$CLAUDES_APP_SRC" ]; then id="$STUB_OLD_ID"; team="$STUB_OLD_TEAM"; else id="$STUB_NEW_ID"; team="$STUB_NEW_TEAM"; fi
    printf 'Executable=/x\nIdentifier=%s\n' "$id" >&2
    [ "$team" = none ] || printf 'TeamIdentifier=%s\n' "$team" >&2
    exit 0;;
esac
exit 9
EOS
  cat > "$T/bin/spctl" <<'EOS'
#!/bin/bash
[ -z "${STUB_SPCTL_FAIL:-}" ] || { echo "rejected" >&2; exit 3; }
exit 0
EOS
  cat > "$T/bin/xattr" <<'EOS'
#!/bin/bash
echo "$*" >> "$T/xattr.log"
exit 0
EOS
  cat > "$T/bin/uuidgen" <<'EOS'
#!/bin/bash
echo "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D"
EOS
  cat > "$T/bin/sw_vers" <<'EOS'
#!/bin/bash
[ "$1" = "-productVersion" ] && echo "26.6.2"
EOS
  chmod +x "$T/bin/"*
}

# the real feed answer shape (findings section 1), version overridable
mkfeed() { # [version] [url]
  local v="${1:-$NEWV}" u="${2:-https://downloads.claude.ai/releases/darwin/universal/${1:-$NEWV}/Claude-abc123.zip}"
  cat > "$T/feed.json" <<EOS
{"currentRelease":"$v","releases":[{"version":"$v","updateTo":{"name":"$v","version":"$v","pub_date":"2026-11-14T10:00:00.000Z","url":"$u","notes":"Bug fixes","sha256":"$SHA","size":$ZIPSIZE}}]}
EOS
}

# write the saved feed answer: checked version [first_seen]
mkcache() {
  mkdir -p "$T/state"
  printf 'checked\t%s\nversion\t%s\nurl\thttps://downloads.claude.ai/releases/darwin/universal/%s/Claude-abc123.zip\nsha256\t%s\nsize\t%s\nfirst_seen\t%s\n' \
    "$1" "$2" "$2" "$SHA" "$ZIPSIZE" "${3:-$1}" > "$T/state/release-check"
}

fresh_cache() { mkcache "$(date +%s)" "${1:-$NEWV}" "${2:-}"; }

curl_calls() { [ -f "$T/curl.log" ] && wc -l < "$T/curl.log" | tr -d ' ' || echo 0; }

assert_failed_clean() { # version : discarded, failure recorded, never ready
  [ ! -e "$T/state/ready" ]
  [ ! -e "$T/state/download/$1" ]
  [ "$(_rel_kv_get "$T/state/release-failed" version)" = "$1" ]
  [ -n "$(_rel_kv_get "$T/state/release-failed" reason)" ]
}

# ---- feed url ----
@test "feed url has a fresh lowercase uuid, installed version and macOS version, nothing else" {
  run release_feed_url
  [ "$status" -eq 0 ]
  [ "$output" = "https://feed.test/api/desktop/darwin/universal/squirrel/update?device_id=a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d&version=5.11492.5&os_version=26.6.2" ]
}

@test "feed url uses 0.0.0 when no app is installed" {
  rm -rf "$CLAUDES_APP_SRC"
  run release_feed_url
  [[ "$output" == *"&version=0.0.0&"* ]]
}

@test "feed url never contains the real device id from the data folder" {
  mkdir -p "$T/home/Library/Application Support/Claude"
  echo '{"deviceId":"REAL-DEVICE-ID"}' > "$T/home/Library/Application Support/Claude/config.json"
  run release_feed_url
  [[ "$output" != *REAL-DEVICE-ID* ]]
}

# ---- fetch and parse ----
@test "fetch parses the real response shape and writes release-check" {
  mkfeed 5.11492.5
  run release_fetch_feed
  [ "$status" -eq 0 ]
  f="$T/state/release-check"
  [ "$(_rel_kv_get "$f" version)" = "5.11492.5" ]
  [ "$(_rel_kv_get "$f" url)" = "https://downloads.claude.ai/releases/darwin/universal/5.11492.5/Claude-abc123.zip" ]
  [ "$(_rel_kv_get "$f" sha256)" = "$SHA" ]
  [ "$(_rel_kv_get "$f" size)" = "$ZIPSIZE" ]
  [ -n "$(_rel_kv_get "$f" checked)" ]
}

@test "fetch picks the release named by currentRelease among several" {
  cat > "$T/feed.json" <<EOS
{"currentRelease":"5.2.0","releases":[{"version":"5.1.0","updateTo":{"url":"https://downloads.claude.ai/a.zip","sha256":"11","size":1}},{"version":"5.2.0","updateTo":{"url":"https://downloads.claude.ai/b.zip","sha256":"22","size":2}}]}
EOS
  run release_fetch_feed
  [ "$status" -eq 0 ]
  [ "$(_rel_kv_get "$T/state/release-check" url)" = "https://downloads.claude.ai/b.zip" ]
  [ "$(_rel_kv_get "$T/state/release-check" sha256)" = "22" ]
}

@test "fetch refuses a download address outside downloads.claude.ai" {
  mkfeed "$NEWV" "https://evil.example.com/Claude.zip"
  run release_fetch_feed
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected download address"* ]]
  [ ! -e "$T/state/release-check" ]
}

@test "fetch refuses a lookalike host" {
  mkfeed "$NEWV" "https://downloads.claude.ai.evil.com/Claude.zip"
  run release_fetch_feed
  [ "$status" -eq 1 ]
}

@test "fetch fails plainly when the request fails" {
  export STUB_CURL_FAIL=1
  run release_fetch_feed
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not reach"* ]]
}

@test "fetch fails plainly when the answer is not understood" {
  echo 'not json at all' > "$T/feed.json"
  run release_fetch_feed
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not understand"* ]]
}

@test "fetch sends only https with the claudes user agent" {
  mkfeed
  release_fetch_feed
  grep -q -- '--proto =https' "$T/curl.log"
  grep -q -- '-A claudes-update-check' "$T/curl.log"
}

# ---- release_check ----
@test "release_check uses a young saved answer without asking" {
  fresh_cache 5.11500.1
  run release_check
  [ "$status" -eq 0 ]
  [ "$output" = "5.11500.1" ]
  [ "$(curl_calls)" = 0 ]
}

@test "release_check asks again when the saved answer is old" {
  mkcache "$(( $(date +%s) - 4000 ))" 5.11400.0
  mkfeed 5.11500.1
  run release_check
  [ "$status" -eq 0 ]
  [ "$output" = "5.11500.1" ]
  [ "$(curl_calls)" = 1 ]
}

@test "release_check --force asks even when the saved answer is young" {
  fresh_cache 5.11400.0
  mkfeed 5.11500.1
  run release_check --force
  [ "$output" = "5.11500.1" ]
  [ "$(curl_calls)" = 1 ]
}

@test "release_check fails when nothing is known and the request fails" {
  export STUB_CURL_FAIL=1
  run release_check
  [ "$status" -eq 1 ]
}

@test "first_seen survives a refresh that finds the same version" {
  mkcache "$(( $(date +%s) - 4000 ))" "$NEWV" 12345
  mkfeed "$NEWV"
  release_check >/dev/null
  [ "$(_rel_kv_get "$T/state/release-check" first_seen)" = "12345" ]
}

@test "first_seen restarts when a different version appears" {
  mkcache "$(( $(date +%s) - 4000 ))" 5.11400.0 12345
  mkfeed "$NEWV"
  release_check >/dev/null
  [ "$(_rel_kv_get "$T/state/release-check" first_seen)" != "12345" ]
}

# ---- release_is_newer ----
@test "release_is_newer true when the newest is greater than installed" {
  fresh_cache 5.11500.1
  run release_is_newer
  [ "$status" -eq 0 ]
}

@test "release_is_newer false when equal" {
  fresh_cache 5.11492.5
  run release_is_newer
  [ "$status" -eq 1 ]
}

@test "release_is_newer false when older" {
  fresh_cache 5.11400.0
  run release_is_newer
  [ "$status" -eq 1 ]
}

@test "release_is_newer false when nothing is known" {
  run release_is_newer
  [ "$status" -eq 1 ]
}

# ---- release_verify_app ----
@test "verify passes for a genuine newer app" {
  run release_verify_app "$T/zipcontent/Claude.app" "$NEWV"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "verify fails when the bundle is missing" {
  run release_verify_app "$T/nope/Claude.app" "$NEWV"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing"* ]]
}

@test "verify fails when codesign --verify fails" {
  export STUB_VERIFY_FAIL=1
  run release_verify_app "$T/zipcontent/Claude.app" "$NEWV"
  [ "$status" -eq 1 ]
  [[ "$output" == *"signature"* ]]
}

@test "verify fails on a different Team ID" {
  export STUB_NEW_TEAM=EVIL000000
  run release_verify_app "$T/zipcontent/Claude.app" "$NEWV"
  [ "$status" -eq 1 ]
  [[ "$output" == *"different developer"* ]]
}

@test "verify fails on a different bundle id" {
  export STUB_NEW_ID=com.evil.app
  run release_verify_app "$T/zipcontent/Claude.app" "$NEWV"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not the Claude app"* ]]
}

@test "verify fails when spctl rejects" {
  export STUB_SPCTL_FAIL=1
  run release_verify_app "$T/zipcontent/Claude.app" "$NEWV"
  [ "$status" -eq 1 ]
  [[ "$output" == *"safe, notarized"* ]]
}

@test "verify fails when the version is not the announced one" {
  run release_verify_app "$T/zipcontent/Claude.app" "5.99999.9"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not the 5.99999.9"* ]]
}

@test "verify fails when the app is not newer than installed" {
  mkbundle "$T/zipcontent/Claude.app" 5.11492.5
  run release_verify_app "$T/zipcontent/Claude.app" 5.11492.5
  [ "$status" -eq 1 ]
  [[ "$output" == *"not newer"* ]]
}

@test "verify uses CLAUDES_TEAM_ID when the installed app's team can't be read" {
  export STUB_OLD_TEAM=none
  run release_verify_app "$T/zipcontent/Claude.app" "$NEWV"
  [ "$status" -eq 0 ]
  export STUB_NEW_TEAM=EVIL000000
  run release_verify_app "$T/zipcontent/Claude.app" "$NEWV"
  [ "$status" -eq 1 ]
}

# ---- release_prepare ----
@test "prepare downloads, verifies and writes ready" {
  fresh_cache
  run release_prepare
  [ "$status" -eq 0 ]
  [ "$(release_ready_version)" = "$NEWV" ]
  [ "$(release_ready_app)" = "$T/state/download/$NEWV/app/Claude.app" ]
  [ -n "$(release_ready_get verified)" ]
  [ -n "$(release_ready_get first_seen)" ]
  [ ! -e "$T/state/release-failed" ]
  [ ! -e "$T/state/download/$NEWV/Claude.zip.part" ]
  grep -q -- '--proto =https' "$T/curl.log"
  grep -q 'com.apple.quarantine' "$T/xattr.log"
}

@test "prepare: wrong size is discarded and recorded" {
  fresh_cache
  sed -i '' "s/^size.*/size\t999/" "$T/state/release-check"
  run release_prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"wrong size"* ]]
  assert_failed_clean "$NEWV"
}

@test "prepare: checksum mismatch is discarded and recorded" {
  fresh_cache
  export STUB_SHA=deadbeef
  run release_prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"checksum"* ]]
  assert_failed_clean "$NEWV"
}

@test "prepare: a download that fails is recorded" {
  fresh_cache
  export STUB_CURL_FAIL=1
  run release_prepare
  [ "$status" -eq 1 ]
  assert_failed_clean "$NEWV"
}

@test "prepare: unzip failure is discarded and recorded" {
  fresh_cache
  export STUB_DITTO_FAIL=1
  run release_prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"unpacked"* ]]
  assert_failed_clean "$NEWV"
}

@test "prepare: two apps in the zip is discarded and recorded" {
  fresh_cache
  export STUB_TWO_APPS=1
  run release_prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"exactly one"* ]]
  assert_failed_clean "$NEWV"
}

@test "prepare: codesign failure is discarded and recorded" {
  fresh_cache
  export STUB_VERIFY_FAIL=1
  run release_prepare
  [ "$status" -eq 1 ]
  assert_failed_clean "$NEWV"
}

@test "prepare: wrong Team ID is discarded and recorded" {
  fresh_cache
  export STUB_NEW_TEAM=EVIL000000
  run release_prepare
  [ "$status" -eq 1 ]
  assert_failed_clean "$NEWV"
}

@test "prepare: wrong bundle id is discarded and recorded" {
  fresh_cache
  export STUB_NEW_ID=com.evil.app
  run release_prepare
  [ "$status" -eq 1 ]
  assert_failed_clean "$NEWV"
}

@test "prepare: spctl rejection is discarded and recorded" {
  fresh_cache
  export STUB_SPCTL_FAIL=1
  run release_prepare
  [ "$status" -eq 1 ]
  assert_failed_clean "$NEWV"
}

@test "prepare: version mismatch inside the app is discarded and recorded" {
  fresh_cache
  mkbundle "$T/zipcontent/Claude.app" 5.11500.9
  run release_prepare
  [ "$status" -eq 1 ]
  assert_failed_clean "$NEWV"
}

@test "prepare: an app that is not newer is discarded and recorded" {
  fresh_cache 5.11492.5
  mkbundle "$T/zipcontent/Claude.app" 5.11492.5
  run release_prepare
  [ "$status" -eq 1 ]
  [[ "$output" == *"not newer"* ]]
  assert_failed_clean 5.11492.5
}

@test "prepare: a failure removes an older ready file" {
  fresh_cache
  printf 'version\t%s\napp\t/x\n' "$NEWV" > "$T/state/ready"
  export STUB_VERIFY_FAIL=1
  run release_prepare
  [ "$status" -eq 1 ]
  [ ! -e "$T/state/ready" ]
}

@test "prepare: retry is blocked within 6 hours of a failure" {
  fresh_cache
  printf 'version\t%s\nreason\tbad\nat\t%s\n' "$NEWV" "$(( $(date +%s) - 3 * 3600 - 60 ))" > "$T/state/release-failed"
  run release_prepare
  [ "$status" -eq 1 ]
  [ "$output" = "this version failed its checks 3 hours ago; trying again later" ]
  [ "$(curl_calls)" = 0 ]
}

@test "prepare: retry is allowed after 6 hours" {
  fresh_cache
  printf 'version\t%s\nreason\tbad\nat\t%s\n' "$NEWV" "$(( $(date +%s) - 7 * 3600 ))" > "$T/state/release-failed"
  run release_prepare
  [ "$status" -eq 0 ]
  [ "$(release_ready_version)" = "$NEWV" ]
  [ ! -e "$T/state/release-failed" ]
}

@test "prepare: a failure for another version does not block this one" {
  fresh_cache
  printf 'version\t5.1.0\nreason\tbad\nat\t%s\n' "$(date +%s)" > "$T/state/release-failed"
  run release_prepare
  [ "$status" -eq 0 ]
}

@test "prepare: an already-ready verified update skips the download" {
  fresh_cache
  mkdir -p "$T/state/download/$NEWV/app"
  cp -R "$T/zipcontent/Claude.app" "$T/state/download/$NEWV/app/"
  printf 'version\t%s\napp\t%s\nverified\t1\nfirst_seen\t1\n' "$NEWV" "$T/state/download/$NEWV/app/Claude.app" > "$T/state/ready"
  run release_prepare
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" = 0 ]
  [ ! -e "$T/ditto.log" ]
}

@test "prepare: ready that no longer verifies is downloaded again and first_seen is kept" {
  fresh_cache
  printf 'version\t%s\napp\t%s\nverified\t1\nfirst_seen\t424242\n' "$NEWV" "$T/state/download/$NEWV/app/Claude.app" > "$T/state/ready"
  run release_prepare
  [ "$status" -eq 0 ]
  [ "$(curl_calls)" = 1 ]
  [ "$(release_ready_get first_seen)" = "424242" ]
}

@test "prepare: first_seen comes from release-check when there is no earlier ready" {
  fresh_cache "$NEWV" 777
  run release_prepare
  [ "$status" -eq 0 ]
  [ "$(release_ready_get first_seen)" = "777" ]
}

@test "prepare: other versions' download folders are deleted" {
  fresh_cache
  mkdir -p "$T/state/download/5.0.0/app"
  run release_prepare
  [ "$status" -eq 0 ]
  [ ! -e "$T/state/download/5.0.0" ]
  [ -d "$T/state/download/$NEWV" ]
}

@test "prepare works when the state folder path has a space" {
  export CLAUDES_STATE_DIR="$T/Application Support/claudes"
  mkdir -p "$CLAUDES_STATE_DIR"
  mkcache "$(date +%s)" "$NEWV"
  mv "$T/state/release-check" "$CLAUDES_STATE_DIR/release-check"
  run release_prepare
  [ "$status" -eq 0 ]
  [ -d "$CLAUDES_STATE_DIR/download/$NEWV/app/Claude.app" ]
}

# ---- ready helpers ----
@test "ready helpers report missing when there is no ready file" {
  run release_ready_version
  [ "$status" -eq 1 ]
  run release_ready_app
  [ "$status" -eq 1 ]
  run release_ready_get version
  [ "$status" -eq 1 ]
}

@test "release_ready_app fails when the app folder is gone" {
  printf 'version\t1\napp\t%s\n' "$T/gone/Claude.app" > "$T/state/ready"
  run release_ready_app
  [ "$status" -eq 1 ]
  [ "$(release_ready_version)" = "1" ]
}

@test "release_ready_set adds and replaces a key and keeps the others" {
  printf 'version\t1\nnotified\t5\n' > "$T/state/ready"
  release_ready_set notified 9
  release_ready_set extra x
  [ "$(release_ready_get version)" = "1" ]
  [ "$(release_ready_get notified)" = "9" ]
  [ "$(release_ready_get extra)" = "x" ]
  [ "$(grep -c '^notified' "$T/state/ready")" = 1 ]
  [ -z "$(ls "$T/state" | grep tmp || true)" ]
}

@test "release_discard removes ready and the download folder" {
  mkdir -p "$T/state/download/1/app"
  printf 'version\t1\n' > "$T/state/ready"
  release_discard
  [ ! -e "$T/state/ready" ]
  [ ! -e "$T/state/download" ]
}

@test "release_discard is fine when there is nothing to remove" {
  run release_discard
  [ "$status" -eq 0 ]
}
