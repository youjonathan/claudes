#!/bin/bash
# lib/update_detect.sh — read-only facts about updates and accounts. Source, do not execute.

CLAUDES_STATE_DIR="${CLAUDES_STATE_DIR:-$HOME/Library/Application Support/claudes}"
CLAUDES_IDLE_MINUTES="${CLAUDES_IDLE_MINUTES:-10}"
CLAUDES_CPU_SAMPLE="${CLAUDES_CPU_SAMPLE:-20}"
CLAUDES_CPU_IDLE="${CLAUDES_CPU_IDLE:-2}"
_UD_WINDOWS_SWIFT="${CLAUDES_WINDOWS_SWIFT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/windows.swift}"
_PLIST_BUDDY=/usr/libexec/PlistBuddy
_SHIPIT_LABEL="com.anthropic.claudefordesktop.ShipIt"

# FILE KEY -> raw value of KEY in a plist/JSON file; status 1 when unreadable or missing
_plist_raw() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

# A B -> status 0 when dotted version A is greater than B (numeric, field by field)
_version_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb) ? na : nb
    for (i = 1; i <= n; i++) {
      p = x[i] + 0; q = y[i] + 0
      if (p > q) exit 0
      if (p < q) exit 1
    }
    exit 1
  }'
}

# -> CFBundleVersion of $CLAUDES_APP_SRC/Contents/Info.plist
installed_build() {
  "$_PLIST_BUDDY" -c 'Print :CFBundleVersion' "$CLAUDES_APP_SRC/Contents/Info.plist" 2>/dev/null
}

# -> status 0 when launchctl shows the ShipIt job with state = running
shipit_waiting() {
  local out
  out="$(launchctl print "gui/$(id -u)/$_SHIPIT_LABEL" 2>/dev/null)" || return 1
  grep -Eq '^[[:space:]]+state = running[[:space:]]*$' <<<"$out"
}

# -> path of staged bundle from updateBundleURL in ShipItState.plist, only if the folder exists
staged_bundle_path() {
  local url path
  url="$(_plist_raw "$CLAUDES_SHIPIT_DIR/ShipItState.plist" updateBundleURL)" || return 1
  [ -n "$url" ] || return 1
  path="${url#file://}"
  while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do path="${path%/}"; done
  path="$(printf '%s' "$path" | sed 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"
  path="$(printf '%b' "$path")"
  [ -d "$path" ] || return 1
  printf '%s\n' "$path"
}

# -> CFBundleVersion of the staged bundle
staged_build() {
  local p
  p="$(staged_bundle_path)" || return 1
  "$_PLIST_BUDDY" -c 'Print :CFBundleVersion' "$p/Contents/Info.plist" 2>/dev/null
}

# -> one word: none | waiting | no-installer
update_state() {
  local sb ib
  sb="$(staged_build)" || { echo none; return 0; }
  ib="$(installed_build)" || ib=""
  if [ -z "$sb" ] || [ "$sb" = "$ib" ] || { [ -n "$ib" ] && ! _version_gt "$sb" "$ib"; }; then
    echo none
  elif shipit_waiting; then
    echo waiting
  else
    echo no-installer
  fi
}

# -> byte size of ShipIt_stderr.log (0 if missing)
shipit_log_size() {
  local f="$CLAUDES_SHIPIT_DIR/ShipIt_stderr.log"
  if [ -f "$f" ]; then stat -f %z "$f" 2>/dev/null || echo 0; else echo 0; fi
}

# OFFSET -> ShipIt log text after that byte offset
shipit_log_since() {
  local f="$CLAUDES_SHIPIT_DIR/ShipIt_stderr.log"
  [ -f "$f" ] || return 0
  tail -c +"$(( ${1:-0} + 1 ))" "$f"
}

# -> status 0 and prints the plist path when disableAutoUpdates is true in managed prefs
auto_updates_blocked() {
  local f v
  for f in "$CLAUDES_MANAGED_PREFS_DIR/$CLAUDES_BASE_ID.plist" \
           "$CLAUDES_MANAGED_PREFS_DIR/${USER:-$(id -un)}/$CLAUDES_BASE_ID.plist"; do
    [ -f "$f" ] || continue
    v="$(_plist_raw "$f" disableAutoUpdates)" || continue
    case "$v" in true|1) printf '%s\n' "$f"; return 0;; esac
  done
  return 1
}

# state for known_accounts (config_each callback cannot return values)
_KA_OUT=""
_KA_SEEN=""
_KA_LAUNCHERS=""
_ka_nl=$'\n'

# DATADIR LAUNCHER -> add one account unless the folder is already listed
_ka_add() {
  case "$_ka_nl$_KA_SEEN$_ka_nl" in *"$_ka_nl$1$_ka_nl"*) return 0;; esac
  _KA_SEEN="$_KA_SEEN${_KA_SEEN:+$_ka_nl}$1"
  [ -n "$2" ] && _KA_LAUNCHERS="$_KA_LAUNCHERS${_KA_LAUNCHERS:+$_ka_nl}$2"
  _KA_OUT="$_KA_OUT$1"$'\t'"$2$_ka_nl"
}

# suffix color profile -> config_each callback
_ka_from_config() {
  local app="$CLAUDES_APPS_DIR/Claude $1.app"
  [ -d "$app" ] || return 0
  is_legacy_instance "$1" && return 0
  [ -n "$3" ] || return 0
  _ka_add "$CLAUDES_SUPPORT_DIR/$3" "$app"
}

# -> lines DATADIR<TAB>LAUNCHER (LAUNCHER may be empty), one per DATADIR
known_accounts() {
  local f app name suffix line dir
  _KA_OUT=""; _KA_SEEN=""; _KA_LAUNCHERS=""
  [ -f "$CLAUDES_CONFIG" ] && config_each _ka_from_config
  for f in "$CLAUDES_APPS_DIR"/Claude\ *.app/Contents/MacOS/launch; do
    [ -f "$f" ] || continue
    app="${f%/Contents/MacOS/launch}"
    name="${app##*/}"; suffix="${name#Claude }"; suffix="${suffix%.app}"
    is_legacy_instance "$suffix" && continue
    case "$_ka_nl$_KA_LAUNCHERS$_ka_nl" in *"$_ka_nl$app$_ka_nl"*) continue;; esac
    line="$(strings "$f" 2>/dev/null | grep -F -- '--user-data-dir=' | head -n 1 || true)"
    [ -n "$line" ] || continue
    dir="${line#*--user-data-dir=}"
    dir="${dir//"%s"/$HOME}"
    [ -n "$dir" ] || continue
    _ka_add "$dir" "$app"
  done
  _ka_add "$CLAUDES_SUPPORT_DIR/Claude" ""
  printf '%s' "$_KA_OUT"
}

# DATADIR -> launcher path, or nothing
launcher_for() {
  local d l
  while IFS=$'\t' read -r d l; do
    if [ "$d" = "$1" ]; then [ -n "$l" ] && printf '%s\n' "$l"; return 0; fi
  done < <(known_accounts)
  return 0
}

# DATADIR -> status 0 when stealth-relaunch exists with userQuit and navOnly not true
marker_says_update_quit() {
  local f="$1/stealth-relaunch" v
  [ -f "$f" ] || return 1
  _plist_raw "$f" ts >/dev/null || return 1   # not a readable marker (garbage)
  v="$(_plist_raw "$f" userQuit || true)"; [ "$v" = true ] && return 1
  v="$(_plist_raw "$f" navOnly || true)"; [ "$v" = true ] && return 1
  return 0
}

# DATADIR -> seconds since the stealth-relaunch ts (ms)
marker_age() {
  local ts
  ts="$(_plist_raw "$1/stealth-relaunch" ts)" || return 1
  ts="${ts%%.*}"
  case "$ts" in ''|*[!0-9]*) return 1;; esac
  echo $(( $(date +%s) - ts / 1000 ))
}

# TIME -> seconds (float) from ps cputime format [[dd-]hh:]mm:ss.ss
ps_time_to_seconds() {
  awk -v t="$1" 'BEGIN {
    d = 0
    if (index(t, "-")) { split(t, a, "-"); d = a[1] + 0; t = a[2] }
    n = split(t, p, ":"); s = 0
    for (i = 1; i <= n; i++) s = s * 60 + p[i]
    printf "%.2f\n", d * 86400 + s
  }'
}

# PID -> total CPU seconds of PID descendants whose command is not inside $CLAUDES_APP_SRC
claude_code_cpu_seconds() {
  local p cmd t total=""
  for p in $(proc_tree "$1" 2>/dev/null); do
    [ "$p" = "$1" ] && continue
    cmd="$(ps -o command= -p "$p" 2>/dev/null || true)"
    [ -n "$cmd" ] || continue
    case "$cmd" in "$CLAUDES_APP_SRC/"*) continue;; esac
    t="$(ps -o time= -p "$p" 2>/dev/null | tr -d ' ' || true)"
    [ -n "$t" ] || continue
    total="$total $(ps_time_to_seconds "$t")"
  done
  echo $total | tr ' ' '\n' | awk '{ s += $1 } END { printf "%.2f\n", s + 0 }'
}

# -> pid of the frontmost app (lsappinfo front, then its pid); status 1 if unknown
front_app_pid() {
  local asn pid
  asn="$(lsappinfo front 2>/dev/null | head -n 1 | tr -d '[:space:]')" || return 1
  [ -n "$asn" ] || return 1
  pid="$(lsappinfo info -only pid "$asn" 2>/dev/null | sed -n 's/.*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)" || return 1
  case "$pid" in ''|*[!0-9]*) return 1;; esac
  printf '%s\n' "$pid"
}

# DEST -> compile lib/windows.swift into DEST; status 1 if it can't be built
_windows_build() {
  local tmp="$1.$$"
  if swiftc -O -o "$tmp" "$_UD_WINDOWS_SWIFT" >/dev/null 2>&1 && [ -x "$tmp" ] && mv -f "$tmp" "$1"; then return 0; fi
  rm -f "$tmp"
  return 1
}

# -> pids that own a full-screen window, one per line; status 1 when the check cannot run.
# Runs the helper compiled in the claudes state folder (rebuilt when windows.swift is newer); falls back to
# `swift FILE`. In a dry run (CLAUDES_IDLE_READONLY=1) a missing helper is built in a throwaway folder instead.
fullscreen_pids() {
  local bin="$CLAUDES_STATE_DIR/bin/claudes-windows" out tmpd rc=0
  [ -f "$_UD_WINDOWS_SWIFT" ] || return 1
  if [ -x "$bin" ] && ! [ "$_UD_WINDOWS_SWIFT" -nt "$bin" ]; then
    out="$("$bin" 2>/dev/null)" || return 1
  elif [ "${CLAUDES_IDLE_READONLY:-0}" = 1 ]; then
    tmpd="$(mktemp -d)" || return 1
    if _windows_build "$tmpd/claudes-windows"; then
      out="$("$tmpd/claudes-windows" 2>/dev/null)" || rc=1
    else
      out="$(swift "$_UD_WINDOWS_SWIFT" 2>/dev/null)" || rc=1
    fi
    rm -f "$tmpd/claudes-windows"; rmdir "$tmpd" 2>/dev/null || true
    [ "$rc" -eq 0 ] || return 1
  elif mkdir -p "$CLAUDES_STATE_DIR/bin" 2>/dev/null && _windows_build "$bin"; then
    out="$("$bin" 2>/dev/null)" || return 1
  else
    out="$(swift "$_UD_WINDOWS_SWIFT" 2>/dev/null)" || return 1
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
  return 0
}

# DATADIR -> main pid of the running copy, or nothing
_idle_main_pid() {
  local p d
  while IFS=$'\t' read -r p d; do
    [ "$d" = "$1" ] && { printf '%s\n' "$p"; return 0; }
  done < <(claude_main_procs 2>/dev/null)
  return 0
}

# DATADIR -> newest change time (epoch) of the Claude Code session files local_*.json, or nothing
_newest_code_session() {
  [ -d "$1/claude-code-sessions" ] || return 0
  find "$1/claude-code-sessions" -type f -name 'local_*.json' -exec stat -f %m {} + 2>/dev/null \
    | sort -n | tail -n 1 || true
}

# DATADIR -> newest change time (epoch) of the Cowork session files (skills sync files left out), or nothing
_newest_cowork_session() {
  [ -d "$1/local-agent-mode-sessions" ] || return 0
  find "$1/local-agent-mode-sessions" -type f -not -path '*/skills-plugin/*' -not -name manifest.json \
    -exec stat -f %m {} + 2>/dev/null | sort -n | tail -n 1 || true
}

# EPOCH -> whole minutes since EPOCH (never negative); status 0 when younger than CLAUDES_IDLE_MINUTES
_recent_minutes() {
  local age=$(( $(claudes_now) - $1 ))
  [ "$age" -lt 0 ] && age=0
  _RECENT_MIN=$(( age / 60 ))
  [ "$age" -lt $(( CLAUDES_IDLE_MINUTES * 60 )) ]
}

# TEXT -> append a timestamped line to update.log (real runs only; never fails)
_idle_log() {
  mkdir -p "$CLAUDES_LOG_DIR" 2>/dev/null || return 0
  printf '%s idle check: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$CLAUDES_LOG_DIR/update.log" 2>/dev/null || true
}

# DATADIR -> status 0 when idle; prints a short plain reason on stdout when busy; not running -> idle.
# Copies Claude's own idle rules in order: window in front, full screen, session files, CPU.
# A rule that cannot run (lsappinfo or the full-screen helper failing) counts as busy and is logged, except in
# a dry run (CLAUDES_IDLE_READONLY=1), where idle_rules_report says so instead.
account_idle() {
  local dir="$1" pid front fs newest c1 c2 delta reason
  pid="$(_idle_main_pid "$dir")"
  [ -n "$pid" ] || return 0

  if front="$(front_app_pid)"; then
    if [ "$front" = "$pid" ]; then
      echo "its window is in front"
      return 1
    fi
  elif [ "${CLAUDES_IDLE_READONLY:-0}" != 1 ]; then
    reason="could not check which app is in front (lsappinfo failed); the update waits until it works"
    _idle_log "$reason"
    echo "$reason"
    return 1
  fi

  if fs="$(fullscreen_pids 2>/dev/null)"; then
    :
  elif [ "${CLAUDES_IDLE_READONLY:-0}" != 1 ]; then
    reason="could not check for full-screen windows (the Swift helper would not build or run); install Xcode Command Line Tools with: xcode-select --install"
    _idle_log "$reason"
    echo "$reason"
    return 1
  else
    fs=""
  fi
  if grep -Fxq -- "$pid" <<<"$fs"; then
    echo "a window is full screen"
    return 1
  fi

  newest="$(_newest_code_session "$dir")"
  if [ -n "$newest" ] && _recent_minutes "$newest"; then
    echo "a Claude Code session was active $_RECENT_MIN min ago"
    return 1
  fi

  newest="$(_newest_cowork_session "$dir")"
  if [ -n "$newest" ] && _recent_minutes "$newest"; then
    echo "a Cowork session was active $_RECENT_MIN min ago"
    return 1
  fi

  c1="$(claude_code_cpu_seconds "$pid")"
  claudes_sleep "$CLAUDES_CPU_SAMPLE"
  c2="$(claude_code_cpu_seconds "$pid")"
  delta="$(awk -v a="$c1" -v b="$c2" 'BEGIN { printf "%.2f\n", b - a }')"
  if awk -v d="$delta" -v m="$CLAUDES_CPU_IDLE" 'BEGIN { exit !(d > m) }'; then
    echo "Claude Code used $(awk -v d="$delta" 'BEGIN { printf "%.0f", d }')s of CPU in ${CLAUDES_CPU_SAMPLE}s"
    return 1
  fi
  return 0
}

# -> path of the file holding when each account was first seen idle
_idle_since_file() { echo "$CLAUDES_STATE_DIR/idle-since"; }

# DATADIR MAINPID -> epoch of the line for exactly that folder and pid, or nothing
_idle_since_get() {
  local f; f="$(_idle_since_file)"
  [ -f "$f" ] || return 0
  awk -F'\t' -v d="$1" -v p="$2" '$1 == d && $2 == p { print $3; exit }' "$f"
}

# -> take the small lock around rewriting idle-since (accounts are checked in parallel); waits up to about 5 s
_idle_since_lock() {
  local lock="$CLAUDES_STATE_DIR/idle-since.lock" n=0
  mkdir -p "$CLAUDES_STATE_DIR" 2>/dev/null || true
  while ! mkdir "$lock" 2>/dev/null; do
    n=$((n + 1))
    [ "$n" -ge 50 ] && { rm -rf "$lock"; mkdir "$lock" 2>/dev/null || true; break; }
    sleep 0.1
  done
}
_idle_since_unlock() { rmdir "$CLAUDES_STATE_DIR/idle-since.lock" 2>/dev/null || true; }

# DATADIR [MAINPID EPOCH] -> drop the folder's line, then add MAINPID/EPOCH when given
_idle_since_set() {
  local f tmp; f="$(_idle_since_file)"
  [ -n "${3:-}" ] || [ -f "$f" ] || return 0
  _idle_since_lock
  tmp="$(mktemp "$CLAUDES_STATE_DIR/idle-since.XXXXXX")" || { _idle_since_unlock; return 0; }
  {
    [ -f "$f" ] && DIR="$1" awk -F'\t' '$1 != ENVIRON["DIR"]' "$f"
    [ -z "${3:-}" ] || printf '%s\t%s\t%s\n' "$1" "$2" "$3"
  } > "$tmp" || true
  mv -f "$tmp" "$f"
  _idle_since_unlock
}

# DATADIR -> the 10-minute countdown. Status 0 only after CLAUDES_IDLE_MINUTES of unbroken idleness; otherwise
# prints why (the busy reason, or "quiet for M of 10 minutes") and returns 1. Not running -> 0.
# CLAUDES_IDLE_READONLY=1 reads idle-since but never writes it.
account_idle_settled() {
  local dir="$1" pid reason since now elapsed ro="${CLAUDES_IDLE_READONLY:-0}"
  pid="$(_idle_main_pid "$dir")"
  if [ -z "$pid" ]; then
    [ "$ro" = 1 ] || _idle_since_set "$dir"
    return 0
  fi
  if ! reason="$(account_idle "$dir")"; then
    [ "$ro" = 1 ] || _idle_since_set "$dir"
    printf '%s\n' "$reason"
    return 1
  fi
  now="$(claudes_now)"
  since="$(_idle_since_get "$dir" "$pid")"
  if [ -z "$since" ]; then
    since="$now"
    [ "$ro" = 1 ] || _idle_since_set "$dir" "$pid" "$now"
  fi
  elapsed=$(( now - since ))
  [ "$elapsed" -lt 0 ] && elapsed=0
  if [ "$elapsed" -lt $(( CLAUDES_IDLE_MINUTES * 60 )) ]; then
    echo "quiet for $(( elapsed / 60 )) of $CLAUDES_IDLE_MINUTES minutes"
    return 1
  fi
  return 0
}

# -> plain list of which of Claude's own idle rules are copied and which cannot be seen (for --dry-run)
idle_rules_report() {
  echo "Claude's own rules for when it may close, and how claudes copies them:"
  echo "  Copied:"
  echo "    - a Claude Code or Cowork session is working (read from the session files and from CPU use)"
  echo "    - an account's window is in front"
  echo "    - a window is full screen"
  echo "    - $CLAUDES_IDLE_MINUTES quiet minutes in a row, counted per account"
  echo "  Cannot be seen from outside:"
  echo "    - unsaved typing in a message box (Claude keeps drafts on disk, so they very likely come back after reopening)"
  echo "    - an export or import in progress"
  echo "    - a /loop or scheduled wake-up waiting inside a quiet session"
  echo "    - a claude.ai chat reply that is still streaming"
  front_app_pid >/dev/null 2>&1 \
    || echo "  Note: could not tell which app is in front on this Mac (lsappinfo failed). A real update counts every open account as busy until that works."
  fullscreen_pids >/dev/null 2>&1 \
    || echo "  Note: could not check for full-screen windows on this Mac (needs the Swift tools). A real update counts every open account as busy until you install Xcode Command Line Tools: xcode-select --install"
  return 0
}

# [PID] -> status 0 when this process (or PID) has a Claude main process as an ancestor
inside_claude_copy() {
  local pid="${1:-$$}" cmd n=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$n" -lt 64 ]; do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    case "$cmd" in
      "$CLAUDES_APP_SRC/Contents/MacOS/Claude"|"$CLAUDES_APP_SRC/Contents/MacOS/Claude "*) return 0;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    n=$((n + 1))
  done
  return 1
}
