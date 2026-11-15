#!/bin/bash
# lib/update.sh — claudes update. Source, do not execute.

# globals shared by the step functions (cmd_update sets them)
UPDATE_DRY=0               # 1 = dry run: never signal, open, write state or lock
UPDATE_WATCH=0             # 1 = run by the background watcher (one check, never waits)
UPDATE_WAITING=0           # 1 = an update is waiting to install (markers of any age count)
UPDATE_ACCOUNTS=""         # lines DATADIR<TAB>LAUNCHER for the accounts being handled
UPDATE_OLD_BUILD=""        # installed build before the quit
UPDATE_OLD_VERSION=""      # installed version before the quit
UPDATE_LOG_OFFSET=0        # ShipIt log size before the quit
UPDATE_BLOCKED_FILE=""      # the managed-prefs file that blocks Claude's own updater, empty when it is not blocked
UPDATE_NOTBACK=""          # lines DATADIR<TAB>LAUNCHER of accounts that did not come back up
CLAUDES_PENDING_MAX_AGE="${CLAUDES_PENDING_MAX_AGE:-86400}"   # reopen-pending older than this is ignored
CLAUDES_NOTICE_AFTER="${CLAUDES_NOTICE_AFTER:-604800}"         # a verified download this old triggers the one-time notice
CLAUDES_TERMINAL_BACKOFF="${CLAUDES_TERMINAL_BACKOFF:-86400}"  # the watcher waits this long after asking for Terminal
CLAUDES_FIRST_LAUNCH_WAIT="${CLAUDES_FIRST_LAUNCH_WAIT:-20}"   # seconds before checking the reopened accounts are still up

claudes_open() { open "$@"; }   # every open goes through here so tests can replace it
claudes_notify() {              # TEXT -> macOS notification; tests replace it
  local t; t="$(printf '%s' "$1" | tr -d '"\\')"
  osascript -e "display notification \"$t\" with title \"claudes\"" >/dev/null 2>&1 || true
}

update_pending_file() { echo "$CLAUDES_STATE_DIR/reopen-pending"; }

# reopen-pending: header "#ts<TAB>EPOCH" and "#offset<TAB>BYTES" (ShipIt log size when we quit), then one "DATADIR<TAB>LAUNCHER" per closed account,
# then optional "#tries<TAB>DATADIR<TAB>N" lines (how many reopen attempts failed)

# -> epoch seconds written in reopen-pending, empty if none
_update_pending_ts() {
  local pf; pf="$(update_pending_file)"
  [ -f "$pf" ] || return 0
  awk -F'\t' '$1 == "#ts" { print $2; exit }' "$pf"
}

# -> status 0 when reopen-pending exists and is older than $CLAUDES_PENDING_MAX_AGE
_update_pending_expired() {
  local ts
  ts="$(_update_pending_ts)"
  case "$ts" in ''|*[!0-9]*) return 1;; esac
  [ $(( $(claudes_now) - ts )) -gt "$CLAUDES_PENDING_MAX_AGE" ]
}

# -> the account lines of reopen-pending (nothing if missing or too old)
update_pending_accounts() {
  local pf; pf="$(update_pending_file)"
  [ -f "$pf" ] || return 0
  if _update_pending_expired; then return 0; fi
  grep -v '^#' "$pf" | sed '/^$/d' || true
}

# -> ShipIt log size recorded in reopen-pending, empty if none
_update_pending_offset() {
  local pf; pf="$(update_pending_file)"
  [ -f "$pf" ] || return 0
  awk -F'\t' '$1 == "#offset" { print $2; exit }' "$pf"
}

# OFFSET -> status 0 when the ShipIt log since OFFSET shows "Beginning installation" with no completion or failure
# after it AND the ShipIt job is still running (a job that died mid-install counts as a failed install)
_update_install_started() {
  shipit_log_since "$1" 2>/dev/null | awk '
    /Beginning installation/ { b = 1; next }
    /Installation completed successfully|Installation cancelled|Installation error|Aborting update attempt|Too many attempts/ { b = 0 }
    END { exit !b }' || return 1
  shipit_waiting
}

# -> status 0 when the install that followed the quit recorded in reopen-pending may still be running
_update_pending_mid_install() {
  local off; off="$(_update_pending_offset)"
  case "$off" in
    ''|*[!0-9]*) shipit_waiting;;   # an older list without a log offset: fall back to the job state
    *) _update_install_started "$off";;
  esac
}

# DATADIR -> failed reopen attempts recorded for it (0 if none)
_update_pending_tries() {
  local pf n; pf="$(update_pending_file)"
  [ -f "$pf" ] || { echo 0; return 0; }
  n="$(awk -F'\t' -v d="$1" '$1 == "#tries" && $2 == d { print $3; exit }' "$pf")"
  echo "${n:-0}"
}

# ACCOUNTLINES [TS] [TRIESLINES] [LOGOFFSET] -> write reopen-pending (atomically)
_update_pending_write() {
  local pf ts="${2:-}"; pf="$(update_pending_file)"
  [ -n "$ts" ] || ts="$(claudes_now)"
  mkdir -p "$CLAUDES_STATE_DIR"
  { printf '#ts\t%s\n' "$ts"
    if [ -n "${4:-}" ]; then printf '#offset\t%s\n' "$4"; fi
    printf '%s\n' "$1" | sed '/^$/d'
    if [ -n "${3:-}" ]; then printf '%s\n' "$3" | sed '/^$/d'; fi
  } > "$pf.tmp"
  mv "$pf.tmp" "$pf"
}

# -> in a real run, drop a reopen-pending that is too old
_update_pending_expire() {
  local pf; pf="$(update_pending_file)"
  if [ -f "$pf" ] && _update_pending_expired; then
    echo "An old list of accounts to reopen (more than $((CLAUDES_PENDING_MAX_AGE / 3600)) hours old) was ignored and deleted."
    rm -f "$pf"
  fi
  return 0
}

# DATADIR LAUNCHER -> the name to show the user (launcher name like "Claude C", else the folder name)
update_account_name() {
  local b
  if [ -n "${2:-}" ]; then b="$(basename "$2")"; echo "${b%.app}"; else basename "$1"; fi
}

# newline-separated DATADIR<TAB>LAUNCHER lines on $1 -> "Claude A, Claude C"
update_names_of() {
  local d l out="" n
  while IFS=$'\t' read -r d l; do
    [ -n "$d" ] || continue
    n="$(update_account_name "$d" "$l")"
    if [ -n "$out" ]; then out="$out, $n"; else out="$n"; fi
  done <<EOF
$1
EOF
  printf '%s' "$out"
}

# -> keep the watcher log small: over 1 MB, keep its last 2000 lines (truncated in place, launchd keeps writing)
_update_trim_log() {
  local f="$CLAUDES_LOG_DIR/update-watcher.log" size tmp
  [ -f "$f" ] || return 0
  size="$(wc -c < "$f" | tr -d ' ')"
  [ "$size" -gt 1048576 ] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/claudes-log.XXXXXX")"
  tail -n 2000 "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
  return 0
}

# TEXT... -> print, never failing (the terminal may be gone)
_update_say() { echo "$@" 2>/dev/null || true; }

# on INT/TERM after accounts started quitting: put things back, or say who will
_update_on_interrupt() {
  set +e
  trap - INT TERM HUP
  _update_say
  _update_say "Interrupted."
  if _update_install_started "$UPDATE_LOG_OFFSET"; then
    _update_say "Claude's installer is running. The next 'claudes update' (or the background helper) will reopen your accounts."
    _update_say "They are listed in $(update_pending_file)."
  else
    _update_say "Reopening the accounts that were closed."
    update_reopen_accounts || true
  fi
  update_unlock
  exit 1
}

# on HUP (the Terminal was closed): do not stop half way; keep going and write to a log instead
_update_on_hup() {
  mkdir -p "$CLAUDES_LOG_DIR" 2>/dev/null || true
  exec >> "$CLAUDES_LOG_DIR/update.log" 2>&1 || true
  _update_say "The Terminal was closed. Carrying on with the update; this output goes to $CLAUDES_LOG_DIR/update.log."
}

# [--dry-run] [--watch-run] -> find, download, verify and install a new Claude, then reopen accounts; exit status 0/1
cmd_update() {
  local dry=0 watch=0 arg rc=0
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry=1;;
      --watch-run) watch=1;;
      *) echo "claudes update: unknown option '$arg'" >&2
         echo "usage: claudes update [--dry-run] [--watch-run]" >&2
         return 1;;
    esac
  done
  UPDATE_DRY="$dry"; UPDATE_WATCH="$watch"; UPDATE_WAITING=0
  CLAUDES_IDLE_READONLY="$dry"; export CLAUDES_IDLE_READONLY   # a dry run only reads the idle countdown
  if [ "$dry" = 0 ]; then trap '' PIPE; fi   # a vanished Terminal must not kill the run half way

  # a blocked updater is the healthy state (the dry run and doctor mention it); an open one gets one plain warning
  UPDATE_BLOCKED_FILE=""
  if ! UPDATE_BLOCKED_FILE="$(auto_updates_blocked)"; then
    UPDATE_BLOCKED_FILE=""
    if [ "$watch" = 0 ] && [ "$dry" = 0 ]; then claudes_block_off_text || true; fi
  fi

  if [ "$dry" = 0 ] && inside_claude_copy; then
    echo "This command is running inside a Claude window. Quitting Claude would stop it half way and nothing would reopen your accounts."
    echo "Run it from Terminal instead, not from inside Claude."
    trap - PIPE
    return 1
  fi

  if [ "$dry" = 1 ]; then
    _update_run || rc=$?
    return "$rc"
  fi

  if [ "$watch" = 1 ]; then _update_trim_log; fi
  if ! update_lock; then
    echo "Another claudes update is already in progress, so this one is stopping. Nothing was changed."
    trap - PIPE
    return 0
  fi
  _update_run || rc=$?
  trap - INT TERM HUP PIPE
  update_unlock
  return "$rc"
}

# -> the flow after the checks: recover, then either Claude's own waiting installer or claudes' own download; status 0/1
_update_run() {
  local state pending names
  [ "$UPDATE_DRY" = 1 ] || _update_pending_expire
  state="$(update_state 2>/dev/null || true)"

  # a previous run that was interrupted leaves its list of accounts behind
  pending="$(update_pending_accounts)"
  if [ -n "$pending" ] && [ "$state" != waiting ] && ! _update_pending_mid_install; then
    names="$(update_names_of "$pending")"
    if [ "$UPDATE_DRY" = 1 ]; then
      echo "A previous update run was interrupted. It would reopen: $names"
    else
      echo "A previous update run was interrupted. Reopening: $names"
      update_reopen_accounts || true
    fi
  fi

  if [ "$state" = waiting ]; then
    _update_run_waiting_installer
  else
    _update_run_release
  fi
}

# VERSION -> the version, or "unknown" so messages never show an empty name
_update_v() { echo "${1:-unknown}"; }

# EPOCH -> a readable date
_update_date() { date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$1"; }

# -> dry run: the newest version from the cache or a fresh check, without writing anything to the state folder.
#    Prints the version; status 0 newer than installed, 1 not newer, 2 unknown.
_update_peek_release() {
  local tmp out rc=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/claudes-peek.XXXXXX")"
  if [ -f "$CLAUDES_STATE_DIR/release-check" ]; then cp "$CLAUDES_STATE_DIR/release-check" "$tmp/release-check"; fi
  out="$( CLAUDES_STATE_DIR="$tmp"; export CLAUDES_STATE_DIR
          v="$(release_check 2>/dev/null)" || exit 2
          echo "$v"; release_is_newer 2>/dev/null || exit 1 )" || rc=$?
  rm -rf "$tmp"
  printf '%s\n' "$out"
  return "$rc"
}

# the claudes download flow: check the newest Claude, download and verify it, wait until every account is idle, install
_update_run_release() {
  local newest="" rc=0 installed ready_v="" dry_rc=0
  installed="$(main_version 2>/dev/null || true)"

  if [ "$UPDATE_DRY" = 1 ]; then
    echo "Installed Claude: $(_update_v "$installed")"
    newest="$(_update_peek_release)" || dry_rc=$?
    echo "Newest Claude: $(_update_v "$newest")"
    ready_v="$(release_ready_version 2>/dev/null || true)"
    if [ -n "$ready_v" ] && release_ready_app >/dev/null 2>&1; then
      echo "Verified download waiting: yes (version $ready_v)"
    else
      ready_v=""
      echo "Verified download waiting: no"
    fi
    if [ -n "$UPDATE_BLOCKED_FILE" ]; then
      echo "Claude's own updater: blocked by $UPDATE_BLOCKED_FILE (expected)"
    else
      echo "Claude's own updater: ON, so Claude may close accounts by itself. To stop that, install the block profile."
    fi
    if [ "$dry_rc" = 2 ]; then
      echo "Could not find out the newest Claude version (no internet?)."
      _update_dry_report
      return 0
    fi
    if [ "$dry_rc" = 1 ]; then
      echo "Claude is up to date ($(_update_v "$installed"))."
      _update_dry_report
      return 0
    fi
    if [ -z "$ready_v" ]; then
      echo "It would download Claude $newest and check it before using it."
    fi
    UPDATE_ACCOUNTS="$(update_open_accounts)"
    _update_print_plan "$(update_all_idle || true)" release
    return 0
  fi

  if ! newest="$(release_check)"; then
    echo "Could not find out the newest Claude version. Nothing was changed."
    if [ "$UPDATE_WATCH" = 1 ]; then return 0; fi
    return 1
  fi
  if ! release_is_newer; then
    echo "Claude is up to date ($(_update_v "$installed"))."
    if [ -n "$(release_ready_version 2>/dev/null || true)" ]; then release_discard || true; fi   # a leftover download of an older version
    update_safety_net
    return 0
  fi

  echo "Claude $newest is available (you have $(_update_v "$installed"))."
  if ! release_prepare; then
    echo "The new Claude could not be downloaded and checked, so nothing was quit."
    return 1
  fi

  _update_week_notice

  # the background helper cannot ask macOS for permission to replace the app, so it leaves that part to Terminal
  if [ "$UPDATE_WATCH" = 1 ]; then
    if _update_terminal_backoff; then return 0; fi
    if ! install_shipit_path >/dev/null 2>&1; then
      _update_needs_terminal
      return 0
    fi
  fi

  UPDATE_WAITING=1
  _update_wait_idle ready || rc=$?
  [ "$rc" = 0 ] || return 0

  _update_install_and_reopen
}

# -> once per version, a notice when the verified download has waited 7 days
_update_week_notice() {
  local first notified now
  first="$(release_ready_get first_seen 2>/dev/null || true)"
  notified="$(release_ready_get notified 2>/dev/null || true)"
  case "$first" in ''|*[!0-9]*) return 0;; esac
  [ -z "$notified" ] || return 0
  now="$(claudes_now)"
  if [ $((now - first)) -gt "$CLAUDES_NOTICE_AFTER" ]; then
    claudes_notify "A Claude update has been waiting 7 days because your accounts are never all idle at once. Run claudes update in Terminal to see what is busy."
    release_ready_set notified "$now" || true
  fi
  return 0
}

# -> status 0 while a watcher run should stay quiet because it already asked for Terminal less than 24 hours ago
_update_terminal_backoff() {
  local at
  at="$(release_ready_get needs_terminal 2>/dev/null || true)"
  case "$at" in ''|*[!0-9]*) return 1;; esac
  [ $(( $(claudes_now) - at )) -lt "$CLAUDES_TERMINAL_BACKOFF" ]
}

# -> the watcher cannot finish this update: tell the user once, and do not try again for 24 hours
_update_needs_terminal() {
  echo "The new Claude is ready, but replacing the app needs Terminal. Run claudes update in Terminal to finish."
  claudes_notify "Claude update ready — run claudes update in Terminal to finish"
  release_ready_set needs_terminal "$(claudes_now)" || true
}

# KIND(ready|waiting) -> real runs only: wait until every open account is idle, with no time limit.
#    Status 0 go ahead and quit; 2 stop here and report success (busy under the watcher, or the update went away).
_update_wait_idle() {
  local kind="$1" busy last="" state
  while :; do
    UPDATE_ACCOUNTS="$(update_open_accounts)"
    if busy="$(update_all_idle)"; then return 0; fi
    if [ "$UPDATE_WATCH" = 1 ]; then
      echo "$busy"
      echo "Not updating now. The background helper will try again later."
      return 2
    fi
    if [ "$busy" != "$last" ]; then
      echo "$busy"
      last="$busy"
      echo "Waiting until every account is idle. Checking again every $CLAUDES_POLL seconds."
    fi
    claudes_sleep "$CLAUDES_POLL"
    if [ "$kind" = waiting ]; then
      state="$(update_state 2>/dev/null || true)"
      if [ "$state" != waiting ]; then
        echo "The update is no longer waiting. Nothing was quit."
        return 2
      fi
    elif ! release_ready_app >/dev/null 2>&1; then
      echo "The downloaded update is gone (Claude may have been updated another way). Nothing was quit."
      return 2
    fi
  done
}

# -> every account is idle: quit them together, install the verified Claude, reopen, and check the first launch; status 0/1
_update_install_and_reopen() {
  local newapp old_ver old_build d l up=0 reopen_rc=0
  newapp="$(release_ready_app)" || { echo "The downloaded update is gone. Nothing was quit."; return 1; }

  if [ -z "$UPDATE_ACCOUNTS" ]; then echo "No Claude copy is open, so nothing needs quitting."; fi
  if ! update_quit_all; then
    echo "The update was not started. Reopening the accounts that were closed."
    update_reopen_accounts || true
    return 1
  fi
  old_ver="$UPDATE_OLD_VERSION"; old_build="$UPDATE_OLD_BUILD"

  if ! install_new "$newapp"; then
    echo "The new Claude could not be installed. Reopening your accounts on the old version."
    update_reopen_accounts || true
    if [ "$UPDATE_WATCH" = 1 ]; then _update_needs_terminal; fi
    return 1
  fi
  update_reopen_accounts || reopen_rc=1

  # a new version that crashes at once would leave every account closed: look again after a short wait
  if [ -n "$UPDATE_ACCOUNTS" ]; then
    claudes_sleep "$CLAUDES_FIRST_LAUNCH_WAIT"
    while IFS=$'\t' read -r d l; do
      [ -n "$d" ] || continue
      if datadir_running "$d"; then up=1; fi
    done <<EOF
$UPDATE_ACCOUNTS
EOF
    if [ "$up" = 0 ]; then
      echo "None of your accounts stayed open on the new Claude. Putting the old version back."
      if install_rollback; then
        _update_pending_write "$UPDATE_ACCOUNTS" "" "" "$UPDATE_LOG_OFFSET"
        update_reopen_accounts || true
        echo "Your accounts were reopened on the old version."
      else
        echo "The old version could not be put back by claudes. Your accounts are closed; see the message above."
      fi
      return 1
    fi
  fi

  install_finish || true
  release_discard || true
  rm -f "$CLAUDES_STATE_DIR/idle-since"
  echo "Claude updated: $(_update_ver "$old_ver" "$old_build") -> $(_update_ver "$(main_version 2>/dev/null || true)" "$(installed_build 2>/dev/null || true)")"
  if [ "$UPDATE_WATCH" = 0 ]; then update_safety_net; fi
  return "$reopen_rc"
}

# Claude's own installer is already waiting (only possible with the block off): wait idle, quit, let it install, reopen
_update_run_waiting_installer() {
  local old new rc=0
  UPDATE_WAITING=1
  old="$(installed_build 2>/dev/null || true)"; new="$(staged_build 2>/dev/null || true)"
  echo "A Claude update is waiting to install (build ${old:-?} -> ${new:-?})."

  if [ "$UPDATE_DRY" = 1 ]; then
    UPDATE_ACCOUNTS="$(update_open_accounts)"
    _update_print_plan "$(update_all_idle || true)" waiting
    return 0
  fi
  _update_wait_idle waiting || rc=$?
  [ "$rc" = 0 ] || return 0

  if [ -z "$UPDATE_ACCOUNTS" ]; then
    echo "No Claude copy is open, so Claude's installer can run by itself."
  fi
  if ! update_quit_all; then
    echo "The update was not started. Reopening the accounts that were closed."
    update_reopen_accounts || true
    return 1
  fi

  local install_ok=0 reopen_rc=0
  update_wait_install || install_ok=1
  if [ "$install_ok" = 0 ]; then
    update_close_plain_relaunch || true
  fi
  update_reopen_accounts || reopen_rc=1

  if [ "$install_ok" = 1 ]; then
    echo "The update did not install. Your accounts were reopened on the old version."
    return 1
  fi
  echo "Claude updated: $(_update_ver "$UPDATE_OLD_VERSION" "$UPDATE_OLD_BUILD") -> $(_update_ver "$(main_version 2>/dev/null || true)" "$(installed_build 2>/dev/null || true)")"
  if [ "$UPDATE_WATCH" = 0 ]; then update_safety_net; fi
  return "$reopen_rc"
}

# dry run only: show what the tool sees (open accounts, idle status, Claude's rules) even with nothing to install
_update_dry_report() {
  local busy=""
  [ "$UPDATE_DRY" = 1 ] || return 0
  UPDATE_ACCOUNTS="$(update_open_accounts)"
  busy="$(update_all_idle || true)"
  _update_print_accounts "$busy"
  echo
  idle_rules_report || true
  echo
  echo "Accounts that quit for an update and did not come back:"
  update_safety_net
  echo
  echo "Dry run: nothing was quit, opened or changed."
  return 0
}

# VERSION BUILD -> "1.2.3 (build 456)"
_update_ver() { echo "${1:-?} (build ${2:-?})"; }

# BUSYTEXT -> prints the open accounts and each one's idle status
_update_print_accounts() {
  local busy="$1" d l n line
  echo
  echo "Open accounts:"
  if [ -z "$UPDATE_ACCOUNTS" ]; then echo "  none"; fi
  while IFS=$'\t' read -r d l; do
    [ -n "$d" ] || continue
    n="$(update_account_name "$d" "$l")"
    line="$(grep -F -- "$n is busy" <<<"$busy" | head -n 1 || true)"
    if [ -n "$line" ]; then echo "  $line"; else echo "  $n: idle"; fi
  done <<EOF
$UPDATE_ACCOUNTS
EOF
}

# BUSYTEXT KIND(release|waiting) -> prints the dry-run plan
_update_print_plan() {
  local busy="$1" kind="$2" d l n how
  _update_print_accounts "$busy"
  echo
  echo "What claudes update would do:"
  if [ -n "$busy" ]; then
    echo "  1. Wait until every open account is idle (right now it would wait, see above)."
  else
    echo "  1. Wait until every open account is idle (they all are right now)."
  fi
  echo "  2. Quit these together: $(update_names_of "$UPDATE_ACCOUNTS")"
  if [ "$kind" = release ]; then
    echo "  3. Hand the checked Claude to Claude's own installer (or move the app into place if that is not possible)."
  else
    echo "  3. Let Claude's installer run, then close the plain Claude it opens afterwards."
  fi
  echo "  4. Reopen each account:"
  while IFS=$'\t' read -r d l; do
    [ -n "$d" ] || continue
    n="$(update_account_name "$d" "$l")"
    if [ -n "$l" ]; then how="from its own launcher"; else how="with the plain Claude icon (no launcher)"; fi
    echo "       $n, $how"
  done <<EOF
$UPDATE_ACCOUNTS
EOF
  if [ "$kind" = release ]; then
    echo "  5. Check that the accounts are still open $CLAUDES_FIRST_LAUNCH_WAIT seconds later; if none are, put the old Claude back."
  fi
  echo
  idle_rules_report || true
  echo
  echo "Dry run: nothing was quit, opened or changed."
}

# -> prints update/watcher/launcher lines for claudes doctor; always status 0
doctor_update_report() {
  local p state pid d v rv first
  echo "Claude installed: $(_update_v "$(main_version 2>/dev/null || true)")"
  if v="$(release_check 2>/dev/null)"; then
    echo "newest released Claude: $v"
  else
    echo "newest released Claude: unknown (could not check)"
  fi
  rv="$(release_ready_version 2>/dev/null || true)"
  if [ -n "$rv" ] && release_ready_app >/dev/null 2>&1; then
    first="$(release_ready_get first_seen 2>/dev/null || true)"
    case "$first" in
      ''|*[!0-9]*) echo "verified download waiting: yes (version $rv)";;
      *) echo "verified download waiting: yes (version $rv, since $(_update_date "$first"))";;
    esac
  else
    echo "verified download waiting: no"
  fi
  if p="$(auto_updates_blocked 2>/dev/null)"; then
    echo "auto-updates: block on (expected), set by $p"
  else
    echo "auto-updates: block OFF — Claude's own updater may close accounts by itself"
  fi
  state="$(update_state 2>/dev/null || true)"
  case "$state" in
    waiting) echo "Claude's own installer: update waiting";;
    no-installer) echo "Claude's own installer: update downloaded but installer not waiting";;
  esac
  if [ -f "$CLAUDES_LAUNCHAGENTS_DIR/${CLAUDES_WATCH_LABEL:-}.plist" ]; then
    if launchctl print "gui/$(id -u)/${CLAUDES_WATCH_LABEL:-}" >/dev/null 2>&1; then
      echo "watcher: installed and loaded"
    else
      echo "watcher: installed, not loaded"
    fi
  else
    echo "watcher: not installed"
  fi
  while IFS=$'\t' read -r pid d; do
    [ -n "$d" ] || continue
    if [ -z "$(launcher_for "$d" 2>/dev/null || true)" ]; then
      echo "note: $d is open without a launcher; after an update it reopens with the plain Claude icon"
    fi
  done < <(claude_main_procs 2>/dev/null || true)
  return 0
}

# -> seconds since ShipItState.plist was written (the waiting update); status 1 if it is missing
update_staged_age() {
  local f="$CLAUDES_SHIPIT_DIR/ShipItState.plist" m
  [ -f "$f" ] || return 1
  m="$(stat -f %m "$f")" || return 1
  echo $(( $(date +%s) - m ))
}

# -> lines DATADIR<TAB>LAUNCHER for running accounts plus accounts down with an update marker.
#    While an update is waiting, a marker counts up to the age of the update itself (or the normal limit, whichever is larger).
update_open_accounts() {
  local nl seen pid d l age limit staged_age
  nl=$'\n'; seen="$nl"
  while IFS=$'\t' read -r pid d; do
    [ -n "$d" ] || continue
    case "$seen" in *"$nl$d$nl"*) continue;; esac
    seen="$seen$d$nl"
    printf '%s\t%s\n' "$d" "$(launcher_for "$d" 2>/dev/null || true)"
  done < <(claude_main_procs 2>/dev/null || true)

  while IFS=$'\t' read -r d l; do
    [ -n "$d" ] || continue
    case "$seen" in *"$nl$d$nl"*) continue;; esac
    if datadir_running "$d"; then continue; fi
    marker_says_update_quit "$d" || continue
    age="$(marker_age "$d" 2>/dev/null || true)"
    case "$age" in ''|*[!0-9]*) continue;; esac
    limit="$CLAUDES_MARKER_MAX_AGE"
    if [ "$UPDATE_WAITING" = 1 ]; then
      # while an update waits, any marker newer than that update counts, however old
      staged_age="$(update_staged_age 2>/dev/null || true)"
      # the plist is rewritten by every copy's download, so it can look newer than a real self-quit
      case "$staged_age" in ''|*[!0-9]*) ;; *) [ "$staged_age" -le "$limit" ] || limit="$staged_age";; esac
    fi
    [ "$age" -le "$limit" ] || continue
    seen="$seen$d$nl"
    printf '%s\t%s\n' "$d" "$l"
  done < <(known_accounts 2>/dev/null || true)

  # accounts a half-finished run already closed
  while IFS=$'\t' read -r d l; do
    [ -n "$d" ] || continue
    case "$seen" in *"$nl$d$nl"*) continue;; esac
    seen="$seen$d$nl"
    printf '%s\t%s\n' "$d" "$l"
  done < <(update_pending_accounts)
  return 0
}

# -> status 0 when every account in $UPDATE_ACCOUNTS has been idle for the full countdown; prints "NAME is busy: reason" lines otherwise
update_all_idle() {
  local tmp i=0 d l n rc reason busy=0
  [ -n "$UPDATE_ACCOUNTS" ] || return 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/claudes-idle.XXXXXX")"
  while IFS=$'\t' read -r d l; do
    [ -n "$d" ] || continue
    i=$((i + 1))
    ( rc=0; reason="$(account_idle_settled "$d")" || rc=$?
      echo "$rc" > "$tmp/$i.rc"; printf '%s' "$reason" > "$tmp/$i.reason" ) </dev/null &
  done <<EOF
$UPDATE_ACCOUNTS
EOF
  wait
  i=0
  while IFS=$'\t' read -r d l; do
    [ -n "$d" ] || continue
    i=$((i + 1))
    rc="$(cat "$tmp/$i.rc" 2>/dev/null || echo 1)"
    if [ "$rc" != 0 ]; then
      n="$(update_account_name "$d" "$l")"
      reason="$(cat "$tmp/$i.reason" 2>/dev/null || true)"
      if [ -n "$reason" ]; then echo "$n is busy: $reason"; else echo "$n is busy."; fi
      busy=1
    fi
  done <<EOF
$UPDATE_ACCOUNTS
EOF
  rm -rf "$tmp"
  return "$busy"
}

# -> write reopen-pending, record build and log offset, stop every open account together; status 1 if any copy is still running
update_quit_all() {
  local pf tmp i=0 d l n fail=0 kept="" rc pids="" p running
  pf="$(update_pending_file)"
  UPDATE_OLD_BUILD="$(installed_build 2>/dev/null || true)"
  UPDATE_OLD_VERSION="$(main_version 2>/dev/null || true)"
  UPDATE_LOG_OFFSET="$(shipit_log_size 2>/dev/null || echo 0)"
  case "$UPDATE_LOG_OFFSET" in ''|*[!0-9]*) UPDATE_LOG_OFFSET=0;; esac
  _update_pending_write "$UPDATE_ACCOUNTS" "" "" "$UPDATE_LOG_OFFSET"
  trap '_update_on_interrupt' INT TERM
  trap '_update_on_hup' HUP
  trap '' PIPE

  [ -z "$UPDATE_ACCOUNTS" ] || echo "Quitting together: $(update_names_of "$UPDATE_ACCOUNTS")"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/claudes-stop.XXXXXX")"
  while IFS=$'\t' read -r d l; do
    [ -n "$d" ] || continue
    i=$((i + 1))
    ( trap '' HUP   # closing the Terminal must not cut a shutdown short
      if stop_datadir "$d" "$CLAUDES_STOP_TIMEOUT"; then echo 0; else echo 1; fi > "$tmp/$i.rc" ) </dev/null &
    pids="$pids $!"
  done <<EOF
$UPDATE_ACCOUNTS
EOF
  # wait until every stopper has really exited (a plain `wait` returns early when a signal arrives)
  while :; do
    running=0
    for p in $pids; do
      if kill -0 "$p" 2>/dev/null; then running=1; fi
    done
    [ "$running" = 1 ] || break
    claudes_sleep 1
  done
  wait 2>/dev/null || true
  i=0
  while IFS=$'\t' read -r d l; do
    [ -n "$d" ] || continue
    i=$((i + 1))
    rc="$(cat "$tmp/$i.rc" 2>/dev/null || echo 1)"
    n="$(update_account_name "$d" "$l")"
    # "closed" means the main Claude process is gone; leftover helpers are only a warning
    if datadir_running "$d"; then
      echo "$n would not quit, even when forced."
      fail=1
    else
      kept="$kept$d"$'\t'"$l"$'\n'
      if [ "$rc" != 0 ]; then echo "Some leftover parts of $n are still running. Going on anyway."; fi
    fi
  done <<EOF
$UPDATE_ACCOUNTS
EOF
  rm -rf "$tmp"
  if [ "$fail" = 1 ]; then
    _update_pending_write "$kept" "$(_update_pending_ts)" "" "$UPDATE_LOG_OFFSET"   # every account that did close stays listed until it is back
  fi
  return "$fail"
}

# -> poll ShipIt up to $CLAUDES_INSTALL_TIMEOUT; status 0 on success, 1 on failure/timeout (prints matching log lines)
update_wait_install() {
  local waited=0 build log hits
  echo "Waiting for Claude's installer to finish..."
  while :; do
    build="$(installed_build 2>/dev/null || true)"
    log="$(shipit_log_since "$UPDATE_LOG_OFFSET" 2>/dev/null || true)"
    case "$log" in *'Installation completed successfully'*) return 0;; esac
    # a changed build alone is not enough: the installer may still be copying files
    if [ -n "$build" ] && [ "$build" != "$UPDATE_OLD_BUILD" ] && ! shipit_waiting; then
      return 0
    fi
    hits="$(grep -E 'Aborting update attempt|Installation cancelled|Installation error|Too many attempts' <<<"$log" || true)"
    if [ -n "$hits" ]; then
      echo "Claude's installer failed. Its log says:"
      printf '%s\n' "$hits" | sed 's/^/  /'
      return 1
    fi
    if [ "$waited" -ge "$CLAUDES_INSTALL_TIMEOUT" ]; then
      echo "Claude's installer did not finish within $((CLAUDES_INSTALL_TIMEOUT / 60)) minutes ($CLAUDES_INSTALL_TIMEOUT seconds)."
      if [ -n "$log" ]; then
        echo "The last thing its log said:"
        printf '%s\n' "$log" | tail -n 3 | sed 's/^/  /'
      else
        echo "Its log has not said anything new."
      fi
      return 1
    fi
    claudes_sleep 2
    waited=$((waited + 2))
  done
}

# -> stop the plain copy ShipIt relaunches when it is not wanted; status 0
update_close_plain_relaunch() {
  local def="$CLAUDES_SUPPORT_DIR/Claude" waited=0 seen_at="" d l in_pending=0 launcher="" log
  # wait for the plain copy: up to 10 more seconds after the installer says it launched Claude
  while [ "$waited" -lt 30 ]; do
    if datadir_running "$def"; then break; fi
    if [ -z "$seen_at" ]; then
      log="$(shipit_log_since "$UPDATE_LOG_OFFSET" 2>/dev/null || true)"
      case "$log" in *'Successfully launched application'*) seen_at="$waited";; esac
    fi
    if [ -n "$seen_at" ] && [ $((waited - seen_at)) -ge 10 ]; then break; fi
    if [ -z "$seen_at" ] && [ "$waited" -ge 20 ]; then break; fi
    claudes_sleep 2
    waited=$((waited + 2))
  done
  datadir_running "$def" || return 0

  while IFS=$'\t' read -r d l; do
    if [ "$d" = "$def" ]; then in_pending=1; launcher="$l"; fi
  done < <(update_pending_accounts)
  [ -n "$launcher" ] || launcher="$(launcher_for "$def" 2>/dev/null || true)"

  # a plain copy is only wanted when the default folder was open before and has no launcher
  if [ -n "$launcher" ] || [ "$in_pending" = 0 ]; then
    echo "Closing the plain Claude that the installer opened."
    if ! stop_datadir "$def" "$CLAUDES_STOP_TIMEOUT"; then
      echo "The plain Claude would not close. Leaving it open."
    fi
  else
    echo "Leaving the plain Claude that the installer opened running, because it was open before."
  fi
  return 0
}

# FILE -> reopen every DATADIR<TAB>LAUNCHER line in FILE and confirm each is running.
#    Status 1 if any did not come up; those are listed in $UPDATE_NOTBACK.
_update_reopen_file() {
  local f="$1" d l n first=1 tries failed="" nl
  nl=$'\n'
  UPDATE_NOTBACK=""
  while IFS=$'\t' read -r d l; do
    [ -n "$d" ] || continue
    n="$(update_account_name "$d" "$l")"
    if datadir_running "$d"; then
      echo "$n is already open."
      continue
    fi
    if [ "$first" = 0 ]; then claudes_sleep 2; fi
    first=0
    if [ -n "$l" ]; then
      echo "Reopening $n from its launcher."
      claudes_open "$l" </dev/null || { echo "Could not open $n."; failed="$failed$d$nl"; }
    elif [ "$d" = "$CLAUDES_SUPPORT_DIR/Claude" ]; then
      echo "Reopening Claude (plain, no launcher)."
      claudes_open -n -a "$CLAUDES_APP_SRC" </dev/null || { echo "Could not open Claude."; failed="$failed$d$nl"; }
    else
      echo "Reopening $n. It has no launcher, so its Dock icon will be the plain Claude icon."
      claudes_open -n -a "$CLAUDES_APP_SRC" --args "--user-data-dir=$d" </dev/null || { echo "Could not open $n."; failed="$failed$d$nl"; }
    fi
  done < "$f"

  while IFS=$'\t' read -r d l; do
    [ -n "$d" ] || continue
    n="$(update_account_name "$d" "$l")"
    tries=0
    while ! datadir_running "$d"; do
      if [ "$tries" -ge 15 ] || { case "$nl$failed" in *"$nl$d$nl"*) true;; *) false;; esac; }; then
        echo "$n did not come back up."
        UPDATE_NOTBACK="$UPDATE_NOTBACK$d"$'\t'"$l"$'\n'
        break
      fi
      claudes_sleep 2
      tries=$((tries + 1))
    done
  done < "$f"
  [ -z "$UPDATE_NOTBACK" ]
}

# -> reopen every account in reopen-pending and confirm each is running; status 1 if any did not come up.
#    Accounts that did not come up stay in reopen-pending (3 tries, then dropped).
update_reopen_accounts() {
  local pf accounts tmp d l t keep="" tries_lines="" ts off
  pf="$(update_pending_file)"
  [ -f "$pf" ] || return 0
  accounts="$(update_pending_accounts)"
  if [ -z "$accounts" ]; then rm -f "$pf"; return 0; fi
  ts="$(_update_pending_ts)"; off="$(_update_pending_offset)"
  tmp="$(mktemp "$CLAUDES_STATE_DIR/reopen-list.XXXXXX")"
  printf '%s\n' "$accounts" > "$tmp"
  _update_reopen_file "$tmp" || true
  rm -f "$tmp"
  if [ -z "$UPDATE_NOTBACK" ]; then rm -f "$pf"; return 0; fi

  while IFS=$'\t' read -r d l; do
    [ -n "$d" ] || continue
    t=$(( $(_update_pending_tries "$d") + 1 ))
    if [ "$t" -ge 3 ]; then
      echo "Giving up on $(update_account_name "$d" "$l") after 3 tries. Open it yourself from the Dock or Launchpad."
    else
      keep="$keep$d"$'\t'"$l"$'\n'
      tries_lines="$tries_lines#tries"$'\t'"$d"$'\t'"$t"$'\n'
    fi
  done <<EOF
$UPDATE_NOTBACK
EOF
  if [ -n "$keep" ]; then
    _update_pending_write "$keep" "$ts" "$tries_lines" "$off"
    echo "Kept it on the list; the next claudes update will try again."
  else
    rm -f "$pf"
  fi
  if [ "$UPDATE_WATCH" = 1 ]; then
    claudes_notify "Could not reopen: $(update_names_of "$UPDATE_NOTBACK"). Open it from the Dock."
  fi
  return 1
}

# -> reopen accounts that quit for an update but never came back; status 0
update_safety_net() {
  local d l age n tmp="" state found=0
  state="$(update_state 2>/dev/null || true)"
  if [ "$state" = waiting ] || shipit_waiting; then return 0; fi
  if [ "$UPDATE_DRY" != 1 ]; then
    mkdir -p "$CLAUDES_STATE_DIR"
    tmp="$(mktemp "$CLAUDES_STATE_DIR/reopen-net.XXXXXX")"
  fi
  while IFS=$'\t' read -r d l; do
    [ -n "$d" ] || continue
    if datadir_running "$d"; then continue; fi
    marker_says_update_quit "$d" || continue
    age="$(marker_age "$d" 2>/dev/null || true)"
    case "$age" in ''|*[!0-9]*) continue;; esac
    [ "$age" -ge "$CLAUDES_MARKER_GRACE" ] || continue
    [ "$age" -le "$CLAUDES_MARKER_MAX_AGE" ] || continue
    n="$(update_account_name "$d" "$l")"
    found=1
    if [ "$UPDATE_DRY" = 1 ]; then
      echo "Would reopen $n: it quit for an update $((age / 60)) minutes ago and did not come back."
    else
      echo "$n quit for an update $((age / 60)) minutes ago and did not come back."
      printf '%s\t%s\n' "$d" "$l" >> "$tmp"
    fi
  done < <(known_accounts 2>/dev/null || true)
  if [ "$UPDATE_DRY" = 1 ]; then
    if [ "$found" = 0 ]; then echo "  none"; fi
  else
    if [ "$found" = 1 ]; then
      if ! _update_reopen_file "$tmp" && [ "$UPDATE_WATCH" = 1 ]; then
        claudes_notify "Could not reopen: $(update_names_of "$UPDATE_NOTBACK"). Open it from the Dock."
      fi
    fi
    rm -f "$tmp"
  fi
  return 0
}

# -> take $CLAUDES_STATE_DIR/update.lock (pid file inside); status 1 if busy
update_lock() {
  local lock="$CLAUDES_STATE_DIR/update.lock" pid
  mkdir -p "$CLAUDES_STATE_DIR"
  if ! mkdir "$lock" 2>/dev/null; then
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -z "$pid" ]; then   # the other run may be between mkdir and writing its pid
      claudes_sleep 1
      pid="$(cat "$lock/pid" 2>/dev/null || true)"
    fi
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 1; fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || return 1
  fi
  echo $$ > "$lock/pid"
  return 0
}

# -> release the update lock
update_unlock() { rm -rf "$CLAUDES_STATE_DIR/update.lock"; return 0; }
