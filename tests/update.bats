#!/usr/bin/env bats
# claudes update: flow tests against a small fake world. Nothing here touches real Claude copies.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  W="$BATS_TEST_TMPDIR/world"
  mkdir -p "$W/markers" "$W/busy" "$W/nostop" "$W/running.d"
  export CLAUDES_STATE_DIR="$W/state" CLAUDES_SUPPORT_DIR="$W/support" CLAUDES_APP_SRC="$W/Claude.app"
  export CLAUDES_LAUNCHAGENTS_DIR="$W/la" CLAUDES_APPS_DIR="$W/Apps"
  export CLAUDES_POLL=1 CLAUDES_MAX_WAIT=3 CLAUDES_INSTALL_TIMEOUT=6 CLAUDES_MARKER_GRACE=300 CLAUDES_MARKER_MAX_AGE=43200
  for f in common config instance procs update_detect update watch; do source "$REPO/lib/$f.sh"; done

  SUP="$CLAUDES_SUPPORT_DIR"
  A="$SUP/Claude"; C="$SUP/Claude-3p"; D="$SUP/Claude-Acct-D"; E="$SUP/Claude-E"
  : > "$W/events"; : > "$W/sleeps"; : > "$W/log"; echo 1000000 > "$W/clock"; echo 100000 > "$W/staged_age"
  echo 100 > "$W/build"
  echo waiting > "$W/state_word"
  echo success > "$W/mode"
  printf '%s\t%s\n' "$A" "$W/Apps/Claude A.app" "$C" "$W/Apps/Claude C.app" "$D" "$W/Apps/Claude D.app" > "$W/accounts"

  # ---- fake world (redefines the real functions after sourcing) ----
  _name() { basename "$1"; }
  claude_main_procs() { local f; for f in "$W"/running.d/*; do [ -e "$f" ] || continue; printf '100\t%s\n' "$SUP/$(basename "$f")"; done; return 0; }
  datadir_running() { [ -e "$W/running.d/$(basename "$1")" ]; }
  known_accounts() { cat "$W/accounts"; }
  launcher_for() { awk -F'\t' -v d="$1" '$1==d{print $2}' "$W/accounts"; }
  update_state() { cat "$W/state_word"; }
  auto_updates_blocked() { [ -e "$W/blocked" ] && { echo "$W/blocked"; return 0; }; return 1; }
  inside_claude_copy() { [ -e "$W/inside" ]; }
  staged_build() { echo 101; }
  main_version() { echo "1.$(cat "$W/build")"; }
  shipit_log_size() { wc -c < "$W/log" | tr -d ' '; }
  marker_says_update_quit() { [ "$(awk '{print $1}' "$W/markers/$(basename "$1")" 2>/dev/null)" = update ]; }
  marker_age() { awk '{print $2}' "$W/markers/$(basename "$1")"; }
  account_idle() {
    local f="$W/busy/$(basename "$1")" n
    [ -e "$f" ] || return 0
    n="$(cat "$f")"
    [ "$n" -gt 0 ] || return 0
    echo $((n - 1)) > "$f"
    echo "Claude Code used 14s of CPU in 20s"
    return 1
  }
  # ShipIt: once every copy has been stopped and none runs, it installs (or fails) by itself
  _tick() {
    [ -e "$W/stopped" ] && [ ! -e "$W/installed" ] || return 0
    [ -z "$(ls "$W/running.d")" ] || return 0
    touch "$W/installed"
    case "$(cat "$W/mode")" in
      success)
        echo 101 > "$W/build"
        printf 'Installation completed successfully\nSuccessfully launched application at file:///X/\n' >> "$W/log"
        [ -e "$W/noplain" ] || touch "$W/running.d/Claude";;
      cancel) echo "Installation cancelled: App Still Running Error" >> "$W/log";;
    esac
    return 0
  }
  installed_build() { _tick; cat "$W/build"; }
  shipit_log_since() { _tick; tail -c +$(($1 + 1)) "$W/log"; }
  stop_datadir() {
    echo "stop $1" >> "$W/events"
    [ ! -e "$W/nostop/$(basename "$1")" ] || return 1
    rm -f "$W/running.d/$(basename "$1")"; touch "$W/stopped"; return 0
  }
  claudes_open() {
    local arg d="" last="" a
    echo "open $*" >> "$W/events"
    if [ "$1" = "-n" ]; then
      for a in "$@"; do last="$a"; done
      case "$last" in --user-data-dir=*) d="${last#--user-data-dir=}";; *) d="$A";; esac
    elif [ "$1" = "$CLAUDES_APP_SRC" ]; then d="$A"
    else d="$(awk -F'\t' -v l="$1" '$2==l{print $1}' "$W/accounts")"; fi
    [ -z "$d" ] || [ -e "$W/noopen" ] || touch "$W/running.d/$(basename "$d")"
    return 0
  }
  claudes_sleep() { echo "$1" >> "$W/sleeps"; echo $(( $(cat "$W/clock") + ${CLOCK_STEP:-$1} )) > "$W/clock"; }
  claudes_now() { cat "$W/clock"; }
  claudes_notify() { echo "$*" >> "$W/notes"; }
  update_staged_age() { cat "$W/staged_age" 2>/dev/null || return 1; }
  shipit_waiting() { [ -e "$W/shipit_running" ]; }
  user_idle_seconds() { if [ -e "$W/useridle" ]; then cat "$W/useridle"; else return 1; fi; }
  run_up() { local n; for n in "$@"; do touch "$W/running.d/$n"; done; }
  set_marker() { echo "$2 $3" > "$W/markers/$1"; }
  set -euo pipefail   # the real script runs this way; catch unset variables and aborted pipelines
}

events() { cat "$W/events"; }

@test "1a. blocked: explains, exits 1, signals nothing" {
  touch "$W/blocked"; run_up Claude
  run cmd_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"switched off"* ]]
  [[ "$output" == *"$W/blocked"* ]]
  [ ! -s "$W/events" ]
}

@test "1b. blocked with --dry-run exits 0" {
  touch "$W/blocked"
  run cmd_update --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"switched off"* ]]
  [ ! -s "$W/events" ]
}

@test "2a. real run inside a Claude copy refuses with exit 1" {
  touch "$W/inside"; run_up Claude
  run cmd_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"Terminal"* ]]
  [ ! -s "$W/events" ]
  [ ! -e "$W/state" ]
}

@test "2b. dry-run inside a Claude copy works" {
  touch "$W/inside"; run_up Claude
  run cmd_update --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"What claudes update would do"* ]]
}

@test "unknown argument is a usage error" {
  run cmd_update --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: claudes update"* ]]
}

@test "3. no update: says so, runs the safety net, exits 0" {
  echo none > "$W/state_word"
  set_marker Claude update 400
  run cmd_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"No Claude update is waiting"* ]]
  [[ "$output" == *"Claude A"* ]]
  [ "$(events)" = "open $W/Apps/Claude A.app" ]
}

@test "4. dry-run with 3 open accounts (one busy) prints the plan and changes nothing" {
  run_up Claude Claude-3p Claude-Acct-D
  echo 5 > "$W/busy/Claude-3p"
  run cmd_update --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wait until every open account is idle"* ]]
  [[ "$output" == *"Claude C is busy: Claude Code used 14s of CPU in 20s"* ]]
  [[ "$output" == *"Claude A: idle"* ]]
  [[ "$output" == *"Quit these together: Claude A, Claude C, Claude D"* ]]
  [[ "$output" == *"Claude C, from its own launcher"* ]]
  [[ "$output" == *"Claude D, from its own launcher"* ]]
  [ ! -s "$W/events" ]
  [ ! -e "$W/state" ]
}

@test "5. watch-run with a busy account exits 0 and stops nothing" {
  run_up Claude Claude-3p
  echo 5 > "$W/busy/Claude-3p"
  run cmd_update --watch-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude C is busy"* ]]
  [ ! -s "$W/events" ]
  [ ! -s "$W/sleeps" ]
}

@test "6. happy path: pending written first, all stopped, install seen, plain relaunch closed, all reopened in order" {
  run_up Claude Claude-3p Claude-Acct-D
  # snapshot the pending file at the moment of the first stop
  stop_datadir() {
    if [ ! -e "$W/stopped" ]; then cp "$CLAUDES_STATE_DIR/reopen-pending" "$W/pending-at-first-stop"; fi
    echo "stop $1" >> "$W/events"; rm -f "$W/running.d/$(basename "$1")"; touch "$W/stopped"; return 0
  }
  run cmd_update
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -vc '^#' "$W/pending-at-first-stop")" = 3 ]
  grep -q '^#ts' "$W/pending-at-first-stop"
  [ ! -e "$CLAUDES_STATE_DIR/reopen-pending" ]
  [ ! -e "$CLAUDES_STATE_DIR/update.lock" ]
  # every stop comes before the first open; plain Claude (default folder) is stopped a second time
  ev="$(events)"
  [ "$(printf '%s\n' "$ev" | grep -c "^stop $A\$")" = 2 ]
  [ "$(printf '%s\n' "$ev" | grep -c '^stop ')" = 4 ]
  first_open="$(printf '%s\n' "$ev" | grep -n '^open ' | head -1 | cut -d: -f1)"
  last_stop="$(printf '%s\n' "$ev" | grep -n '^stop ' | tail -1 | cut -d: -f1)"
  [ "$last_stop" -lt "$first_open" ]
  [ "$(printf '%s\n' "$ev" | grep '^open ')" = "open $W/Apps/Claude A.app
open $W/Apps/Claude C.app
open $W/Apps/Claude D.app" ]
  [[ "$output" == *"Claude updated: 1.100 (build 100) -> 1.101 (build 101)"* ]]
}

@test "7. plain Claude open before with no launcher: relaunched copy stays, not reopened twice" {
  printf '%s\t%s\n' "$A" "" "$C" "$W/Apps/Claude C.app" > "$W/accounts"
  run_up Claude Claude-3p
  run cmd_update
  [ "$status" -eq 0 ]
  ev="$(events)"
  [ "$(printf '%s\n' "$ev" | grep -c "^stop $A\$")" = 1 ]
  [ "$(printf '%s\n' "$ev" | grep '^open ')" = "open $W/Apps/Claude C.app" ]
  [ -e "$W/running.d/Claude" ]
  [[ "$output" == *"Leaving the plain Claude"* ]]
}

@test "8a. install failure: message has the log line, accounts reopened, exit 1" {
  echo cancel > "$W/mode"
  run_up Claude Claude-3p
  run cmd_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"Installation cancelled: App Still Running Error"* ]]
  [ "$(events | grep '^open ')" = "open $W/Apps/Claude A.app
open $W/Apps/Claude C.app" ]
  [ ! -e "$CLAUDES_STATE_DIR/reopen-pending" ]
}

@test "8b. install timeout: clear message, accounts reopened, exit 1" {
  echo none > "$W/mode"
  echo "some earlier line" > "$W/log"
  run_up Claude Claude-3p
  run cmd_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not finish within"* ]]
  [ "$(events | grep -c '^open ')" = 2 ]
}

@test "9. a copy that will not stop: others reopened, exit 1, no install wait" {
  touch "$W/nostop/Claude-3p"
  run_up Claude Claude-3p
  run cmd_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"Claude C would not quit"* ]]
  [[ "$output" != *"Waiting for Claude's installer"* ]]
  [ "$(events | grep '^open ')" = "open $W/Apps/Claude A.app" ]
  [ ! -e "$CLAUDES_STATE_DIR/reopen-pending" ]
}

@test "10. safety net: only update-quit markers older than the grace period are reopened" {
  printf '%s\t%s\n' "$A" "$W/Apps/Claude A.app" "$C" "$W/Apps/Claude C.app" \
    "$D" "$W/Apps/Claude D.app" "$E" "$W/Apps/Claude E.app" > "$W/accounts"
  echo none > "$W/state_word"
  set_marker Claude update 400            # old enough, update quit -> reopen
  set_marker Claude-3p userquit 400       # user quit -> leave
  set_marker Claude-Acct-D update 100     # younger than grace -> leave
  # Claude-E has no marker -> leave
  run update_safety_net
  [ "$status" -eq 0 ]
  [ "$(events)" = "open $W/Apps/Claude A.app" ]
}

@test "10b. safety net in dry-run only reports" {
  echo none > "$W/state_word"
  set_marker Claude update 400
  UPDATE_DRY=1
  run update_safety_net
  [[ "$output" == *"Would reopen Claude A"* ]]
  [ ! -s "$W/events" ]
  [ ! -e "$W/state" ]
}

@test "11. interrupted run: leftover reopen-pending is reopened and removed" {
  echo none > "$W/state_word"
  mkdir -p "$CLAUDES_STATE_DIR"
  printf '%s\t%s\n' "$A" "$W/Apps/Claude A.app" "$D" "$W/Apps/Claude D.app" > "$CLAUDES_STATE_DIR/reopen-pending"
  run cmd_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"previous update run was interrupted"* ]]
  [ "$(events | grep '^open ')" = "open $W/Apps/Claude A.app
open $W/Apps/Claude D.app" ]
  [ ! -e "$CLAUDES_STATE_DIR/reopen-pending" ]
}

@test "12a. lock held by a live run: exits 0 saying another run is in progress" {
  mkdir -p "$CLAUDES_STATE_DIR/update.lock"
  echo $$ > "$CLAUDES_STATE_DIR/update.lock/pid"
  run_up Claude
  run cmd_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Another claudes update is already in progress"* ]]
  [ ! -s "$W/events" ]
  [ -d "$CLAUDES_STATE_DIR/update.lock" ]
}

@test "12b. stale lock (dead pid) is taken over" {
  echo none > "$W/state_word"
  ( : ) & dead=$!; wait "$dead"
  mkdir -p "$CLAUDES_STATE_DIR/update.lock"
  echo "$dead" > "$CLAUDES_STATE_DIR/update.lock/pid"
  run cmd_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"No Claude update is waiting"* ]]
  [ ! -e "$CLAUDES_STATE_DIR/update.lock" ]
}

@test "13a. plain run: busy, then idle on the second check -> proceeds" {
  run_up Claude Claude-3p
  echo 1 > "$W/busy/Claude-3p"
  run cmd_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude C is busy"* ]]
  [ "$(head -1 "$W/sleeps")" = 1 ]
  [ "$(events | grep -c '^stop ')" -ge 2 ]
}

@test "13b. plain run gives up after CLAUDES_MAX_WAIT without quitting anything" {
  run_up Claude Claude-3p
  echo 99 > "$W/busy/Claude-3p"
  run cmd_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"Gave up waiting"* ]]
  [ ! -s "$W/events" ]
  [ ! -e "$CLAUDES_STATE_DIR/reopen-pending" ]
}

@test "doctor_update_report prints the four kinds of line" {
  run_up Claude-E
  echo "no-installer" > "$W/state_word"
  run doctor_update_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-updates: on"* ]]
  [[ "$output" == *"update: downloaded but installer not waiting"* ]]
  [[ "$output" == *"watcher: not installed"* ]]
  [[ "$output" == *"note: $E is open without a launcher; after an update it reopens with the plain Claude icon"* ]]
  mkdir -p "$CLAUDES_LAUNCHAGENTS_DIR"; touch "$CLAUDES_LAUNCHAGENTS_DIR/$CLAUDES_WATCH_LABEL.plist"
  touch "$W/blocked"
  run doctor_update_report
  [[ "$output" == *"auto-updates: BLOCKED by $W/blocked (claudes update needs Claude's own updater on)"* ]]
  [[ "$output" == *"watcher: installed"* ]]
}

# ---- end to end: the real bin/claudes as a subprocess (set -euo pipefail), fake ps/launchctl on PATH ----
e2e_world() {
  T="$BATS_TEST_TMPDIR/e2e"
  mkdir -p "$T/bin" "$T/apps" "$T/support" "$T/shipit/update.X/Claude.app/Contents" "$T/app/Claude.app/Contents/MacOS" "$T/home" "$T/managed"
  for s in A:Claude C:Claude-3p D:Claude-Acct-D; do
    mkdir -p "$T/apps/Claude ${s%%:*}.app/Contents/MacOS" "$T/support/${s#*:}"
    printf '%s\t%s\t%s\n' "${s%%:*}" blue "${s#*:}" >> "$T/config"
  done
  cat > "$T/app/Claude.app/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>100</string>
</dict></plist>
P
  sed -e 's/1.0.0/2.0.0/' -e 's/>100</>200</' "$T/app/Claude.app/Contents/Info.plist" > "$T/shipit/update.X/Claude.app/Contents/Info.plist"
  cat > "$T/shipit/ShipItState.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>updateBundleURL</key><string>file://$T/shipit/update.X/Claude.app/</string></dict></plist>
P
  BIN="$T/app/Claude.app/Contents/MacOS/Claude"
  cat > "$T/ps.txt" <<P
 501 1 $BIN
 502 1 $BIN --user-data-dir=$T/support/Claude-3p
 503 1 $BIN --user-data-dir=$T/support/Claude-Acct-D
 504 502 $T/app/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)
P
  cat > "$T/bin/ps" <<'P'
#!/bin/bash
case "$*" in *-axo*) cat "$E2E_PS";; esac
exit 0
P
  printf '#!/bin/sh\necho "\tstate = running"\n' > "$T/bin/launchctl"
  chmod +x "$T/bin/ps" "$T/bin/launchctl"
  mkdir -p "$T/support/Claude-3p/claude-code-sessions"; touch "$T/support/Claude-3p/claude-code-sessions/work.json"
}

e2e_run() { # args to claudes update
  run env -i HOME="$T/home" USER=tester PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" E2E_PS="$T/ps.txt" \
    CLAUDES_APP_SRC="$T/app/Claude.app" CLAUDES_APPS_DIR="$T/apps" CLAUDES_SUPPORT_DIR="$T/support" \
    CLAUDES_SHIPIT_DIR="$T/shipit" CLAUDES_MANAGED_PREFS_DIR="$T/managed" CLAUDES_CONFIG="$T/config" \
    CLAUDES_STATE_DIR="$T/state" CLAUDES_CPU_SAMPLE=1 \
    /bin/bash "$BATS_TEST_DIRNAME/../bin/claudes" update "$@"
}

@test "e2e: bin/claudes update --dry-run with a waiting update lists the open accounts by launcher name" {
  e2e_world
  e2e_run --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" == *"A Claude update is waiting to install (build 100 -> 200)"* ]]
  [[ "$output" == *"Quit these together: Claude A, Claude C, Claude D"* ]]
  [[ "$output" == *"Claude C is busy: session files changed"* ]]
  [[ "$output" == *"Claude A: idle"* ]]
  [ ! -e "$T/state" ]
}

@test "e2e: dry-run with no update waiting still shows open accounts and the safety net" {
  e2e_world
  rm "$T/shipit/ShipItState.plist"
  e2e_run --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No Claude update is waiting."* ]]
  [[ "$output" == *"Open accounts:"* ]]
  [[ "$output" == *"Claude A: idle"* ]]
  [[ "$output" == *"Claude C is busy"* ]]
  [[ "$output" == *"Accounts that quit for an update and did not come back:"* ]]
  [ ! -e "$T/state" ]
}

# ---- review fixes ----

@test "fix 1a. (reviewer repro) main gone but a helper lingers: account is still reopened" {
  run_up Claude Claude-3p
  stop_datadir() {
    echo "stop $1" >> "$W/events"
    rm -f "$W/running.d/$(basename "$1")"; touch "$W/stopped"
    [ "$(basename "$1")" != Claude-3p ]   # main exited, but a tracked helper survived KILL -> 1
  }
  run cmd_update
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"leftover parts of Claude C"* ]]
  [ -e "$W/running.d/Claude-3p" ]
  [ -e "$W/running.d/Claude" ]
}

@test "fix 1b. a main still running: no install wait, closed accounts stay listed until confirmed back" {
  touch "$W/nostop/Claude-3p" "$W/noopen"
  run_up Claude Claude-3p Claude-Acct-D
  run cmd_update
  [ "$status" -eq 1 ]
  [[ "$output" != *"Waiting for Claude's installer"* ]]
  # A and D closed but could not be reopened (noopen): both stay in the list, C (still running) is not listed
  [ "$(grep -v '^#' "$CLAUDES_STATE_DIR/reopen-pending" | cut -f1 | sort | tr '\n' ' ')" = "$A $D " ]
}

@test "fix 2. (reviewer repro) an account that closed itself 13h ago while another stays busy is reopened at the end" {
  run_up Claude-3p
  set_marker Claude-Acct-D update 46800
  run cmd_update
  echo "$output"
  [ "$status" -eq 0 ]
  [ -e "$W/running.d/Claude-Acct-D" ]
  [[ "$output" == *"Quitting together: Claude C, Claude D"* ]]
}

@test "fix 2b. without a waiting update a 13h-old marker is left alone" {
  echo none > "$W/state_word"
  set_marker Claude-Acct-D update 46800
  run cmd_update
  [ ! -s "$W/events" ]
}

@test "fix 3a. safety net does nothing while ShipIt is waiting, even if the state reads none" {
  echo none > "$W/state_word"; touch "$W/shipit_running"
  set_marker Claude update 400
  run update_safety_net
  [ ! -s "$W/events" ]
}

@test "fix 3b. recovery of reopen-pending waits while the installer is mid-install" {
  echo none > "$W/state_word"; touch "$W/shipit_running"
  echo "Beginning installation" > "$W/log"
  _update_pending_write "$A"$'\t'"$W/Apps/Claude A.app" "" "" 0
  run cmd_update
  [ ! -s "$W/events" ]
  [ -e "$CLAUDES_STATE_DIR/reopen-pending" ]
}

@test "fix 4a. a changed build while the installer is still running is not success" {
  UPDATE_OLD_BUILD=100; UPDATE_LOG_OFFSET=0; CLOCK_STEP=2
  echo 101 > "$W/build"; touch "$W/shipit_running"
  run update_wait_install
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not finish"* ]]
}

@test "fix 4b. a changed build with the installer finished is success" {
  UPDATE_OLD_BUILD=100; UPDATE_LOG_OFFSET=0
  echo 101 > "$W/build"
  run update_wait_install
  [ "$status" -eq 0 ]
}

@test "fix 4c. the completed line alone is success" {
  UPDATE_OLD_BUILD=100; UPDATE_LOG_OFFSET=0
  touch "$W/shipit_running"
  echo "Installation completed successfully" > "$W/log"
  run update_wait_install
  [ "$status" -eq 0 ]
}

@test "fix 5. the plain relaunch is still closed when it appears 6s after the launched line" {
  touch "$W/noplain"
  run_up Claude Claude-3p
  claudes_sleep() {
    echo "$1" >> "$W/sleeps"; echo $(( $(cat "$W/clock") + $1 )) > "$W/clock"
    if [ -e "$W/installed" ]; then
      echo x >> "$W/post"
      if [ "$(wc -l < "$W/post" | tr -d ' ')" -ge 3 ]; then touch "$W/running.d/Claude"; fi
    fi
  }
  run cmd_update
  [ "$status" -eq 0 ]
  [ "$(events | grep -c "^stop $A\$")" = 2 ]
  [[ "$output" == *"Closing the plain Claude"* ]]
}

@test "fix 6a. an account that does not come back stays in reopen-pending with a try counted" {
  touch "$W/noopen"
  mkdir -p "$CLAUDES_STATE_DIR"
  _update_pending_write "$A"$'\t'"$W/Apps/Claude A.app"
  run update_reopen_accounts
  [ "$status" -eq 1 ]
  grep -q "^$A	" "$CLAUDES_STATE_DIR/reopen-pending"
  [ "$(_update_pending_tries "$A")" = 1 ]
}

@test "fix 6b. after 3 tries the account is dropped with a message" {
  touch "$W/noopen"
  _update_pending_write "$A"$'\t'"$W/Apps/Claude A.app" "" "#tries"$'\t'"$A"$'\t'2
  run update_reopen_accounts
  [ "$status" -eq 1 ]
  [[ "$output" == *"Giving up on Claude A after 3 tries"* ]]
  [ ! -e "$CLAUDES_STATE_DIR/reopen-pending" ]
}

@test "fix 6c. under --watch-run a failed reopen posts a notification" {
  touch "$W/noopen"
  UPDATE_WATCH=1
  _update_pending_write "$A"$'\t'"$W/Apps/Claude A.app"
  run update_reopen_accounts
  [ "$status" -eq 1 ]
  [[ "$(cat "$W/notes")" == *"Could not reopen: Claude A"* ]]
}

@test "fix 7a. interrupted after quitting, installer not running: accounts are reopened and the lock released" {
  echo none > "$W/mode"
  run_up Claude Claude-3p
  claudes_sleep() { echo "$1" >> "$W/sleeps"; if [ -e "$W/stopped" ]; then bash -c 'echo $PPID' > "$W/me"; kill -TERM "$(cat "$W/me")"; fi; }
  run cmd_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"Interrupted"* ]]
  [ "$(events | grep '^open ')" = "open $W/Apps/Claude A.app
open $W/Apps/Claude C.app" ]
  [ ! -e "$CLAUDES_STATE_DIR/reopen-pending" ]
  [ ! -e "$CLAUDES_STATE_DIR/update.lock" ]
}

@test "fix 7b. interrupted while the installer is mid-install: nothing is reopened, the list stays" {
  echo none > "$W/mode"; touch "$W/shipit_running"
  shipit_log_since() { echo "Beginning installation"; }
  run_up Claude Claude-3p
  claudes_sleep() { echo "$1" >> "$W/sleeps"; if [ -e "$W/stopped" ]; then bash -c 'echo $PPID' > "$W/me"; kill -TERM "$(cat "$W/me")"; fi; }
  run cmd_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"will reopen your accounts"* ]]
  [ "$(events | grep -c '^open ')" = 0 ]
  [ -e "$CLAUDES_STATE_DIR/reopen-pending" ]
  [ ! -e "$CLAUDES_STATE_DIR/update.lock" ]
}

@test "fix 7c. a reopen-pending older than 24h is ignored and deleted" {
  echo none > "$W/state_word"
  _update_pending_write "$A"$'\t'"$W/Apps/Claude A.app" 900000
  run cmd_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignored and deleted"* ]]
  [ ! -s "$W/events" ]
  [ ! -e "$CLAUDES_STATE_DIR/reopen-pending" ]
}

@test "fix 8. the default folder with no launcher is reopened with open -n -a" {
  printf '%s\t%s\n' "$A" "" > "$W/accounts"
  _update_pending_write "$A"$'\t'
  run update_reopen_accounts
  [ "$(events)" = "open -n -a $CLAUDES_APP_SRC" ]
}

@test "fix 9a. watch-run waits while someone used the Mac recently" {
  run_up Claude Claude-3p
  echo 120 > "$W/useridle"
  run cmd_update --watch-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"someone used the Mac 2 min ago"* ]]
  [ ! -s "$W/events" ]
}

@test "fix 9b. watch-run waits when the idle time cannot be read" {
  run_up Claude
  run cmd_update --watch-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"can't tell if someone is using the Mac"* ]]
  [ ! -s "$W/events" ]
}

@test "fix 9c. watch-run proceeds when the Mac has been idle long enough; a manual run ignores user idle time" {
  run_up Claude
  echo 700 > "$W/useridle"
  run cmd_update --watch-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude updated"* ]]
  rm -rf "$W/stopped" "$W/installed" "$W/running.d/"*; run_up Claude
  echo 5 > "$W/useridle"; echo 100 > "$W/build"
  run cmd_update
  [[ "$output" == *"Claude updated"* ]]
}

@test "fix 11. the manual-run wait is measured with the clock, not by adding up poll intervals" {
  run_up Claude Claude-3p
  echo 99 > "$W/busy/Claude-3p"
  CLAUDES_MAX_WAIT=30; CLAUDES_POLL=1; CLOCK_STEP=20
  run cmd_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"Gave up waiting"* ]]
  [ "$(wc -l < "$W/sleeps" | tr -d ' ')" = 2 ]
}

@test "fix 12. a watcher log over 1 MB is cut to its last 2000 lines at the start of a watch-run" {
  echo none > "$W/state_word"
  export CLAUDES_LOG_DIR="$W/logs"; mkdir -p "$CLAUDES_LOG_DIR"
  awk 'BEGIN { for (i = 1; i <= 30000; i++) printf "line %d padded to make the file big enough for the limit\n", i }' > "$CLAUDES_LOG_DIR/update-watcher.log"
  run cmd_update --watch-run
  [ "$(wc -l < "$CLAUDES_LOG_DIR/update-watcher.log" | tr -d ' ')" = 2000 ]
  [ "$(tail -n 1 "$CLAUDES_LOG_DIR/update-watcher.log" | cut -d' ' -f1-2)" = "line 30000" ]
}

# ---- second review round ----

# run cmd_update in a clean bash (no bats traps) with the fake world's functions; extra shell given as $1, e.g. redirections
clean_run() {   # SHELLCODE -> status of a clean "bash -euo pipefail" that has all current functions
  export W SUP A C D E CLOCK_STEP
  bash -c "$(declare -f)
$(declare -p $(compgen -v | grep -E '^(CLAUDES_|UPDATE_|_KA_|_ka_|_PLIST|_SHIPIT)') 2>/dev/null)
trap - ERR DEBUG; set -euo pipefail
$1"
}

hup_sleep() {   # fake sleep: the first time after the accounts are stopped, send HUP to this process
  echo "$1" >> "$W/sleeps"; echo $(( $(cat "$W/clock") + $1 )) > "$W/clock"
  if [ -e "$W/stopped" ] && [ ! -e "$W/hup-sent" ]; then
    touch "$W/hup-sent"; bash -c 'echo $PPID' > "$W/me"; kill -HUP "$(cat "$W/me")"
  fi
}

@test "A1. closing the Terminal (HUP) while the output pipe is broken: the run completes and reopens" {
  export CLAUDES_LOG_DIR="$W/logs"
  echo none > "$W/mode"
  run_up Claude Claude-3p
  claudes_sleep() { hup_sleep "$@"; }
  clean_run 'cmd_update 2>&1' | head -n 2 > /dev/null || true
  [ "$(events | grep -c '^open ')" = 2 ]
  [ ! -e "$CLAUDES_STATE_DIR/reopen-pending" ]
}

@test "A2. after HUP the rest of the output goes to update.log" {
  export CLAUDES_LOG_DIR="$W/logs"
  echo none > "$W/mode"
  run_up Claude
  claudes_sleep() { hup_sleep "$@"; }
  clean_run 'cmd_update' > /dev/null 2>&1 || true
  grep -q "Terminal was closed" "$CLAUDES_LOG_DIR/update.log"
  grep -q "Reopening Claude A" "$CLAUDES_LOG_DIR/update.log"
}

@test "D. interrupt with ShipIt only waiting (no Beginning installation) reopens" {
  echo none > "$W/mode"; touch "$W/shipit_running"
  run_up Claude Claude-3p
  claudes_sleep() { echo "$1" >> "$W/sleeps"; if [ -e "$W/stopped" ]; then bash -c 'echo $PPID' > "$W/me"; kill -TERM "$(cat "$W/me")"; fi; }
  run cmd_update
  [ "$status" -eq 1 ]
  [ "$(events | grep -c '^open ')" = 2 ]
  [ ! -e "$CLAUDES_STATE_DIR/reopen-pending" ]
}

@test "D2. interrupt after the installer finished reopens" {
  echo none > "$W/mode"
  run_up Claude
  shipit_log_since() { printf 'Beginning installation\nInstallation completed successfully\n'; }
  UPDATE_LOG_OFFSET=0
  run _update_install_started 0
  [ "$status" -eq 1 ]
}

@test "E. while an update waits, a marker older than the update itself is not reopened" {
  run_up Claude-3p
  set_marker Claude-Acct-D update 46800
  echo 20000 > "$W/staged_age"            # the update was staged 20000s ago, the marker is older
  run cmd_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Quitting together: Claude C"* ]]
  [[ "$output" != *"Claude D"* ]]
}

@test "F1. leftover reopen-pending with the installer finished is recovered although ShipIt reads running" {
  echo none > "$W/state_word"; touch "$W/shipit_running"
  printf 'Beginning installation\nInstallation completed successfully\n' > "$W/log"
  _update_pending_write "$A"$'\t'"$W/Apps/Claude A.app" "" "" 0
  run cmd_update
  [ "$status" -eq 0 ]
  [ "$(events | grep '^open ')" = "open $W/Apps/Claude A.app" ]
  [ ! -e "$CLAUDES_STATE_DIR/reopen-pending" ]
}

@test "F2. leftover reopen-pending with no Beginning installation at all is recovered" {
  echo none > "$W/state_word"; touch "$W/shipit_running"
  _update_pending_write "$A"$'\t'"$W/Apps/Claude A.app" "" "" 0
  run cmd_update
  [ "$(events | grep '^open ')" = "open $W/Apps/Claude A.app" ]
}

@test "F3. only the log after the recorded offset counts" {
  echo none > "$W/state_word"; touch "$W/shipit_running"
  echo "Beginning installation" > "$W/log"      # an old, unfinished line from before we quit
  _update_pending_write "$A"$'\t'"$W/Apps/Claude A.app" "" "" "$(wc -c < "$W/log" | tr -d ' ')"
  run cmd_update
  [ "$(events | grep -c '^open ')" = 1 ]
}

# ---- third review round ----

@test "R3-1a. (reviewer repro) a marker older than the plist but within the normal age limit is kept" {
  echo 600 > "$W/staged_age"              # another copy's later download rewrote the plist 10 minutes ago
  run_up Claude-3p
  set_marker Claude-Acct-D update 10800   # D quit itself 3 hours ago
  run cmd_update
  [ "$status" -eq 0 ]
  [ -e "$W/running.d/Claude-Acct-D" ]
}

@test "R3-1b. after a successful manual run the safety net runs" {
  run_up Claude
  set_marker Claude-E update 400
  printf '%s\t%s\n' "$A" "$W/Apps/Claude A.app" "$E" "$W/Apps/Claude E.app" > "$W/accounts"
  marker_says_update_quit() { [ "$(basename "$1")" != Claude-E ] || [ -e "$W/installed" ]; }   # E's marker only appears after the install
  update_state() { if [ -e "$W/installed" ]; then echo none; else echo waiting; fi; }
  run cmd_update
  [ "$status" -eq 0 ]
  [ "$(events | grep '^open ')" = "open $W/Apps/Claude A.app
open $W/Apps/Claude E.app" ]
}

@test "R3-1c. the safety net does not run at the end of a watch-run" {
  run_up Claude
  set_marker Claude-E update 400
  printf '%s\t%s\n' "$A" "$W/Apps/Claude A.app" "$E" "$W/Apps/Claude E.app" > "$W/accounts"
  marker_says_update_quit() { [ "$(basename "$1")" != Claude-E ] || [ -e "$W/installed" ]; }   # E's marker only appears after the install
  update_state() { if [ -e "$W/installed" ]; then echo none; else echo waiting; fi; }
  echo 700 > "$W/useridle"
  run cmd_update --watch-run
  [ "$(events | grep -c "Claude E.app")" = 0 ]
}

@test "R3-2. HUP during the quit phase: the slow account is still waited for and everything is reopened" {
  export CLAUDES_LOG_DIR="$W/logs"
  run_up Claude Claude-3p
  stop_datadir() {
    echo "stop $1" >> "$W/events"
    if [ "$(basename "$1")" = Claude-3p ]; then
      bash -c 'echo $PPID' > "$W/me"
      kill -HUP "$(cat "$W/me")" "$(cat "$W/mainpid")"    # the Terminal closes: this stopper and the main script both get HUP
      sleep 1                                             # ... while this copy is still shutting down
    fi
    rm -f "$W/running.d/$(basename "$1")"; touch "$W/stopped"; return 0
  }
  clean_run 'echo $$ > "$W/mainpid"; cmd_update' > /dev/null 2>&1 || true
  [ "$(events | grep '^open ')" = "open $W/Apps/Claude A.app
open $W/Apps/Claude C.app" ]
  ! grep -q "would not quit" "$CLAUDES_LOG_DIR/update.log"
  [ ! -e "$CLAUDES_STATE_DIR/reopen-pending" ]
  # reopening happened after the install, i.e. after both stops
  [ "$(events | grep -n '^open ' | head -1 | cut -d: -f1)" -gt "$(events | grep -n '^stop ' | tail -1 | cut -d: -f1)" ]
}

@test "R3-3a. a log of more than 200 KB still gives 'completed successfully'" {
  UPDATE_OLD_BUILD=100; UPDATE_LOG_OFFSET=0
  { awk 'BEGIN { for (i = 1; i <= 6000; i++) printf "ShipIt line %d with some padding to fill the log up nicely\n", i }'
    echo "Installation completed successfully"; } > "$W/log"
  [ "$(wc -c < "$W/log" | tr -d ' ')" -gt 200000 ]
  run update_wait_install
  [ "$status" -eq 0 ]
}

@test "R3-3b. a long log with a failure line is still reported" {
  UPDATE_OLD_BUILD=100; UPDATE_LOG_OFFSET=0
  { awk 'BEGIN { for (i = 1; i <= 6000; i++) printf "ShipIt line %d with some padding to fill the log up nicely\n", i }'
    echo "Installation cancelled: App Still Running Error"; } > "$W/log"
  run update_wait_install
  [ "$status" -eq 1 ]
  [[ "$output" == *"Installation cancelled"* ]]
}

@test "R3-3c. no printf-into-grep -q pipelines remain in lib/" {
  ! grep -nE "printf .*\| *grep -[a-zA-Z]*q|\| *grep -[a-zA-Z]*q" "$REPO"/lib/*.sh
}

@test "R3-4. install started but the ShipIt job is gone (crashed): recovery reopens" {
  echo none > "$W/state_word"                     # shipit_waiting is false: no shipit_running file
  echo "Beginning installation" > "$W/log"
  _update_pending_write "$A"$'\t'"$W/Apps/Claude A.app" "" "" 0
  run cmd_update
  [ "$status" -eq 0 ]
  [ "$(events | grep '^open ')" = "open $W/Apps/Claude A.app" ]
  [ ! -e "$CLAUDES_STATE_DIR/reopen-pending" ]
}
