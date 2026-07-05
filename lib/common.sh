#!/bin/bash
# lib/common.sh — shared helpers. Source, do not execute.
CLAUDES_APP_SRC="/Applications/Claude.app"
CLAUDES_BASE_ID="com.anthropic.claudefordesktop"

CLAUDES_APPS_DIR="${CLAUDES_APPS_DIR:-/Applications}"

is_legacy_instance() { # $1: suffix — exit 0 if an old full-copy clone (has Claude-bin)
  [ -e "$CLAUDES_APPS_DIR/Claude ${1}.app/Contents/MacOS/Claude-bin" ]
}

color_to_hue() { # $1: color name or 0-255. echoes hue; returns 1 on bad input.
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    red) echo 0;;       orange) echo 18;;  yellow) echo 38;;  green) echo 90;;
    teal|cyan) echo 125;; blue) echo 160;; indigo) echo 172;;
    violet) echo 195;;  purple) echo 190;; pink|magenta) echo 220;;
    ''|*[!0-9]*) return 1;;
    *) echo "$1";;
  esac
}

valid_suffix() { # $1: suffix. returns 1 on invalid (must be bundle-id-safe).
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: invalid suffix '$1' (use letters/digits/./_/- only)"; return 1; }
}

valid_profile() { # $1: profile dir name. single path component, no whitespace/quotes.
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != "." && "$1" != ".." ]] \
    || { echo "ERROR: invalid profile '$1' (use letters/digits/./_/- only)"; return 1; }
}

preflight() { # verify deps + main app BEFORE any build step
  local bad=0
  for t in swift iconutil; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: '$t' missing — run: xcode-select --install"; bad=1; }
  done
  [ -d "$CLAUDES_APP_SRC" ] || { echo "ERROR: $CLAUDES_APP_SRC not found — install Claude Desktop first"; bad=1; }
  [ "$bad" = 0 ] || exit 1
}

main_version() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$CLAUDES_APP_SRC/Contents/Info.plist" 2>/dev/null
}
