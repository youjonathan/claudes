#!/bin/bash
# lib/release.sh — find, download and verify the newest Claude release ourselves. Source, do not execute.
# Needs _version_gt, _plist_raw and installed_build from lib/update_detect.sh.

CLAUDES_APP_SRC="${CLAUDES_APP_SRC:-/Applications/Claude.app}"
CLAUDES_BASE_ID="${CLAUDES_BASE_ID:-com.anthropic.claudefordesktop}"
CLAUDES_STATE_DIR="${CLAUDES_STATE_DIR:-$HOME/Library/Application Support/claudes}"
CLAUDES_FEED_BASE="${CLAUDES_FEED_BASE:-https://api.anthropic.com}"
CLAUDES_RELEASE_CHECK_EVERY="${CLAUDES_RELEASE_CHECK_EVERY:-3600}"
CLAUDES_RETRY_FAILED="${CLAUDES_RETRY_FAILED:-21600}"
CLAUDES_TEAM_ID="${CLAUDES_TEAM_ID:-Q6L2SF6YDW}"   # used only if the installed app's Team ID can't be read

# -> epoch seconds (claudes_now when procs.sh is loaded)
_rel_now() { if declare -F claudes_now >/dev/null 2>&1; then claudes_now; else date +%s; fi; }

# -> installed CFBundleVersion, or 0 when it can't be read (error text from PlistBuddy is not a version)
_rel_installed_build() {
  local ib
  ib="$(installed_build 2>/dev/null || true)"
  case "$ib" in ''|*[!0-9.]*) ib="0";; esac
  printf '%s\n' "$ib"
}

# FILE KEY -> value of KEY from a KEY<TAB>VALUE file; status 1 when file or key is missing
_rel_kv_get() {
  [ -f "$1" ] || return 1
  awk -F '\t' -v k="$2" '$1 == k { print substr($0, length(k) + 2); f = 1; exit } END { exit !f }' "$1"
}

# FILE KEY VALUE -> rewrite FILE atomically with KEY set to VALUE (other lines kept)
_rel_kv_set() {
  local tmp="$1.tmp.$$"
  mkdir -p "$(dirname "$1")"
  { [ -f "$1" ] && awk -F '\t' -v k="$2" '$1 != k' "$1"; printf '%s\t%s\n' "$2" "$3"; } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$1"
}

# FILE KEY VALUE [KEY VALUE ...] -> write FILE atomically with exactly these lines
_rel_kv_write() {
  local f="$1" tmp="$1.tmp.$$"
  shift
  mkdir -p "$(dirname "$f")"
  while [ "$#" -ge 2 ]; do printf '%s\t%s\n' "$1" "$2"; shift 2; done > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f"
}

# -> the address to ask Claude's update service, with a fresh random id (never Claude's real device id)
release_feed_url() {
  local id ver os
  id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  ver="$("${_PLIST_BUDDY:-/usr/libexec/PlistBuddy}" -c 'Print :CFBundleShortVersionString' "$CLAUDES_APP_SRC/Contents/Info.plist" 2>/dev/null)" || ver=""
  [ -n "$ver" ] || ver="0.0.0"
  os="$(sw_vers -productVersion 2>/dev/null || true)"
  [ -n "$os" ] || os="0"
  printf '%s/api/desktop/darwin/universal/squirrel/update?device_id=%s&version=%s&os_version=%s\n' \
    "$CLAUDES_FEED_BASE" "$id" "$ver" "$os"
}

# -> ask the update service and write release-check; status 1 with a plain reason on stderr when it fails
release_fetch_feed() {
  local url tmp cur i v="" u="" sha="" size="" f="$CLAUDES_STATE_DIR/release-check" prev first now
  url="$(release_feed_url)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/claudes-feed.XXXXXX")" || { echo "could not make a temporary file to check for updates" >&2; return 1; }
  if ! curl -fsS --proto =https --max-time 30 -A claudes-update-check -o "$tmp" "$url" 2>/dev/null; then
    rm -f "$tmp"
    echo "could not reach Claude's update service (no internet, or the service is down)" >&2
    return 1
  fi
  cur="$(_plist_raw "$tmp" currentRelease || true)"
  if [ -n "$cur" ]; then
    for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19; do
      v="$(_plist_raw "$tmp" "releases.$i.version" || true)"
      [ -n "$v" ] || break
      if [ "$v" = "$cur" ]; then
        u="$(_plist_raw "$tmp" "releases.$i.updateTo.url" || true)"
        sha="$(_plist_raw "$tmp" "releases.$i.updateTo.sha256" || true)"
        size="$(_plist_raw "$tmp" "releases.$i.updateTo.size" || true)"
        break
      fi
    done
  fi
  rm -f "$tmp"
  if [ -z "$cur" ] || [ -z "$u" ] || [ -z "$sha" ] || [ -z "$size" ]; then
    echo "Claude's update service gave an answer claudes does not understand" >&2
    return 1
  fi
  case "$u" in
    https://downloads.claude.ai/*) ;;
    *) echo "Claude's update service gave an unexpected download address, so claudes will not use it" >&2; return 1;;
  esac
  now="$(_rel_now)"
  prev="$(_rel_kv_get "$f" version || true)"
  first=""
  [ "$prev" = "$cur" ] && first="$(_rel_kv_get "$f" first_seen || true)"
  [ -n "$first" ] || first="$now"
  _rel_kv_write "$f" checked "$now" version "$cur" url "$u" sha256 "$sha" size "$size" first_seen "$first"
}

# [--force] -> prints the newest released version; uses the saved answer when it is young enough; status 1 if unknown
release_check() {
  local f="$CLAUDES_STATE_DIR/release-check" at v now
  if [ "${1:-}" != "--force" ]; then
    at="$(_rel_kv_get "$f" checked || true)"
    v="$(_rel_kv_get "$f" version || true)"
    now="$(_rel_now)"
    case "$at" in ''|*[!0-9]*) at="";; esac
    if [ -n "$at" ] && [ -n "$v" ] && [ $(( now - at )) -lt "$CLAUDES_RELEASE_CHECK_EVERY" ]; then
      printf '%s\n' "$v"
      return 0
    fi
  fi
  release_fetch_feed || return 1
  _rel_kv_get "$f" version
}

# -> status 0 when the newest known version (saved answer, no network) is newer than the installed build
release_is_newer() {
  local v ib
  v="$(_rel_kv_get "$CLAUDES_STATE_DIR/release-check" version || true)"
  [ -n "$v" ] || return 1
  ib="$(_rel_installed_build)"
  _version_gt "$v" "$ib"
}

# PATH VERSION -> status 0 when the downloaded app is genuine Claude, intact and newer; else one plain reason and status 1
release_verify_app() {
  local app="$1" want="$2" team_ok id team build ib out
  [ -d "$app" ] || { echo "the downloaded Claude app is missing"; return 1; }
  if ! codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
    echo "the downloaded Claude app's signature is damaged or incomplete"
    return 1
  fi
  team_ok="$(codesign -dv "$CLAUDES_APP_SRC" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1 || true)"
  case "$team_ok" in ''|"not set") team_ok="$CLAUDES_TEAM_ID";; esac
  out="$(codesign -dv "$app" 2>&1 || true)"
  id="$(printf '%s\n' "$out" | sed -n 's/^Identifier=//p' | head -n 1)"
  team="$(printf '%s\n' "$out" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  if [ "$id" != "$CLAUDES_BASE_ID" ]; then
    echo "the download is not the Claude app (it says it is '${id:-unknown}')"
    return 1
  fi
  if [ "$team" != "$team_ok" ]; then
    echo "the download was signed by a different developer than your installed Claude"
    return 1
  fi
  if ! spctl --assess --type execute "$app" >/dev/null 2>&1; then
    echo "macOS would not accept the download as a safe, notarized app"
    return 1
  fi
  build="$("${_PLIST_BUDDY:-/usr/libexec/PlistBuddy}" -c 'Print :CFBundleVersion' "$app/Contents/Info.plist" 2>/dev/null)" || build=""
  if [ "$build" != "$want" ]; then
    echo "the download is version ${build:-unknown}, not the ${want} that was announced"
    return 1
  fi
  ib="$(_rel_installed_build)"
  if ! _version_gt "$build" "$ib"; then
    echo "the download (version $build) is not newer than the Claude you have ($ib)"
    return 1
  fi
  return 0
}

# VERSION REASON -> clean up after a failed download: delete its folder and ready, record release-failed, print the reason, status 1
_rel_fail() {
  rm -rf "$CLAUDES_STATE_DIR/download/$1"
  rm -f "$CLAUDES_STATE_DIR/ready"
  _rel_kv_write "$CLAUDES_STATE_DIR/release-failed" version "$1" reason "$2" at "$(_rel_now)" || true
  printf '%s\n' "$2"
  return 1
}

# -> download and verify the newest release into ready; status 0 when a verified update is waiting, else reason and 1
release_prepare() {
  local s="$CLAUDES_STATE_DIR" v url sha size dir zip app rv fv fat age first got n reason apps now
  v="$(release_check)" || return 1
  dir="$s/download/$v"
  now="$(_rel_now)"

  rv="$(_rel_kv_get "$s/ready" version || true)"
  if [ "$rv" = "$v" ]; then
    app="$(release_ready_app || true)"
    if [ -n "$app" ] && release_verify_app "$app" "$v" >/dev/null 2>&1; then return 0; fi
  fi

  fv="$(_rel_kv_get "$s/release-failed" version || true)"
  fat="$(_rel_kv_get "$s/release-failed" at || true)"
  case "$fat" in ''|*[!0-9]*) fat="";; esac
  if [ "$fv" = "$v" ] && [ -n "$fat" ] && [ $(( now - fat )) -lt "$CLAUDES_RETRY_FAILED" ]; then
    age=$(( (now - fat) / 3600 ))
    if [ "$age" -lt 1 ]; then
      echo "this version failed its checks less than an hour ago; trying again later"
    elif [ "$age" -eq 1 ]; then
      echo "this version failed its checks 1 hour ago; trying again later"
    else
      echo "this version failed its checks $age hours ago; trying again later"
    fi
    return 1
  fi

  first=""
  [ "$rv" = "$v" ] && first="$(_rel_kv_get "$s/ready" first_seen || true)"
  if [ -z "$first" ] && [ "$(_rel_kv_get "$s/release-check" version || true)" = "$v" ]; then
    first="$(_rel_kv_get "$s/release-check" first_seen || true)"
  fi
  [ -n "$first" ] || first="$now"

  url="$(_rel_kv_get "$s/release-check" url || true)"
  sha="$(_rel_kv_get "$s/release-check" sha256 || true)"
  size="$(_rel_kv_get "$s/release-check" size || true)"
  [ -n "$url" ] || { echo "the download address for version $v is not known"; return 1; }

  [ "$rv" = "$v" ] || rm -f "$s/ready"
  if [ -d "$s/download" ]; then
    find "$s/download" -mindepth 1 -maxdepth 1 ! -name "$v" -exec rm -rf {} + 2>/dev/null || true
  fi
  rm -rf "$dir"
  mkdir -p "$dir/app" || { _rel_fail "$v" "could not make a folder for the download"; return 1; }
  zip="$dir/Claude.zip"

  if ! curl -fsS --proto =https -o "$zip.part" "$url" 2>/dev/null; then
    _rel_fail "$v" "the download of Claude $v did not finish"; return 1
  fi
  mv "$zip.part" "$zip" || { _rel_fail "$v" "could not save the download"; return 1; }

  got="$(stat -f %z "$zip" 2>/dev/null || echo 0)"
  if [ "$got" != "$size" ]; then
    _rel_fail "$v" "the download is the wrong size ($got bytes, expected $size)"; return 1
  fi
  got="$(shasum -a 256 "$zip" 2>/dev/null | awk '{ print tolower($1) }' || true)"
  if [ "$got" != "$(printf '%s' "$sha" | tr '[:upper:]' '[:lower:]')" ]; then
    _rel_fail "$v" "the download does not match its published checksum, so it may be damaged or tampered with"; return 1
  fi

  if ! ditto -x -k "$zip" "$dir/app" >/dev/null 2>&1; then
    _rel_fail "$v" "the download could not be unpacked"; return 1
  fi
  apps="$(find "$dir/app" -mindepth 1 -maxdepth 1 -name '*.app' 2>/dev/null || true)"
  n="$(printf '%s' "$apps" | grep -c . || true)"
  if [ "$n" != "1" ] || [ "$apps" != "$dir/app/Claude.app" ]; then
    _rel_fail "$v" "the download did not contain exactly one Claude app"; return 1
  fi
  app="$dir/app/Claude.app"

  xattr -dr com.apple.quarantine "$app" >/dev/null 2>&1 || true

  reason="$(release_verify_app "$app" "$v" || true)"
  if [ -n "$reason" ]; then _rel_fail "$v" "$reason"; return 1; fi

  rm -f "$s/release-failed"
  _rel_kv_write "$s/ready" version "$v" app "$app" verified "$(_rel_now)" first_seen "$first"
}

# -> version of the verified update waiting; status 1 if none
release_ready_version() {
  local v
  v="$(_rel_kv_get "$CLAUDES_STATE_DIR/ready" version || true)"
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# -> path of the verified Claude.app waiting; status 1 if there is none or its folder is gone
release_ready_app() {
  local a
  a="$(_rel_kv_get "$CLAUDES_STATE_DIR/ready" app || true)"
  [ -n "$a" ] && [ -d "$a" ] || return 1
  printf '%s\n' "$a"
}

# KEY -> value of KEY in ready; status 1 if missing
release_ready_get() { _rel_kv_get "$CLAUDES_STATE_DIR/ready" "$1"; }

# KEY VALUE -> set KEY in ready (atomic rewrite)
release_ready_set() { _rel_kv_set "$CLAUDES_STATE_DIR/ready" "$1" "$2"; }

# -> forget the waiting update: remove ready and every download folder
release_discard() {
  rm -f "$CLAUDES_STATE_DIR/ready"
  rm -rf "$CLAUDES_STATE_DIR/download"
}
