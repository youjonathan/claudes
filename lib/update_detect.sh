#!/bin/bash
# lib/update_detect.sh — read-only facts about updates and accounts. Source, do not execute.

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

# DATADIR -> status 0 when idle; prints a short reason on stdout when busy; not running -> idle
account_idle() {
  local dir="$1" pid="" p d hit newest mins c1 c2 delta
  while IFS=$'\t' read -r p d; do
    [ "$d" = "$dir" ] && { pid="$p"; break; }
  done < <(claude_main_procs 2>/dev/null)
  [ -n "$pid" ] || return 0

  if [ -d "$dir/claude-code-sessions" ]; then
    newest="$(find "$dir/claude-code-sessions" -type f -mmin "-$CLAUDES_IDLE_MINUTES" \
      -exec stat -f %m {} + 2>/dev/null | sort -n | tail -n 1 || true)"
    if [ -n "$newest" ]; then
      mins=$(( ($(date +%s) - newest) / 60 ))
      [ "$mins" -lt 0 ] && mins=0
      echo "session files changed $mins min ago"
      return 1
    fi
  fi

  if [ -d "$dir/local-agent-mode-sessions" ]; then   # Cowork
    newest="$(find "$dir/local-agent-mode-sessions" -type f -not -path '*/skills-plugin/*' -mmin "-$CLAUDES_IDLE_MINUTES" \
      -exec stat -f %m {} + 2>/dev/null | sort -n | tail -n 1 || true)"
    if [ -n "$newest" ]; then
      mins=$(( ($(date +%s) - newest) / 60 ))
      [ "$mins" -lt 0 ] && mins=0
      echo "Cowork files changed $mins min ago"
      return 1
    fi
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

# -> whole seconds since the last keyboard/mouse use (HIDIdleTime from ioreg); status 1 if it can't be read
user_idle_seconds() {
  local ns
  ns="$(ioreg -c IOHIDSystem -d 4 2>/dev/null | awk '/"HIDIdleTime"/ { print $NF; exit }' || true)"
  case "$ns" in ''|*[!0-9]*) return 1;; esac
  echo $((ns / 1000000000))
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
