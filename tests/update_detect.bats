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

# ---- account_idle ----
DD() { echo "$CLAUDES_SUPPORT_DIR/Claude-3p"; }

@test "account_idle: not running is idle" {
  stub_ps
  run account_idle "$(DD)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "account_idle: busy by recent session file" {
  stub_ps
  printf '100\t%s\n' "$(DD)" > "$T/mainprocs"
  mkdir -p "$(DD)/claude-code-sessions/a"
  touch "$(DD)/claude-code-sessions/a/s.json"
  run account_idle "$(DD)"
  [ "$status" -eq 1 ]
  [[ "$output" == "session files changed "*" min ago" ]]
}

@test "account_idle: old session files do not make it busy" {
  stub_ps
  printf '100\t%s\n' "$(DD)" > "$T/mainprocs"
  mkdir -p "$(DD)/claude-code-sessions/a"
  touch -t 202001010000 "$(DD)/claude-code-sessions/a/s.json"
  printf '100 1 0:10.00 %s/Contents/MacOS/Claude\n' "$CLAUDES_APP_SRC" > "$T/procs"
  run account_idle "$(DD)"
  [ "$status" -eq 0 ]
}

@test "account_idle: busy by CPU of Claude Code children" {
  stub_ps
  printf '100\t%s\n' "$(DD)" > "$T/mainprocs"
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
  stub_ps
  printf '100\t%s\n' "$(DD)" > "$T/mainprocs"
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
