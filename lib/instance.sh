#!/bin/bash
# lib/instance.sh — build/remove one Claude instance. Source, do not execute.
# Requires: CLAUDES_LIB (dir with common.sh, recolor.swift, seticon.swift) sourced/available.

build_instance() { # suffix hue profile-name
  local suffix="$1" hue="$2" profname="$3"
  set -e
  local low; low="$(printf '%s' "$suffix" | tr '[:upper:]' '[:lower:]')"
  local dst="$CLAUDES_APPS_DIR/Claude ${suffix}.app"
  local datadir="$HOME/Library/Application Support/${profname}"
  local bundle_id="${CLAUDES_BASE_ID}.${low}"

  preflight   # deps + main app BEFORE anything destructive

  local scratch; scratch="$(mktemp -d)"
  trap 'rm -rf "$scratch"; trap - RETURN' RETURN

  echo ">> [$suffix] quit any running copy + fresh launcher bundle"
  pkill -f "user-data-dir=$datadir" 2>/dev/null || true
  rm -rf "$dst"
  mkdir -p "$dst/Contents/MacOS" "$dst/Contents/Resources"

  echo ">> [$suffix] Info.plist (id=$bundle_id, DisplayName='Claude $suffix')"
  cat > "$dst/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude ${suffix}</string>
  <key>CFBundleDisplayName</key><string>Claude ${suffix}</string>
  <key>CFBundleIdentifier</key><string>${bundle_id}</string>
  <key>CFBundleExecutable</key><string>launch</string>
  <key>CFBundleIconFile</key><string>electron</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
EOF

  echo ">> [$suffix] compiling launcher -> delegate to live Claude.app (--user-data-dir=$datadir)"
  cat > "$scratch/launch.c" <<EOF
#include <unistd.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
    const char *claude = "$CLAUDES_APP_SRC/Contents/MacOS/Claude";
    const char *datadir_arg = "--user-data-dir=$datadir";

    char **new_argv = malloc(sizeof(char *) * (argc + 2));
    new_argv[0] = (char *)claude;
    new_argv[1] = (char *)datadir_arg;
    for (int i = 1; i < argc; i++) new_argv[i + 1] = argv[i];
    new_argv[argc + 1] = NULL;

    execv(claude, new_argv);
    /* only reached if execv failed (e.g. Claude.app moved/removed) */
    system("osascript -e 'display alert \"Claude not found\" message \"Expected at $CLAUDES_APP_SRC — reinstall Claude Desktop, then relaunch.\"' >/dev/null 2>&1");
    return 1;
}
EOF
  clang -O2 -o "$dst/Contents/MacOS/launch" "$scratch/launch.c"
  codesign --force --sign - "$dst/Contents/MacOS/launch" >/dev/null 2>&1
  mkdir -p "$datadir"

  echo ">> [$suffix] recolor icon (hue $hue)"
  local iconset="$scratch/icon.iconset"
  swift "$CLAUDES_LIB/recolor.swift" "$CLAUDES_APP_SRC/Contents/Resources/electron.icns" "$iconset" "$hue"
  iconutil -c icns "$iconset" -o "$dst/Contents/Resources/electron.icns"

  echo ">> [$suffix] set Finder custom icon"
  swift "$CLAUDES_LIB/seticon.swift" "$dst/Contents/Resources/electron.icns" "$dst" 2>/dev/null || true

  echo ">> [$suffix] register + refresh icon cache"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dst" 2>/dev/null || true
  rm -rf "$HOME/Library/Caches/com.apple.iconservices.store" 2>/dev/null || true
  touch "$dst"; killall Dock 2>/dev/null || true

  echo ">> [$suffix] DONE  bundle=$dst  profile=$datadir"
  open "$dst"
}

remove_instance() { # suffix profile
  local suffix="$1" profname="${2:-}"
  if [ -n "$profname" ]; then
    local datadir="$HOME/Library/Application Support/$profname"
    pkill -f "user-data-dir=$datadir" 2>/dev/null || true
    pkill -f "chrome_crashpad_handler.*database=$datadir/Crashpad" 2>/dev/null || true
    # best-effort wait for the main process, its helper/renderer/gpu/utility
    # children, and the crashpad handler to actually exit, so the caller's
    # rm -rf doesn't race a still-shutting-down process. Empirically, full
    # teardown of a real instance (main + gpu-process + network/node utility
    # + renderer helpers) can take 8-12s in practice, so this caps at ~20s
    # rather than the ~2s that proved too short in testing; it still returns
    # early as soon as everything is gone, and proceeds regardless once the
    # cap elapses (best-effort, not a hard requirement).
    local waited=0
    while [ "$waited" -lt 200 ] && { pgrep -f "user-data-dir=$datadir" >/dev/null 2>&1 || \
      pgrep -f "chrome_crashpad_handler.*database=$datadir/Crashpad" >/dev/null 2>&1; }; do
      sleep 0.1
      waited=$((waited + 1))
    done
  fi
  rm -rf "$CLAUDES_APPS_DIR/Claude ${suffix}.app"
  echo "removed app: Claude ${suffix}.app"
}
