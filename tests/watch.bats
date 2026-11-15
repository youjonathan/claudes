#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/stubs" "$T/agents" "$T/logs"
  export CLAUDES_LAUNCHAGENTS_DIR="$T/agents" CLAUDES_LOG_DIR="$T/logs"
  export LC_CALLS="$T/launchctl.calls"
  : > "$LC_CALLS"
  # launchctl stub: records args; `print` succeeds only if LC_LOADED=1
  cat > "$T/stubs/launchctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$LC_CALLS"
if [ "$1" = print ]; then [ "${LC_LOADED:-0}" = 1 ]; exit $?; fi
exit 0
STUB
  chmod +x "$T/stubs/launchctl"
  export PATH="$T/stubs:$PATH"
  LABEL=io.github.youjonathan.claudes.update-watcher
  PLIST="$T/agents/$LABEL.plist"
  UID_="$(id -u)"
}

# run a watch subcommand with the libs sourced; auto_updates_blocked is faked
w() { # $@: watch args. env: SELF_DIR, BLOCKED
  bash -c 'set -euo pipefail
    source "$1/lib/common.sh"; source "$1/lib/watch.sh"
    auto_updates_blocked() { [ -n "${BLOCKED:-}" ] && echo "$BLOCKED"; }
    if [ -n "${SELF_DIR:-}" ]; then SELF="$SELF_DIR"; fi
    shift; cmd_watch "$@"' _ "$REPO" "$@"
}

@test "on writes a valid plist with the right contents and bootstraps it" {
  SELF_DIR="/opt/cl/bin" run w on
  [ "$status" -eq 0 ]
  [ -f "$PLIST" ]
  plutil -lint "$PLIST"
  [ "$(plutil -extract Label raw -o - "$PLIST")" = "$LABEL" ]
  [ "$(plutil -extract ProgramArguments.0 raw -o - "$PLIST")" = "/opt/cl/bin/claudes" ]
  [ "$(plutil -extract ProgramArguments.1 raw -o - "$PLIST")" = "update" ]
  [ "$(plutil -extract ProgramArguments.2 raw -o - "$PLIST")" = "--watch-run" ]
  [ "$(plutil -extract ProgramArguments raw -o - "$PLIST")" = "3" ]
  [ "$(plutil -extract StartInterval raw -o - "$PLIST")" = "300" ]
  [ "$(plutil -extract StandardOutPath raw -o - "$PLIST")" = "$T/logs/update-watcher.log" ]
  [ "$(plutil -extract StandardErrorPath raw -o - "$PLIST")" = "$T/logs/update-watcher.log" ]
  grep -qx "bootstrap gui/$UID_ $PLIST" "$LC_CALLS"
}

@test "on twice does bootout then bootstrap" {
  SELF_DIR=/opt/cl/bin run w on
  [ "$status" -eq 0 ]
  : > "$LC_CALLS"
  LC_LOADED=1 SELF_DIR=/opt/cl/bin run w on
  [ "$status" -eq 0 ]
  grep -n . "$LC_CALLS"
  b="$(grep -n "^bootout gui/$UID_/$LABEL" "$LC_CALLS" | head -1 | cut -d: -f1)"
  s="$(grep -n "^bootstrap gui/$UID_ $PLIST" "$LC_CALLS" | head -1 | cut -d: -f1)"
  [ -n "$b" ] && [ -n "$s" ] && [ "$b" -lt "$s" ]
}

@test "on refuses when updates are blocked and writes nothing" {
  BLOCKED=/Library/x.plist SELF_DIR=/opt/cl/bin run w on
  [ "$status" -eq 1 ]
  [[ "$output" == *"/Library/x.plist"* ]]
  [ ! -e "$PLIST" ]
  [ ! -s "$LC_CALLS" ]
}

@test "on fails clearly when SELF is unset" {
  run w on
  [ "$status" -eq 1 ]
  [[ "$output" == *"SELF"* ]]
  [ ! -e "$PLIST" ]
}

@test "off boots out and removes the plist" {
  SELF_DIR=/opt/cl/bin run w on
  : > "$LC_CALLS"
  LC_LOADED=1 run w off
  [ "$status" -eq 0 ]
  grep -qx "bootout gui/$UID_/$LABEL" "$LC_CALLS"
  [ ! -e "$PLIST" ]
}

@test "off when not installed says so and exits 0" {
  run w off
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed"* ]]
  ! grep -q bootout "$LC_CALLS"
}

@test "status when not installed" {
  run w status
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed: no"* ]]
  [[ "$output" == *"loaded: no"* ]]
}

@test "status when installed and loaded shows the last 5 log lines" {
  SELF_DIR=/opt/cl/bin run w on
  for i in 1 2 3 4 5 6 7; do echo "line $i" >> "$T/logs/update-watcher.log"; done
  LC_LOADED=1 run w status
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed: yes"* ]]
  [[ "$output" == *"loaded: yes"* ]]
  [[ "$output" == *"line 7"* ]]
  [[ "$output" == *"line 3"* ]]
  [[ "$output" != *"line 2"* ]]
}

@test "a path with & and < is XML-escaped and the plist still lints" {
  mkdir -p "$T/a&b<c"
  SELF_DIR="$T/a&b<c" run w on
  [ "$status" -eq 0 ]
  grep -q 'a&amp;b&lt;c/claudes' "$PLIST"
  plutil -lint "$PLIST"
  [ "$(plutil -extract ProgramArguments.0 raw -o - "$PLIST")" = "$T/a&b<c/claudes" ]
}

@test "unknown subcommand prints usage and exits 1" {
  run w bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: claudes watch on|off|status"* ]]
  run w
  [ "$status" -eq 1 ]
}
