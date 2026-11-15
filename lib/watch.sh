#!/bin/bash
# lib/watch.sh — claudes watch. Source, do not execute.
CLAUDES_WATCH_LABEL=io.github.youjonathan.claudes.update-watcher

_watch_plist() { printf '%s/%s.plist' "$CLAUDES_LAUNCHAGENTS_DIR" "$CLAUDES_WATCH_LABEL"; }
_watch_log() { printf '%s/update-watcher.log' "$CLAUDES_LOG_DIR"; }
_watch_target() { printf 'gui/%s/%s' "$(id -u)" "$CLAUDES_WATCH_LABEL"; }
_watch_loaded() { launchctl print "$(_watch_target)" >/dev/null 2>&1; }

_xml_escape() { # $1: text -> XML-safe text
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# on|off|status -> dispatch to watch_on / watch_off / watch_status
cmd_watch() {
  case "${1:-}" in
    on) watch_on;;
    off) watch_off;;
    status) watch_status;;
    *) echo "usage: claudes watch on|off|status" >&2; return 1;;
  esac
}

# -> write the LaunchAgent plist and load it; refuses if auto-updates are blocked
watch_on() {
  if [ -z "${SELF:-}" ]; then
    echo "claudes: cannot tell where claudes is installed (SELF is unset); run it as 'claudes watch on'" >&2
    return 1
  fi
  local blocked
  if blocked="$(auto_updates_blocked)"; then
    echo "Claude's own updater is switched off by $blocked (disableAutoUpdates)."
    echo "The background helper needs Claude's updater on, so it was not installed."
    return 1
  fi
  local plist logf script
  plist="$(_watch_plist)"; logf="$(_watch_log)"; script="$SELF/claudes"
  mkdir -p "$CLAUDES_LAUNCHAGENTS_DIR" "$CLAUDES_LOG_DIR"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$CLAUDES_WATCH_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(_xml_escape "$script")</string>
    <string>update</string>
    <string>--watch-run</string>
  </array>
  <key>StartInterval</key>
  <integer>300</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>$(_xml_escape "$logf")</string>
  <key>StandardErrorPath</key>
  <string>$(_xml_escape "$logf")</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin</string>
  </dict>
</dict>
</plist>
PLIST
  if _watch_loaded; then
    launchctl bootout "$(_watch_target)" >/dev/null 2>&1 || true
  fi
  launchctl bootstrap "gui/$(id -u)" "$plist"
  echo "update helper installed: checks every 5 minutes ($plist)"
}

# -> unload the LaunchAgent and remove its plist
watch_off() {
  local plist; plist="$(_watch_plist)"
  if [ ! -e "$plist" ] && ! _watch_loaded; then
    echo "update helper is not installed."
    return 0
  fi
  launchctl bootout "$(_watch_target)" >/dev/null 2>&1 || true
  rm -f "$plist"
  echo "update helper removed."
}

# -> print installed/loaded state and the last 5 log lines
watch_status() {
  local plist logf; plist="$(_watch_plist)"; logf="$(_watch_log)"
  if [ -e "$plist" ]; then echo "installed: yes ($plist)"; else echo "installed: no"; fi
  if _watch_loaded; then echo "loaded: yes"; else echo "loaded: no"; fi
  if [ -s "$logf" ]; then
    echo "last log lines ($logf):"
    tail -n 5 "$logf"
  fi
  return 0
}
