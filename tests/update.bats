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
  : > "$W/events"; : > "$W/sleeps"; : > "$W/log"
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
        touch "$W/running.d/Claude";;
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
      for a in "$@"; do last="$a"; done; d="${last#--user-data-dir=}"
    elif [ "$1" = "$CLAUDES_APP_SRC" ]; then d="$A"
    else d="$(awk -F'\t' -v l="$1" '$2==l{print $1}' "$W/accounts")"; fi
    [ -z "$d" ] || touch "$W/running.d/$(basename "$d")"
    return 0
  }
  claudes_sleep() { echo "$1" >> "$W/sleeps"; }
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
  [ "$(wc -l < "$W/pending-at-first-stop" | tr -d ' ')" = 3 ]
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
