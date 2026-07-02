#!/bin/bash
# lib/instance.sh — build/remove one Claude instance. Source, do not execute.
# Requires: CLAUDES_LIB (dir with common.sh, recolor.swift, seticon.swift) sourced/available.
CLAUDES_PB=/usr/libexec/PlistBuddy

build_instance() { # suffix hue profile-name
  local suffix="$1" hue="$2" profname="$3"
  set -e   # fail loudly instead of limping to a false "DONE" on a mid-recipe error
  local low; low="$(printf '%s' "$suffix" | tr '[:upper:]' '[:lower:]')"
  local dst="/Applications/Claude ${suffix}.app"
  local datadir="$HOME/Library/Application Support/${profname}"
  local bundle_id="${CLAUDES_BASE_ID}.${low}"

  preflight   # deps + main app BEFORE anything destructive

  local scratch; scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"; trap - RETURN' RETURN

  local ent="$scratch/ent.plist"
  cat > "$ent" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
</dict></plist>
PLIST

  echo ">> [$suffix] quit any running copy + fresh copy"
  pkill -f "/Applications/Claude ${suffix}\.app/" 2>/dev/null || true
  rm -rf "$dst"; cp -R "$CLAUDES_APP_SRC" "$dst"
  local plist="$dst/Contents/Info.plist"

  echo ">> [$suffix] identity (id=$bundle_id, DisplayName='Claude $suffix')"
  $CLAUDES_PB -c "Set :CFBundleIdentifier $bundle_id" "$plist"
  $CLAUDES_PB -c "Add :CFBundleDisplayName string Claude ${suffix}" "$plist" 2>/dev/null \
    || $CLAUDES_PB -c "Set :CFBundleDisplayName Claude ${suffix}" "$plist"
  $CLAUDES_PB -c "Delete :CFBundleIconName" "$plist" 2>/dev/null || true   # fall back to electron.icns

  echo ">> [$suffix] shim executable -> --user-data-dir=$datadir"
  local macos="$dst/Contents/MacOS"
  mv "$macos/Claude" "$macos/Claude-bin"
  printf '#!/bin/bash\nexec "$(dirname "$0")/Claude-bin" --user-data-dir="%s" "$@"\n' "$datadir" > "$macos/Claude"
  chmod +x "$macos/Claude"; mkdir -p "$datadir"

  echo ">> [$suffix] recolor icon (hue $hue)"
  local iconset="$scratch/icon.iconset"
  swift "$CLAUDES_LIB/recolor.swift" "$CLAUDES_APP_SRC/Contents/Resources/electron.icns" "$iconset" "$hue"
  iconutil -c icns "$iconset" -o "$dst/Contents/Resources/electron.icns"

  echo ">> [$suffix] inside-out ad-hoc re-sign"
  local ef="$dst/Contents/Frameworks/Electron Framework.framework"
  local d
  for d in "$ef/Versions/A/Libraries/"*.dylib; do codesign --force --sign - "$d"; done
  codesign --force --sign - "$ef/Versions/A/Electron Framework"
  codesign --force --sign - "$ef"
  local fw
  for fw in "$dst/Contents/Frameworks/"*.framework; do
    [ "$fw" = "$ef" ] && continue; codesign --force --sign - "$fw"
  done
  local h
  for h in "$dst/Contents/Frameworks/"*.app; do
    codesign --force --options runtime --entitlements "$ent" --sign - "$h/Contents/MacOS/"*
    codesign --force --options runtime --entitlements "$ent" --sign - "$h"
  done
  codesign --force --options runtime --entitlements "$ent" --sign - "$macos/Claude-bin"  # entitle REAL binary
  codesign --force --sign - "$macos/Claude"                                              # shim
  codesign --force --sign - "$dst"

  echo ">> [$suffix] set Finder custom icon (Assets.car/CFBundleIconName would else win)"
  # NOTE: writes <app>/Icon\r OUTSIDE sealed Contents/; verified not to invalidate the
  # signature on current macOS. If the verify below ever fails on a user's machine, suspect this.
  swift "$CLAUDES_LIB/seticon.swift" "$dst/Contents/Resources/electron.icns" "$dst" 2>/dev/null || true

  echo ">> [$suffix] refresh icon cache"
  rm -rf "$HOME/Library/Caches/com.apple.iconservices.store" 2>/dev/null || true
  touch "$dst"; killall Dock 2>/dev/null || true

  if ! codesign --verify --verbose=1 "$dst" > "$scratch/verify.log" 2>&1; then
    echo ">> [$suffix] ERROR: codesign --verify FAILED" >&2
    cat "$scratch/verify.log" >&2
    return 1
  fi
  local verify; verify="$(tail -1 "$scratch/verify.log")"
  echo ">> [$suffix] DONE  profile=$datadir  verify: $verify"
  open "$dst"
}

remove_instance() { # suffix [--purge-profile]
  local suffix="$1"
  pkill -f "/Applications/Claude ${suffix}\.app/" 2>/dev/null || true
  rm -rf "/Applications/Claude ${suffix}.app"
  echo "removed app: Claude ${suffix}.app"
  if [ "${2:-}" = "--purge-profile" ]; then
    echo "(profile purge handled by caller via config lookup)"
  fi
}
