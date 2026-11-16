#!/usr/bin/env bats
# Tests for lib/update_detect.sh — every external path is a temp dir, every command a stub.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home" "$T/apps" "$T/support" "$T/shipit" "$T/managed" "$T/app/Claude.app/Contents"
  export HOME="$T/home"
  export CLAUDES_APP_SRC="$T/app/Claude.app"
  export CLAUDES_APPS_DIR="$T/apps"
  export CLAUDES_SUPPORT_DIR="$T/support"
  export CLAUDES_SHIPIT_DIR="$T/shipit"
  export CLAUDES_MANAGED_PREFS_DIR="$T/managed"
  export CLAUDES_CONFIG="$T/config"
  export CLAUDES_STATE_DIR="$T/state"
  export USER=tester
  export T
  export PATH="$T/bin:$PATH"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/config.sh"
  source "$REPO/lib/procs.sh"
  source "$REPO/lib/update_detect.sh"
  # fakes for the procs.sh functions
  claude_main_procs() { cat "$T/mainprocs" 2>/dev/null || true; }
  proc_tree() { # pid + descendants from the fake table "pid ppid time command"
    local pid="$1" out="$1" frontier="$1" next p q pp
    while [ -n "$frontier" ]; do
      next=""
      for p in $frontier; do
        while read -r q pp _; do
          if [ "$pp" = "$p" ]; then out="$out $q"; next="$next $q"; fi
        done < "$T/procs"
      done
      frontier="$next"
    done
    echo $out | tr ' ' '\n'
  }
  # the "sample window" passes: swap in the second process table if a test made one
  claudes_sleep() { if [ -f "$T/procs2" ]; then cp "$T/procs2" "$T/procs"; fi; }
  : > "$T/procs"; : > "$T/mainprocs"
  stub_lsappinfo
  echo 999 > "$T/front"   # some other app in front by default
  stub_windows_bin
  set -euo pipefail   # the real script runs this way
}

# ---- helpers ----
mkbundle() { # dir version
  mkdir -p "$1/Contents"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $2" "$1/Contents/Info.plist" >/dev/null
}
mkstate() { # url
  /usr/libexec/PlistBuddy -c "Add :updateBundleURL string $1" "$CLAUDES_SHIPIT_DIR/ShipItState.plist" >/dev/null
}
stub_launchctl() { # state text
  cat > "$T/bin/launchctl" <<EOS
#!/bin/bash
[ "\$1" = print ] || exit 9
printf 'gui/501/x = {\n\tactive count = 0\n\tstate = $1\n}\n'
EOS
  chmod +x "$T/bin/launchctl"
}
stub_ps() {
  cat > "$T/bin/ps" <<'EOS'
#!/bin/bash
# fake ps: ps -o FIELD= -p PID, reads $T/procs lines "pid ppid time command..."
field="${2%=}"; pid="$4"
while read -r p pp tm cmd; do
  [ "$p" = "$pid" ] || continue
  case "$field" in ppid) echo "$pp";; time) echo "$tm";; command) echo "$cmd";; esac
  exit 0
done < "$T/procs"
exit 1
EOS
  chmod +x "$T/bin/ps"
}

stub_lsappinfo() { # reads the front pid from $T/front; no file = unknown
  cat > "$T/bin/lsappinfo" <<'EOS'
#!/bin/bash
[ -f "$T/front" ] || exit 1
case "$1" in
  front) if [ -f "$T/front-out" ]; then cat "$T/front-out"; else echo "ASN:0x0-0x1234:"; fi;;
  info) [ "$2 $3" = "-only pid" ] && [ "$4" = "ASN:0x0-0x1234:" ] && printf '"pid"=%s\n' "$(cat "$T/front")";;
esac
EOS
  chmod +x "$T/bin/lsappinfo"
}
stub_windows_bin() { # ready-made helper that prints $T/fs-pids; $T/fs-fail makes it fail
  mkdir -p "$CLAUDES_STATE_DIR/bin"
  cat > "$CLAUDES_STATE_DIR/bin/claudes-windows" <<'EOS'
#!/bin/bash
[ -f "$T/fs-fail" ] && exit 1
cat "$T/fs-pids" 2>/dev/null || true
EOS
  chmod +x "$CLAUDES_STATE_DIR/bin/claudes-windows"
  touch "$CLAUDES_STATE_DIR/bin/claudes-windows"
}
fake_now() { echo "$1" > "$T/now"; claudes_now() { cat "$T/now"; }; }
mkrunning() { stub_ps; printf '100\t%s\n' "$(DD)" > "$T/mainprocs"; }
mksession() { # relative-path [age-minutes]
  local f="$(DD)/$1"
  mkdir -p "$(dirname "$f")"; : > "$f"
  [ -z "${2:-}" ] || touch -t "$(date -v-"$2"M +%Y%m%d%H%M.%S)" "$f"
}

# ---- installed_build / update_state ----
@test "installed_build reads CFBundleVersion" {
  mkbundle "$CLAUDES_APP_SRC" 1000
  run installed_build
  [ "$output" = 1000 ]
}

@test "update_state none when no ShipItState plist" {
  mkbundle "$CLAUDES_APP_SRC" 1000
  run update_state
  [ "$output" = none ]
}

@test "update_state none for leftover plist pointing at a missing folder" {
  mkbundle "$CLAUDES_APP_SRC" 1000
  mkstate "file://$T/shipit/update.GONE/Claude.app/"
  stub_launchctl running
  run update_state
  [ "$output" = none ]
}

@test "update_state none when staged build equals installed" {
  mkbundle "$CLAUDES_APP_SRC" 1000
  mkbundle "$T/shipit/update.X/Claude.app" 1000
  mkstate "file://$T/shipit/update.X/Claude.app/"
  stub_launchctl running
  run update_state
  [ "$output" = none ]
}

@test "update_state waiting when staged is newer and ShipIt is running" {
  mkbundle "$CLAUDES_APP_SRC" 1000
  mkbundle "$T/shipit/update.X/Claude.app" 1001
  mkstate "file://$T/shipit/update.X/Claude.app/"
  stub_launchctl running
  run update_state
  [ "$output" = waiting ]
}

@test "update_state no-installer when staged is newer and ShipIt is not running" {
  mkbundle "$CLAUDES_APP_SRC" 1000
  mkbundle "$T/shipit/update.X/Claude.app" 1001
  mkstate "file://$T/shipit/update.X/Claude.app/"
  stub_launchctl "not running"
  run update_state
  [ "$output" = no-installer ]
}

@test "update_state no-installer when launchctl fails" {
  mkbundle "$CLAUDES_APP_SRC" 1000
  mkbundle "$T/shipit/update.X/Claude.app" 1001
  mkstate "file://$T/shipit/update.X/Claude.app/"
  printf '#!/bin/bash\nexit 113\n' > "$T/bin/launchctl"; chmod +x "$T/bin/launchctl"
  run update_state
  [ "$output" = no-installer ]
}

@test "staged_bundle_path decodes %20 and strips file:// and trailing slash" {
  mkdir -p "$T/shipit/my dir/update.X/Claude.app"
  mkstate "file://$T/shipit/my%20dir/update.X/Claude.app/"
  run staged_bundle_path
  [ "$status" -eq 0 ]
  [ "$output" = "$T/shipit/my dir/update.X/Claude.app" ]
}

@test "staged_build reads the staged bundle version" {
  mkbundle "$T/shipit/update.X/Claude.app" 77
  mkstate "file://$T/shipit/update.X/Claude.app/"
  run staged_build
  [ "$output" = 77 ]
}

@test "shipit_waiting false for not running" {
  stub_launchctl "not running"
  run shipit_waiting
  [ "$status" -eq 1 ]
}

# ---- ShipIt log ----
@test "shipit_log_size is 0 when missing and shipit_log_since returns only new text" {
  run shipit_log_size
  [ "$output" = 0 ]
  printf 'old line\n' > "$CLAUDES_SHIPIT_DIR/ShipIt_stderr.log"
  size="$(shipit_log_size)"
  [ "$size" = 9 ]
  printf 'new line\n' >> "$CLAUDES_SHIPIT_DIR/ShipIt_stderr.log"
  run shipit_log_since "$size"
  [ "$output" = "new line" ]
  run shipit_log_since 0
  [[ "$output" == *"old line"* && "$output" == *"new line"* ]]
}

# ---- managed prefs ----
@test "auto_updates_blocked true for the global file" {
  plutil -create xml1 "$T/managed/com.anthropic.claudefordesktop.plist"
  plutil -insert disableAutoUpdates -bool true "$T/managed/com.anthropic.claudefordesktop.plist"
  run auto_updates_blocked
  [ "$status" -eq 0 ]
  [ "$output" = "$T/managed/com.anthropic.claudefordesktop.plist" ]
}

@test "auto_updates_blocked true for the per-user binary file" {
  mkdir -p "$T/managed/tester"
  f="$T/managed/tester/com.anthropic.claudefordesktop.plist"
  plutil -create binary1 "$f"
  plutil -insert disableAutoUpdates -bool true "$f"
  run auto_updates_blocked
  [ "$status" -eq 0 ]
  [ "$output" = "$f" ]
}

@test "auto_updates_blocked false when absent or false" {
  run auto_updates_blocked
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  f="$T/managed/com.anthropic.claudefordesktop.plist"
  plutil -create xml1 "$f"
  plutil -insert disableAutoUpdates -bool false "$f"
  run auto_updates_blocked
  [ "$status" -eq 1 ]
}

# ---- known_accounts ----
mklauncher() { # suffix string-to-embed
  local d="$CLAUDES_APPS_DIR/Claude $1.app/Contents/MacOS"
  mkdir -p "$d"
  printf 'junk\0%s\0more junk\0' "$2" > "$d/launch"
}

@test "known_accounts merges config, launcher scan and default without duplicates" {
  export CLAUDES_SUPPORT_DIR="$HOME/Library/Application Support"
  mkdir -p "$CLAUDES_SUPPORT_DIR"
  mklauncher D "--user-data-dir=$CLAUDES_SUPPORT_DIR/Claude-Acct-D"    # also in config
  mklauncher C "--user-data-dir=$CLAUDES_SUPPORT_DIR/Claude-3p"        # scan only
  mklauncher A "--user-data-dir=%s/Library/Application Support/Claude" # %s expands, claims default
  mklauncher L "--user-data-dir=$CLAUDES_SUPPORT_DIR/Old"             # legacy
  touch "$CLAUDES_APPS_DIR/Claude L.app/Contents/MacOS/Claude-bin"
  mkdir -p "$CLAUDES_APPS_DIR/Claude Science.app/Contents/MacOS"       # no launch
  printf '# c\nD\tblue\tClaude-Acct-D\nB\tyellow\tClaude-Acct-B\nL\tred\tOld\n' > "$CLAUDES_CONFIG"
  run known_accounts
  [ "$status" -eq 0 ]
  [[ "$output" == *"$CLAUDES_SUPPORT_DIR/Claude-Acct-D"$'\t'"$CLAUDES_APPS_DIR/Claude D.app"* ]]
  [[ "$output" == *"$CLAUDES_SUPPORT_DIR/Claude-3p"$'\t'"$CLAUDES_APPS_DIR/Claude C.app"* ]]
  [[ "$output" == *"$CLAUDES_SUPPORT_DIR/Claude"$'\t'"$CLAUDES_APPS_DIR/Claude A.app"* ]]
  [[ "$output" != *"Claude-Acct-B"* && "$output" != *"Old"* && "$output" != *Science* && "$output" != *"%s"* ]]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 3 ]
}

@test "known_accounts always includes the default folder with empty launcher" {
  run known_accounts
  [ "$output" = "$CLAUDES_SUPPORT_DIR/Claude"$'\t' ]
  run launcher_for "$CLAUDES_SUPPORT_DIR/Claude"
  [ -z "$output" ]
}

@test "launcher_for returns the launcher of a folder" {
  mklauncher C "--user-data-dir=$CLAUDES_SUPPORT_DIR/Claude-3p"
  run launcher_for "$CLAUDES_SUPPORT_DIR/Claude-3p"
  [ "$output" = "$CLAUDES_APPS_DIR/Claude C.app" ]
}

@test "known_accounts compares folders exactly (Claude vs Claude-3p)" {
  mklauncher C "--user-data-dir=$CLAUDES_SUPPORT_DIR/Claude-3p"
  run known_accounts
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 2 ]
}

# ---- markers ----
mkmarker() { mkdir -p "$T/dd"; printf '%s' "$1" > "$T/dd/stealth-relaunch"; }

@test "marker: stealth update marker says update quit" {
  mkmarker '{"ts":1700000000000,"windowVisible":true,"navEntries":3}'
  run marker_says_update_quit "$T/dd"
  [ "$status" -eq 0 ]
}

@test "marker: userQuit navOnly is not an update quit" {
  mkmarker '{"ts":1700000000000,"navOnly":true,"userQuit":true}'
  run marker_says_update_quit "$T/dd"
  [ "$status" -eq 1 ]
}

@test "marker: navOnly alone is not an update quit" {
  mkmarker '{"ts":1700000000000,"navOnly":true}'
  run marker_says_update_quit "$T/dd"
  [ "$status" -eq 1 ]
}

@test "marker: userQuit alone is not an update quit" {
  mkmarker '{"ts":1700000000000,"userQuit":true}'
  run marker_says_update_quit "$T/dd"
  [ "$status" -eq 1 ]
}

@test "marker: missing and garbage are not update quits" {
  run marker_says_update_quit "$T/dd"
  [ "$status" -eq 1 ]
  mkmarker 'not json at all {{{'
  run marker_says_update_quit "$T/dd"
  [ "$status" -eq 1 ]
}

@test "marker_age counts seconds since ts" {
  now_ms=$(( ($(date +%s) - 90) * 1000 ))
  mkmarker "{\"ts\":$now_ms}"
  run marker_age "$T/dd"
  [ "$status" -eq 0 ]
  [ "$output" -ge 90 ]
  [ "$output" -le 95 ]
}

# ---- time parser ----
@test "ps_time_to_seconds parses mm:ss, hh:mm:ss and dd-hh:mm:ss" {
  [ "$(ps_time_to_seconds 0:24.99)" = "24.99" ]
  [ "$(ps_time_to_seconds 1:02:03.50)" = "3723.50" ]
  [ "$(ps_time_to_seconds 2-01:00:00.00)" = "176400.00" ]
}

# ---- front_app_pid / fullscreen_pids ----
DD() { echo "$CLAUDES_SUPPORT_DIR/Claude-3p"; }

@test "front_app_pid: digits of the pid lsappinfo reports" {
  echo 15530 > "$T/front"
  run front_app_pid
  [ "$status" -eq 0 ]
  [ "$output" = 15530 ]
}

@test "front_app_pid: status 2 when lsappinfo fails" {
  rm -f "$T/front"
  run front_app_pid
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "front_app_pid: status 2 when lsappinfo prints nothing at all" {
  echo 1 > "$T/front"; : > "$T/front-out"
  run front_app_pid
  [ "$status" -eq 2 ]
}

@test "front_app_pid: status 1 when the pid is not a number (lsappinfo works, no front app)" {
  echo "[ NULL ]" > "$T/front"
  run front_app_pid
  [ "$status" -eq 1 ]
}

@test "front_app_pid: status 1 when lsappinfo works and says there is no front app" {
  echo 1 > "$T/front"; echo "[ NULL ]" > "$T/front-out"
  run front_app_pid
  [ "$status" -eq 1 ]
}

@test "account_idle: lsappinfo working but reporting no front app is not busy and not logged" {
  mkrunning
  echo 1 > "$T/front"; echo "[ NULL ]" > "$T/front-out"
  run account_idle "$(DD)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$CLAUDES_LOG_DIR/update.log" ]
}

@test "account_idle: lsappinfo printing nothing is busy and logged" {
  mkrunning
  echo 1 > "$T/front"; : > "$T/front-out"
  run account_idle "$(DD)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not check which app is in front"* ]]
  grep -q "could not check which app is in front" "$CLAUDES_LOG_DIR/update.log"
}

@test "_idle_log: update.log over 1 MB is cut to its last 2000 lines" {
  mkdir -p "$CLAUDES_LOG_DIR"
  eval "$(sed -n '/^_update_trim_log()/,/^}/p' "$REPO/lib/update.sh")"   # the real trimmer
  awk 'BEGIN { for (i = 1; i <= 30000; i++) printf "line %d padded to make the file big enough for the limit\n", i }' > "$CLAUDES_LOG_DIR/update.log"
  _idle_log "one more"
  [ "$(wc -l < "$CLAUDES_LOG_DIR/update.log" | tr -d ' ')" = 2000 ]
  [[ "$(tail -n 1 "$CLAUDES_LOG_DIR/update.log")" == *"idle check: one more" ]]
}

@test "fullscreen_pids prints what the helper prints" {
  printf '100\n200\n' > "$T/fs-pids"
  run fullscreen_pids
  [ "$status" -eq 0 ]
  [ "$output" = $'100\n200' ]
}

@test "fullscreen_pids: status 1 when the helper fails" {
  touch "$T/fs-fail"
  run fullscreen_pids
  [ "$status" -eq 1 ]
}

@test "fullscreen_pids compiles the swift file once with swiftc into the state folder" {
  rm -f "$CLAUDES_STATE_DIR/bin/claudes-windows"
  echo '// fake' > "$T/windows.swift"
  _UD_WINDOWS_SWIFT="$T/windows.swift"
  cat > "$T/bin/swiftc" <<'EOS'
#!/bin/bash
echo x >> "$T/swiftc-calls"
[ "$1" = -O ] && [ "$2" = -o ] && [ "$4" = "$T/windows.swift" ] || exit 2
printf '#!/bin/bash\necho 321\n' > "$3"; chmod +x "$3"
EOS
  chmod +x "$T/bin/swiftc"
  run fullscreen_pids
  [ "$output" = 321 ]
  run fullscreen_pids
  [ "$output" = 321 ]
  [ "$(wc -l < "$T/swiftc-calls" | tr -d ' ')" = 1 ]
  [ -x "$CLAUDES_STATE_DIR/bin/claudes-windows" ]
  # a newer swift file is compiled again
  touch -t 203001010000 "$T/windows.swift"
  fullscreen_pids >/dev/null
  [ "$(wc -l < "$T/swiftc-calls" | tr -d ' ')" = 2 ]
}

@test "fullscreen_pids falls back to swift FILE when swiftc fails" {
  rm -f "$CLAUDES_STATE_DIR/bin/claudes-windows"
  echo '// fake' > "$T/windows.swift"
  _UD_WINDOWS_SWIFT="$T/windows.swift"
  printf '#!/bin/bash\nexit 1\n' > "$T/bin/swiftc"
  printf '#!/bin/bash\n[ "$1" = "%s" ] && echo 654\n' "$T/windows.swift" > "$T/bin/swift"
  chmod +x "$T/bin/swiftc" "$T/bin/swift"
  run fullscreen_pids
  [ "$status" -eq 0 ]
  [ "$output" = 654 ]
}

@test "fullscreen_pids: status 1 when nothing can compile or run" {
  rm -f "$CLAUDES_STATE_DIR/bin/claudes-windows"
  echo '// fake' > "$T/windows.swift"
  _UD_WINDOWS_SWIFT="$T/windows.swift"
  printf '#!/bin/bash\nexit 1\n' > "$T/bin/swiftc"; cp "$T/bin/swiftc" "$T/bin/swift"
  chmod +x "$T/bin/swiftc" "$T/bin/swift"
  run fullscreen_pids
  [ "$status" -eq 1 ]
}

@test "fullscreen_pids in a dry run compiles outside the state folder and leaves it untouched" {
  rm -f "$CLAUDES_STATE_DIR/bin/claudes-windows"
  rmdir "$CLAUDES_STATE_DIR/bin" "$CLAUDES_STATE_DIR"
  echo '// fake' > "$T/windows.swift"
  _UD_WINDOWS_SWIFT="$T/windows.swift"
  cat > "$T/bin/swiftc" <<'EOS'
#!/bin/bash
printf '#!/bin/bash\necho 321\n' > "$3"; chmod +x "$3"
EOS
  chmod +x "$T/bin/swiftc"
  CLAUDES_IDLE_READONLY=1 run fullscreen_pids
  [ "$status" -eq 0 ]
  [ "$output" = 321 ]
  [ ! -e "$CLAUDES_STATE_DIR" ]
}

# ---- account_idle ----
@test "account_idle: not running is idle" {
  stub_ps
  echo 100 > "$T/front"
  run account_idle "$(DD)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "account_idle: busy when its window is in front" {
  mkrunning
  echo 100 > "$T/front"
  run account_idle "$(DD)"
  [ "$status" -eq 1 ]
  [ "$output" = "its window is in front" ]
}

@test "account_idle: another app in front is not busy" {
  mkrunning
  echo 999 > "$T/front"
  run account_idle "$(DD)"
  [ "$status" -eq 0 ]
}

@test "account_idle: lsappinfo failing is busy with a reason and is logged" {
  mkrunning
  rm -f "$T/front"
  run account_idle "$(DD)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not check which app is in front"* ]]
  grep -q "could not check which app is in front" "$CLAUDES_LOG_DIR/update.log"
}

@test "account_idle: dry run does not count a failing lsappinfo as busy" {
  mkrunning
  rm -f "$T/front"
  CLAUDES_IDLE_READONLY=1 run account_idle "$(DD)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$CLAUDES_LOG_DIR/update.log" ]
}

@test "account_idle: busy when a window is full screen" {
  mkrunning
  printf '55\n100\n' > "$T/fs-pids"
  run account_idle "$(DD)"
  [ "$status" -eq 1 ]
  [ "$output" = "a window is full screen" ]
}

@test "account_idle: another app full screen is not busy; pid 1000 is not pid 100" {
  mkrunning
  printf '55\n1000\n' > "$T/fs-pids"
  run account_idle "$(DD)"
  [ "$status" -eq 0 ]
}

@test "account_idle: full-screen helper failing is busy, names the fix and is logged" {
  mkrunning
  touch "$T/fs-fail"
  run account_idle "$(DD)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not check for full-screen windows"* ]]
  [[ "$output" == *"xcode-select --install"* ]]
  grep -q "xcode-select --install" "$CLAUDES_LOG_DIR/update.log"
}

@test "account_idle: dry run does not count a failing full-screen helper as busy" {
  mkrunning
  touch "$T/fs-fail"
  CLAUDES_IDLE_READONLY=1 run account_idle "$(DD)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$CLAUDES_LOG_DIR/update.log" ]
}

@test "idle_rules_report: notes both checks that cannot run and names the fix" {
  rm -f "$T/front"; touch "$T/fs-fail"
  run idle_rules_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"lsappinfo failed"* ]]
  [[ "$output" == *"xcode-select --install"* ]]
  [[ "$output" != *"counted as not busy"* ]]
}

@test "account_idle: busy by recent Claude Code session file" {
  mkrunning
  mksession claude-code-sessions/a/b/local_x.json
  run account_idle "$(DD)"
  [ "$status" -eq 1 ]
  [ "$output" = "a Claude Code session was active 0 min ago" ]
}

@test "account_idle: session reason counts the minutes" {
  mkrunning
  mksession claude-code-sessions/a/b/local_x.json 4
  run account_idle "$(DD)"
  [ "$status" -eq 1 ]
  [[ "$output" == "a Claude Code session was active "[34]" min ago" ]]
}

@test "account_idle: an old session file does not make it busy" {
  mkrunning
  mksession claude-code-sessions/a/b/local_x.json 30
  run account_idle "$(DD)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "account_idle: scheduled-tasks.json and other files in claude-code-sessions are ignored" {
  mkrunning
  mksession claude-code-sessions/a/b/scheduled-tasks.json
  mksession claude-code-sessions/a/b/other.json
  mksession claude-code-sessions/a/b/local_x.txt
  run account_idle "$(DD)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "account_idle: session files are judged by the claudes_now clock" {
  mkrunning
  mksession claude-code-sessions/a/b/local_x.json
  m="$(stat -f %m "$(DD)/claude-code-sessions/a/b/local_x.json")"
  fake_now $((m + 9 * 60 + 59))
  run account_idle "$(DD)"
  [ "$status" -eq 1 ]
  [ "$output" = "a Claude Code session was active 9 min ago" ]
  fake_now $((m + 10 * 60))
  run account_idle "$(DD)"
  [ "$status" -eq 0 ]
}

@test "account_idle: busy by recent Cowork session file" {
  mkrunning
  mksession local-agent-mode-sessions/a/b/audit.jsonl
  run account_idle "$(DD)"
  [ "$status" -eq 1 ]
  [ "$output" = "a Cowork session was active 0 min ago" ]
}

@test "account_idle: old Cowork files do not make it busy" {
  mkrunning
  mksession local-agent-mode-sessions/a/b/audit.jsonl 30
  run account_idle "$(DD)"
  [ "$status" -eq 0 ]
}

@test "account_idle: Cowork skills-plugin files and manifest.json are ignored" {
  mkrunning
  mksession local-agent-mode-sessions/skills-plugin/x/SKILL.md
  mksession local-agent-mode-sessions/a/skills-plugin/y/SKILL.md
  mksession local-agent-mode-sessions/manifest.json
  run account_idle "$(DD)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "account_idle: busy by CPU of Claude Code children" {
  mkrunning
  cat > "$T/procs" <<TABLE
100 1 5:00.00 $CLAUDES_APP_SRC/Contents/MacOS/Claude
101 100 9:00.00 $CLAUDES_APP_SRC/Contents/Helpers/disclaimer --pgroup --
102 101 0:10.00 /x/claude-code/1/claude --foo
TABLE
  sed 's/^102 101 0:10.00/102 101 0:30.00/; s/^100 1 5:00.00/100 1 9:00.00/' "$T/procs" > "$T/procs2"
  CLAUDES_CPU_SAMPLE=20 CLAUDES_CPU_IDLE=2 run account_idle "$(DD)"
  [ "$status" -eq 1 ]
  [ "$output" = "Claude Code used 20s of CPU in 20s" ]
}

@test "account_idle: idle when only Claude-owned processes burn CPU" {
  mkrunning
  cat > "$T/procs" <<TABLE
100 1 5:00.00 $CLAUDES_APP_SRC/Contents/MacOS/Claude
101 100 9:00.00 $CLAUDES_APP_SRC/Contents/Helpers/disclaimer --pgroup --
102 101 0:10.00 /x/claude-code/1/claude --foo
TABLE
  sed 's/^101 100 9:00.00/101 100 20:00.00/; s/^102 101 0:10.00/102 101 0:11.00/' "$T/procs" > "$T/procs2"
  run account_idle "$(DD)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- account_idle_settled ----
IS() { echo "$CLAUDES_STATE_DIR/idle-since"; }

@test "settled: first idle sighting starts the countdown and writes idle-since" {
  mkrunning
  fake_now 1000
  run account_idle_settled "$(DD)"
  [ "$status" -eq 1 ]
  [ "$output" = "quiet for 0 of 10 minutes" ]
  [ "$(cat "$(IS)")" = "$(printf '%s\t100\t1000' "$(DD)")" ]
}

@test "settled: countdown continues, then passes at 10 minutes" {
  mkrunning
  fake_now 1000
  account_idle_settled "$(DD)" || true
  fake_now $((1000 + 4 * 60 + 30))
  run account_idle_settled "$(DD)"
  [ "$status" -eq 1 ]
  [ "$output" = "quiet for 4 of 10 minutes" ]
  [ "$(cat "$(IS)")" = "$(printf '%s\t100\t1000' "$(DD)")" ]
  fake_now $((1000 + 600))
  run account_idle_settled "$(DD)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "settled: busy removes the line and prints the reason" {
  mkrunning
  fake_now 1000
  account_idle_settled "$(DD)" || true
  printf 'other\t7\t5\n' >> "$(IS)"
  echo 100 > "$T/front"
  run account_idle_settled "$(DD)"
  [ "$status" -eq 1 ]
  [ "$output" = "its window is in front" ]
  [ "$(cat "$(IS)")" = "$(printf 'other\t7\t5')" ]
  # idle again afterwards: the countdown starts from zero
  echo 999 > "$T/front"
  fake_now 1500
  run account_idle_settled "$(DD)"
  [ "$output" = "quiet for 0 of 10 minutes" ]
  [ "$(grep -c . "$(IS)")" = 2 ]
  grep -q "^$(DD)"$'\t'"100"$'\t'"1500$" "$(IS)"
}

@test "settled: a new main pid restarts the countdown" {
  mkrunning
  fake_now 1000
  account_idle_settled "$(DD)" || true
  printf '222\t%s\n' "$(DD)" > "$T/mainprocs"
  fake_now 1700
  run account_idle_settled "$(DD)"
  [ "$status" -eq 1 ]
  [ "$output" = "quiet for 0 of 10 minutes" ]
  [ "$(cat "$(IS)")" = "$(printf '%s\t222\t1700' "$(DD)")" ]
}

@test "settled: other accounts keep their own lines" {
  mkrunning
  mkdir -p "$CLAUDES_STATE_DIR"
  printf 'other\t7\t5\n' > "$(IS)"
  fake_now 1000
  account_idle_settled "$(DD)" || true
  grep -q "^other"$'\t'"7"$'\t'"5$" "$(IS)"
  grep -q "^$(DD)"$'\t'"100"$'\t'"1000$" "$(IS)"
}

@test "settled: not running counts as settled and drops its line" {
  stub_ps
  mkdir -p "$CLAUDES_STATE_DIR"
  printf '%s\t100\t1000\n' "$(DD)" > "$(IS)"
  run account_idle_settled "$(DD)"
  [ "$status" -eq 0 ]
  [ ! -s "$(IS)" ]
}

@test "settled: readonly never writes or deletes idle-since" {
  mkrunning
  fake_now 1000
  CLAUDES_IDLE_READONLY=1 run account_idle_settled "$(DD)"
  [ "$status" -eq 1 ]
  [ "$output" = "quiet for 0 of 10 minutes" ]
  [ ! -e "$(IS)" ]
  printf '%s\t100\t400\n' "$(DD)" > "$(IS)"
  cp "$(IS)" "$T/before"
  CLAUDES_IDLE_READONLY=1 run account_idle_settled "$(DD)"
  [ "$status" -eq 0 ]
  echo 100 > "$T/front"
  CLAUDES_IDLE_READONLY=1 run account_idle_settled "$(DD)"
  [ "$status" -eq 1 ]
  [ "$output" = "its window is in front" ]
  cmp "$(IS)" "$T/before"
  [ ! -e "$CLAUDES_STATE_DIR/idle-since.lock" ]
}

# ---- idle_rules_report ----
@test "idle_rules_report lists copied rules and the ones that cannot be seen" {
  echo 5 > "$T/front"
  run idle_rules_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"Copied"* && "$output" == *"window is in front"* && "$output" == *"full screen"* ]]
  [[ "$output" == *"10 quiet minutes"* && "$output" == *"CPU"* ]]
  [[ "$output" == *"unsaved typing"* && "$output" == *"export or import"* ]]
  [[ "$output" == *"/loop"* && "$output" == *"still streaming"* ]]
  [[ "$output" != *"could not"* ]]
}

@test "idle_rules_report says when full screen or front app cannot be checked" {
  touch "$T/fs-fail"
  run idle_rules_report
  [[ "$output" == *"could not tell which app is in front"* ]]
  [[ "$output" == *"could not check for full-screen windows"* ]]
}

# ---- inside_claude_copy ----
@test "inside_claude_copy true when an ancestor is a Claude main process" {
  stub_ps
  cat > "$T/procs" <<TABLE
10 1 0:01.00 /sbin/launchd
200 10 0:01.00 $CLAUDES_APP_SRC/Contents/MacOS/Claude --user-data-dir=/x/y
201 200 0:01.00 $CLAUDES_APP_SRC/Contents/Helpers/disclaimer --pgroup --
202 201 0:01.00 /x/claude
203 202 0:01.00 /bin/bash
TABLE
  run inside_claude_copy 203
  [ "$status" -eq 0 ]
}

@test "inside_claude_copy false for a plain Terminal tree and for Claude Helper" {
  stub_ps
  cat > "$T/procs" <<TABLE
10 1 0:01.00 /sbin/launchd
300 10 0:01.00 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
301 300 0:01.00 /bin/zsh
302 301 0:01.00 /bin/bash
400 10 0:01.00 $CLAUDES_APP_SRC/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=gpu
401 400 0:01.00 /bin/bash
TABLE
  run inside_claude_copy 302
  [ "$status" -eq 1 ]
  run inside_claude_copy 401
  [ "$status" -eq 1 ]
}
