#!/bin/bash
# lib/update.sh — claudes update. Source, do not execute.

# globals shared by the step functions (cmd_update sets them)
UPDATE_DRY=0               # 1 = dry run: never signal, open, write state or lock
UPDATE_WATCH=0             # 1 = run by the background watcher (also needs the Mac idle)
UPDATE_WAITING=0           # 1 = an update is waiting to install (markers of any age count)
UPDATE_ACCOUNTS=""         # lines DATADIR<TAB>LAUNCHER for the accounts being handled
UPDATE_OLD_BUILD=""        # installed build before the quit
UPDATE_OLD_VERSION=""      # installed version before the quit
UPDATE_LOG_OFFSET=0        # ShipIt log size before the quit
UPDATE_NOTBACK=""          # lines DATADIR<TAB>LAUNCHER of accounts that did not come back up
CLAUDES_PENDING_MAX_AGE="${CLAUDES_PENDING_MAX_AGE:-86400}"   # reopen-pending older than this is ignored

claudes_open() { open "$@"; }   # every open goes through here so tests can replace it
claudes_now() { date +%s; }     # seconds since the epoch; tests replace it
claudes_notify() {              # TEXT -> macOS notification; tests replace it
  local t; t="$(printf '%s' "$1" | tr -d '"\\')"
  osascript -e "display notification \"$t\" with title \"claudes\"" >/dev/null 2>&1 || true
}

update_pending_file() { echo "$CLAUDES_STATE_DIR/reopen-pending"; }

# reopen-pending: first line "#ts<TAB>EPOCH", then one "DATADIR<TAB>LAUNCHER" per closed account,
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

# DATADIR -> failed reopen attempts recorded for it (0 if none)
_update_pending_tries() {
  local pf n; pf="$(update_pending_file)"
  [ -f "$pf" ] || { echo 0; return 0; }
  n="$(awk -F'\t' -v d="$1" '$1 == "#tries" && $2 == d { print $3; exit }' "$pf")"
  echo "${n:-0}"
}

# ACCOUNTLINES [TS] [TRIESLINES] -> write reopen-pending (atomically)
_update_pending_write() {
  local pf ts="${2:-}"; pf="$(update_pending_file)"
  [ -n "$ts" ] || ts="$(claudes_now)"
  mkdir -p "$CLAUDES_STATE_DIR"
  { printf '#ts\t%s\n' "$ts"
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

# on INT/TERM/HUP after accounts started quitting: put things back, or say who will
_update_on_interrupt() {
  trap - INT TERM HUP
  echo
  echo "Interrupted."
  if shipit_waiting; then
    echo "Claude's installer is running. The next 'claudes update' (or the background helper) will reopen your accounts."
    echo "They are listed in $(update_pending_file)."
  else
    echo "Reopening the accounts that were closed."
    update_reopen_accounts || true
  fi
  update_unlock
  exit 1
}

# [--dry-run] [--watch-run] -> install a waiting Claude update and reopen accounts; exit status 0/1
cmd_update() {
  local dry=0 watch=0 arg blocked rc=0
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

  if blocked="$(auto_updates_blocked)"; then
    echo "Claude's own updater is switched off by this file:"
    echo "  $blocked"
    echo "claudes update works with Claude's own updater, so it needs the updater on. Nothing was changed."
    if [ "$dry" = 1 ]; then return 0; fi
    return 1
  fi

  if [ "$dry" = 0 ] && inside_claude_copy; then
    echo "This command is running inside a Claude window. Quitting Claude would stop it half way and nothing would reopen your accounts."
    echo "Run it from Terminal instead, not from inside Claude."
    return 1
  fi

  if [ "$dry" = 1 ]; then
    _update_run || rc=$?
    return "$rc"
  fi

  if [ "$watch" = 1 ]; then _update_trim_log; fi
  if ! update_lock; then
    echo "Another claudes update is already in progress, so this one is stopping. Nothing was changed."
    return 0
  fi
  _update_run || rc=$?
  trap - INT TERM HUP
  update_unlock
  return "$rc"
}

# -> the flow after the checks: recover, look at the update, wait for idle, quit, install, reopen; status 0/1
_update_run() {
  local state busy old new pending names start elapsed
  [ "$UPDATE_DRY" = 1 ] || _update_pending_expire
  state="$(update_state 2>/dev/null || true)"

  # a previous run that was interrupted leaves its list of accounts behind
  pending="$(update_pending_accounts)"
  if [ -n "$pending" ] && [ "$state" != waiting ] && ! shipit_waiting; then
    names="$(update_names_of "$pending")"
    if [ "$UPDATE_DRY" = 1 ]; then
      echo "A previous update run was interrupted. It would reopen: $names"
    else
      echo "A previous update run was interrupted. Reopening: $names"
      update_reopen_accounts || true
    fi
  fi

  case "$state" in
    none)
      echo "No Claude update is waiting."
      _update_dry_report
      update_safety_net
      return 0;;
    no-installer)
      echo "A Claude update was downloaded, but Claude's installer is not waiting for it."
      echo "It will come back by itself the next time Claude starts. Nothing needs doing now."
      _update_dry_report
      update_safety_net
      return 0;;
    waiting) ;;
    *) echo "Could not tell whether a Claude update is waiting. Nothing was changed."
       return 1;;
  esac

  UPDATE_WAITING=1
  old="$(installed_build 2>/dev/null || true)"; new="$(staged_build 2>/dev/null || true)"
  echo "A Claude update is waiting to install (build ${old:-?} -> ${new:-?})."

  start="$(claudes_now)"
  while :; do
    UPDATE_ACCOUNTS="$(update_open_accounts)"
    if busy="$(update_all_idle)"; then break; fi

    if [ "$UPDATE_DRY" = 1 ]; then
      _update_print_plan "$busy"
      return 0
    fi
    echo "$busy"
    if [ "$UPDATE_WATCH" = 1 ]; then
      echo "Not updating now. The background helper will try again later."
      return 0
    fi
    elapsed=$(( $(claudes_now) - start ))
    if [ "$elapsed" -ge "$CLAUDES_MAX_WAIT" ]; then
      echo "Gave up waiting after $((elapsed / 60)) minutes because an account is still busy. Nothing was quit."
      return 1
    fi
    echo "Checking again in $CLAUDES_POLL seconds."
    claudes_sleep "$CLAUDES_POLL"
    state="$(update_state 2>/dev/null || true)"
    if [ "$state" != waiting ]; then
      echo "The update is no longer waiting. Nothing was quit."
      return 0
    fi
  done

  if [ "$UPDATE_DRY" = 1 ]; then
    _update_print_plan ""
    return 0
  fi

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
  return "$reopen_rc"
}

# dry run only: show what the tool sees (open accounts, idle status) even with no update waiting
_update_dry_report() {
  local busy=""
  [ "$UPDATE_DRY" = 1 ] || return 0
  UPDATE_ACCOUNTS="$(update_open_accounts)"
  busy="$(update_all_idle || true)"
  _update_print_accounts "$busy"
  echo
  echo "Accounts that quit for an update and did not come back:"
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
    line="$(printf '%s\n' "$busy" | grep -F -- "$n is busy" | head -n 1 || true)"
    if [ -n "$line" ]; then echo "  $line"; else echo "  $n: idle"; fi
  done <<EOF
$UPDATE_ACCOUNTS
EOF
}

# BUSYTEXT -> prints the dry-run plan
_update_print_plan() {
  local busy="$1" d l n how
  _update_print_accounts "$busy"
  echo
  echo "What claudes update would do:"
  if [ -n "$busy" ]; then
    echo "  1. Wait until every open account is idle (right now it would wait, see above)."
  else
    echo "  1. Wait until every open account is idle (they all are right now)."
  fi
  echo "  2. Quit these together: $(update_names_of "$UPDATE_ACCOUNTS")"
  echo "  3. Let Claude's installer run, then close the plain Claude it opens afterwards."
  echo "  4. Reopen each account:"
  while IFS=$'\t' read -r d l; do
    [ -n "$d" ] || continue
    n="$(update_account_name "$d" "$l")"
    if [ -n "$l" ]; then how="from its own launcher"; else how="with the plain Claude icon (no launcher)"; fi
    echo "       $n, $how"
  done <<EOF
$UPDATE_ACCOUNTS
EOF
  echo
  echo "Dry run: nothing was quit, opened or changed."
}

# -> prints update/watcher/launcher lines for claudes doctor; always status 0
doctor_update_report() {
  local p state pid d
  if p="$(auto_updates_blocked 2>/dev/null)"; then
    echo "auto-updates: BLOCKED by $p (claudes update needs Claude's own updater on)"
  else
    echo "auto-updates: on"
  fi
  state="$(update_state 2>/dev/null || true)"
  case "$state" in
    waiting) echo "update: waiting";;
    no-installer) echo "update: downloaded but installer not waiting";;
    *) echo "update: none";;
  esac
  if [ -f "$CLAUDES_LAUNCHAGENTS_DIR/${CLAUDES_WATCH_LABEL:-}.plist" ]; then
    echo "watcher: installed"
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

# -> lines DATADIR<TAB>LAUNCHER for running accounts plus accounts down with an update marker.
#    While an update is waiting, a marker of any age counts: that account closed itself for this update.
update_open_accounts() {
  local nl seen pid d l age
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
    if [ "$UPDATE_WAITING" != 1 ]; then
      age="$(marker_age "$d" 2>/dev/null || true)"
      case "$age" in ''|*[!0-9]*) continue;; esac
      [ "$age" -le "$CLAUDES_MARKER_MAX_AGE" ] || continue
    fi
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

# -> status 0 when the Mac and every account in $UPDATE_ACCOUNTS are idle; prints "NAME is busy: reason" lines otherwise
update_all_idle() {
  local tmp i=0 d l n rc reason busy=0 idle_s
  if [ "$UPDATE_WATCH" = 1 ]; then   # the watcher also waits while someone is using the Mac
    if idle_s="$(user_idle_seconds 2>/dev/null)"; then
      if [ "$idle_s" -lt $((CLAUDES_IDLE_MINUTES * 60)) ]; then
        echo "The Mac is busy: someone used the Mac $((idle_s / 60)) min ago"
        return 1
      fi
    else
      echo "The Mac is busy: can't tell if someone is using the Mac"
      return 1
    fi
  fi
  [ -n "$UPDATE_ACCOUNTS" ] || return 0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/claudes-idle.XXXXXX")"
  while IFS=$'\t' read -r d l; do
    [ -n "$d" ] || continue
    i=$((i + 1))
    ( rc=0; reason="$(account_idle "$d")" || rc=$?
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
  local pf tmp i=0 d l n fail=0 kept="" rc
  pf="$(update_pending_file)"
  _update_pending_write "$UPDATE_ACCOUNTS"
  trap '_update_on_interrupt' INT TERM HUP
  UPDATE_OLD_BUILD="$(installed_build 2>/dev/null || true)"
  UPDATE_OLD_VERSION="$(main_version 2>/dev/null || true)"
  UPDATE_LOG_OFFSET="$(shipit_log_size 2>/dev/null || echo 0)"
  case "$UPDATE_LOG_OFFSET" in ''|*[!0-9]*) UPDATE_LOG_OFFSET=0;; esac

  [ -z "$UPDATE_ACCOUNTS" ] || echo "Quitting together: $(update_names_of "$UPDATE_ACCOUNTS")"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/claudes-stop.XXXXXX")"
  while IFS=$'\t' read -r d l; do
    [ -n "$d" ] || continue
    i=$((i + 1))
    ( if stop_datadir "$d" "$CLAUDES_STOP_TIMEOUT"; then echo 0; else echo 1; fi > "$tmp/$i.rc" ) </dev/null &
  done <<EOF
$UPDATE_ACCOUNTS
EOF
  wait
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
    _update_pending_write "$kept" "$(_update_pending_ts)"   # every account that did close stays listed until it is back
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
    if printf '%s\n' "$log" | grep -q 'Installation completed successfully'; then
      return 0
    fi
    # a changed build alone is not enough: the installer may still be copying files
    if [ -n "$build" ] && [ "$build" != "$UPDATE_OLD_BUILD" ] && ! shipit_waiting; then
      return 0
    fi
    hits="$(printf '%s\n' "$log" | grep -E 'Aborting update attempt|Installation cancelled|Installation error|Too many attempts' || true)"
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
  local def="$CLAUDES_SUPPORT_DIR/Claude" waited=0 seen_at="" d l in_pending=0 launcher=""
  # wait for the plain copy: up to 10 more seconds after the installer says it launched Claude
  while [ "$waited" -lt 30 ]; do
    if datadir_running "$def"; then break; fi
    if [ -z "$seen_at" ] && shipit_log_since "$UPDATE_LOG_OFFSET" 2>/dev/null | grep -q 'Successfully launched application'; then
      seen_at="$waited"
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
  local pf accounts tmp d l t keep="" tries_lines="" ts
  pf="$(update_pending_file)"
  [ -f "$pf" ] || return 0
  accounts="$(update_pending_accounts)"
  if [ -z "$accounts" ]; then rm -f "$pf"; return 0; fi
  ts="$(_update_pending_ts)"
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
    _update_pending_write "$keep" "$ts" "$tries_lines"
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
