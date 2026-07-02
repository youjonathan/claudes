#!/bin/bash
# rebuild-claude-instances.sh
#
# Refresh ALL secondary Claude instances (B/C/D/...) after the MAIN Claude.app updates.
#
# WORKFLOW:
#   1. Update the main app first: open regular Claude (account A) -> "Relaunch to update".
#   2. Run this script. It rebuilds every instance below from the now-updated Claude.app,
#      preserving each one's color and login (profile dirs are separate from the app bundle).
#
# To add/remove an instance or change a color, edit the INSTANCES list.
set -euo pipefail
MK="$HOME/bin/make-claude-instance.sh"
[ -x "$MK" ] || { echo "missing $MK"; exit 1; }

# "SUFFIX  COLOR  DATADIR_NAME"   (color: red orange yellow green teal blue purple pink, or 0-255)
INSTANCES=(
  "B blue   Claude-Acct-B"
  "C green  Claude-3p"
  "D purple Claude-Acct-D"
)

MAIN_VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Claude.app/Contents/Info.plist 2>/dev/null)
echo "== Rebuilding all instances from main Claude.app v$MAIN_VER =="
for row in "${INSTANCES[@]}"; do
  # shellcheck disable=SC2086
  set -- $row
  echo ""
  echo "──────── Claude $1 ($2) ────────"
  "$MK" "$1" "$2" "$3" 2>&1 | grep -E "DONE|colorize|verify|NOTE|ERROR" || true
done
killall Dock 2>/dev/null || true
echo ""
echo "== Done. All instances now on v$MAIN_VER. Existing logins preserved. =="
