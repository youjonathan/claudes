#!/usr/bin/env bats
# Process matching and stopping. Everything runs against a fake `ps` and `kill` on PATH; no real process is touched.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export CLAUDES_APP_SRC="$BATS_TEST_TMPDIR/Applications/Claude.app"
  export CLAUDES_SUPPORT_DIR="$BATS_TEST_TMPDIR/Library/Application Support"
  APP="$CLAUDES_APP_SRC"
  SUP="$CLAUDES_SUPPORT_DIR"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  export PSFIX="$BATS_TEST_TMPDIR/ps.txt"      # fake process table: PID PPID COMMAND
  export KILLLOG="$BATS_TEST_TMPDIR/kill.log"  # every kill call: SIGNAL PID
  export STUCK="$BATS_TEST_TMPDIR/stuck.txt"   # pids that ignore TERM (and KILL too if listed as "unkillable PID")
  export CASCADE="$BATS_TEST_TMPDIR/cascade.txt" # lines "PID:PID,PID" = also exit when PID exits
  : > "$PSFIX"; : > "$KILLLOG"; : > "$STUCK"; : > "$CASCADE"

  cat > "$BATS_TEST_TMPDIR/bin/ps" <<'STUB'
#!/bin/bash
cat "$PSFIX"
STUB
  cat > "$BATS_TEST_TMPDIR/bin/kill" <<'STUB'
#!/bin/bash
sig="${1#-}"; pid="$2"
echo "$sig $pid" >> "$KILLLOG"
if grep -qx "unkillable $pid" "$STUCK"; then exit 0; fi
if [ "$sig" = TERM ] && grep -qx "$pid" "$STUCK"; then exit 0; fi
gone=" $pid "
extra="$(grep "^$pid:" "$CASCADE" | cut -d: -f2 | tr ',' ' ')"
for e in $extra; do gone="$gone$e "; done
tmp="$PSFIX.new"; : > "$tmp"
while IFS= read -r line; do
  p="$(echo "$line" | awk '{print $1}')"
  case "$gone" in *" $p "*) ;; *) echo "$line" >> "$tmp";; esac
done < "$PSFIX"
mv "$tmp" "$PSFIX"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/ps" "$BATS_TEST_TMPDIR/bin/kill"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  source "$REPO/lib/common.sh"; source "$REPO/lib/procs.sh"
  claudes_sleep() { :; }
}

# add_proc PID PPID COMMAND...
add_proc() { local pid="$1" ppid="$2"; shift 2; printf '%6s %6s %s\n' "$pid" "$ppid" "$*" >> "$PSFIX"; }

big_fixture() {
  add_proc 1 0 /sbin/launchd
  add_proc 100 1 "$APP/Contents/MacOS/Claude"
  add_proc 101 100 "$APP/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer) --type=renderer"
  add_proc 102 100 "$APP/Contents/Frameworks/Claude Helper (GPU).app/Contents/MacOS/Claude Helper (GPU) --type=gpu-process"
  add_proc 103 100 "$APP/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=utility"
  add_proc 200 1 "$APP/Contents/MacOS/Claude --user-data-dir=$SUP/Claude-3p"
  add_proc 201 200 "$APP/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer) --type=renderer --user-data-dir=$SUP/Claude-3p"
  add_proc 300 1 "$APP/Contents/MacOS/Claude --user-data-dir=$SUP/Claude-Acct-D --foo"
  add_proc 301 300 "$APP/Contents/Frameworks/Claude Helper (GPU).app/Contents/MacOS/Claude Helper (GPU) --type=gpu-process --user-data-dir=$SUP/Claude-Acct-D"
  add_proc 400 1 /usr/bin/vim "$APP/Contents/MacOS/Claude"
}

@test "claude_main_procs prints exactly the three main processes with their folders" {
  big_fixture
  run claude_main_procs
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "$(printf '100\t%s' "$SUP/Claude")" ]
  [ "${lines[1]}" = "$(printf '200\t%s' "$SUP/Claude-3p")" ]
  [ "${lines[2]}" = "$(printf '300\t%s' "$SUP/Claude-Acct-D")" ]
}

@test "claude_main_procs keeps spaces in the data folder and stops at the next flag" {
  add_proc 500 1 "$APP/Contents/MacOS/Claude --user-data-dir=/Users/x/Library/Application Support/Claude-3p --some-flag=1"
  add_proc 501 1 "$APP/Contents/MacOS/Claude --user-data-dir=/Users/x/Library/Application Support/Other"
  run claude_main_procs
  [ "${lines[0]}" = "$(printf '500\t/Users/x/Library/Application Support/Claude-3p')" ]
  [ "${lines[1]}" = "$(printf '501\t/Users/x/Library/Application Support/Other')" ]
}

@test "claude_main_procs ignores another Claude.app" {
  add_proc 600 1 "/Users/x/Other/Claude.app/Contents/MacOS/Claude"
  run claude_main_procs
  [ -z "$output" ]
}

@test "datadir_main_pid is exact: Work vs Work2" {
  add_proc 10 1 "$APP/Contents/MacOS/Claude --user-data-dir=$SUP/Work2"
  run datadir_main_pid "$SUP/Work"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run datadir_running "$SUP/Work"
  [ "$status" -eq 1 ]
  add_proc 11 1 "$APP/Contents/MacOS/Claude --user-data-dir=$SUP/Work"
  run datadir_main_pid "$SUP/Work"
  [ "$status" -eq 0 ]
  [ "$output" = 11 ]
  run datadir_main_pid "$SUP/Work2"
  [ "$output" = 10 ]
  run datadir_running "$SUP/Work"
  [ "$status" -eq 0 ]
}

@test "datadir_running is exact: Claude vs Claude-3p" {
  add_proc 20 1 "$APP/Contents/MacOS/Claude --user-data-dir=$SUP/Claude-3p"
  run datadir_running "$SUP/Claude"
  [ "$status" -eq 1 ]
  run datadir_running "$SUP/Claude-3p"
  [ "$status" -eq 0 ]
  add_proc 21 1 "$APP/Contents/MacOS/Claude"
  run datadir_main_pid "$SUP/Claude"
  [ "$output" = 21 ]
}

@test "datadir_running treats a dot in the profile name as literal" {
  add_proc 30 1 "$APP/Contents/MacOS/Claude --user-data-dir=$SUP/aXb"
  run datadir_running "$SUP/a.b"
  [ "$status" -eq 1 ]
  add_proc 31 1 "$APP/Contents/MacOS/Claude --user-data-dir=$SUP/a.b"
  run datadir_main_pid "$SUP/a.b"
  [ "$output" = 31 ]
}

@test "proc_tree returns the pid and all descendants across levels" {
  add_proc 1 0 /sbin/launchd
  add_proc 10 1 a
  add_proc 11 10 b
  add_proc 12 10 c
  add_proc 13 11 d
  add_proc 14 13 e
  add_proc 99 1 unrelated
  add_proc 98 99 unrelated-child
  run proc_tree 10
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | sort -n | tr '\n' ' ')" = "10 11 12 13 14 " ]
}

@test "proc_tree of a leaf is just itself" {
  add_proc 10 1 a
  run proc_tree 10
  [ "$output" = 10 ]
}

@test "crashpad_pids exact-matches --database=DATADIR/Crashpad" {
  H="$APP/Contents/Frameworks/Claude.app/chrome_crashpad_handler"
  add_proc 40 1 "$H --monitor-self --database=$SUP/Claude/Crashpad --url=https://x"
  add_proc 41 1 "$H --database=$SUP/Claude-3p/Crashpad"
  add_proc 42 1 "$H --database=$SUP/Claude/Crashpad2"
  add_proc 43 1 "$H --database=$SUP/Claude/Crashpad"
  add_proc 44 1 "/usr/bin/other --database=$SUP/Claude/Crashpad"
  run crashpad_pids "$SUP/Claude"
  [ "$(echo "$output" | tr '\n' ' ')" = "40 43 " ]
  run crashpad_pids "$SUP/Claude-3p"
  [ "$output" = 41 ]
  run crashpad_pids "$SUP/Clau"
  [ -z "$output" ]
}

stopfix() {
  add_proc 1 0 /sbin/launchd
  add_proc 100 1 "$APP/Contents/MacOS/Claude --user-data-dir=$SUP/Work"
  add_proc 101 100 "$APP/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer) --type=renderer"
  add_proc 102 101 "$APP/Contents/Frameworks/Claude Helper (GPU).app/Contents/MacOS/Claude Helper (GPU)"
  add_proc 103 1 "$APP/Contents/Frameworks/Claude.app/chrome_crashpad_handler --database=$SUP/Work/Crashpad"
  add_proc 104 100 "$APP/Contents/Frameworks/Squirrel.framework/Resources/ShipIt com.anthropic.claudefordesktop.ShipIt state.plist"
  add_proc 105 100 "$APP/Contents/Helpers/ShipIt something"
  add_proc 106 100 "/usr/local/bin/outside-claude-code-child"
  add_proc 200 1 "$APP/Contents/MacOS/Claude --user-data-dir=$SUP/Other"
  add_proc 201 200 "$APP/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
  echo "100:101,102,103" > "$CASCADE"
}

@test "stop_datadir sends TERM to main, waits for tree and crashpad, returns 0" {
  stopfix
  run stop_datadir "$SUP/Work" 5
  [ "$status" -eq 0 ]
  [ "$(cat "$KILLLOG")" = "TERM 100" ]
  ! datadir_running "$SUP/Work"
  [ -z "$(crashpad_pids "$SUP/Work")" ]
  ! grep -q '^ *101 ' "$PSFIX"
  # the other account is untouched
  datadir_running "$SUP/Other"
}

@test "stop_datadir never signals ShipIt or Squirrel lines, nor processes outside the app" {
  stopfix
  echo "100:101,102,103" > "$CASCADE"
  echo 100 >> "$STUCK"        # main ignores TERM -> forces the KILL path
  echo 101 >> "$STUCK"
  run stop_datadir "$SUP/Work" 2
  [ "$status" -eq 0 ]
  ! grep -Eq ' (104|105|106|200|201)$' "$KILLLOG"
  grep -q '^TERM 100$' "$KILLLOG"
}

@test "stop_datadir escalates to KILL after the timeout on a stuck process" {
  stopfix
  echo 100 >> "$STUCK"
  run stop_datadir "$SUP/Work" 3
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$KILLLOG")" = "TERM 100" ]
  grep -q '^KILL 100$' "$KILLLOG"
  ! grep -Eq ' (104|105|106)$' "$KILLLOG"
  ! datadir_running "$SUP/Work"
}

@test "stop_datadir waits the full timeout before escalating" {
  stopfix
  echo 100 >> "$STUCK"
  SLEEPS_BEFORE_KILL=0
  claudes_sleep() { grep -q '^KILL' "$KILLLOG" || SLEEPS_BEFORE_KILL=$((SLEEPS_BEFORE_KILL + 1)); }
  stop_datadir "$SUP/Work" 3
  [ "$SLEEPS_BEFORE_KILL" -eq 3 ]
}

@test "stop_datadir returns 1 when a process will not die even with KILL" {
  stopfix
  echo 100 >> "$STUCK"
  echo "unkillable 100" >> "$STUCK"
  run stop_datadir "$SUP/Work" 2
  [ "$status" -eq 1 ]
  grep -q '^KILL 100$' "$KILLLOG"
  ! grep -Eq ' (104|105|106)$' "$KILLLOG"
}

@test "stop_datadir waits for a lingering crashpad handler and kills it after the timeout" {
  stopfix
  echo "100:101,102" > "$CASCADE"      # crashpad 103 outlives the main process
  echo 103 >> "$STUCK"
  run stop_datadir "$SUP/Work" 2
  [ "$status" -eq 0 ]
  grep -q '^KILL 103$' "$KILLLOG"
  ! grep -q '^TERM 103$' "$KILLLOG"
}

@test "stop_datadir returns 0 immediately and signals nothing when not running" {
  stopfix
  run stop_datadir "$SUP/NotRunning" 5
  [ "$status" -eq 0 ]
  [ ! -s "$KILLLOG" ]
}

@test "stop_datadir works under set -euo pipefail with a default timeout" {
  stopfix
  run bash -c 'set -euo pipefail; source "$1/lib/common.sh"; source "$1/lib/procs.sh"; claudes_sleep() { :; }
    stop_datadir "$2/Work"; echo done' _ "$REPO" "$SUP"
  [ "$status" -eq 0 ]
  [ "$output" = done ]
}

@test "no pgrep or pkill remains in procs.sh or instance.sh" {
  ! grep -nE 'pgrep|pkill' "$REPO/lib/procs.sh" "$REPO/lib/instance.sh"
}
