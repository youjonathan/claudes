#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "--help lists update and watch" {
  run "$REPO/bin/claudes" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"claudes update [--dry-run]"* ]]
  [[ "$output" == *"claudes watch on|off|status"* ]]
}

@test "sourcing every lib under set -euo pipefail works" {
  run bash -c 'set -euo pipefail; for f in common config instance procs update_detect update watch; do source "$1/lib/$f.sh"; done; echo ok' _ "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "every contract function is defined" {
  run bash -c 'set -euo pipefail; for f in common config instance procs update_detect update watch; do source "$1/lib/$f.sh"; done
    for fn in claudes_sleep claude_main_procs datadir_main_pid datadir_running proc_tree crashpad_pids stop_datadir \
      installed_build shipit_waiting staged_bundle_path staged_build update_state shipit_log_size shipit_log_since \
      auto_updates_blocked known_accounts launcher_for marker_says_update_quit marker_age account_idle inside_claude_copy \
      cmd_update doctor_update_report update_open_accounts update_all_idle update_quit_all update_wait_install \
      update_close_plain_relaunch update_reopen_accounts update_safety_net update_lock update_unlock \
      cmd_watch watch_on watch_off watch_status; do
      declare -F "$fn" >/dev/null || { echo "missing $fn"; exit 1; }
    done; echo ok' _ "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "defaults apply when no overrides are set" {
  run env -i HOME=/home/x PATH="$PATH" bash -c 'source "$1/lib/common.sh"
    echo "$CLAUDES_APP_SRC|$CLAUDES_SUPPORT_DIR|$CLAUDES_STATE_DIR|$CLAUDES_POLL|$CLAUDES_MAX_WAIT|$CLAUDES_MARKER_MAX_AGE"' _ "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "/Applications/Claude.app|/home/x/Library/Application Support|/home/x/Library/Application Support/claudes|60|14400|43200" ]
}

@test "env overrides are honoured" {
  export CLAUDES_APP_SRC=/x/Claude.app CLAUDES_SUPPORT_DIR=/x/sup CLAUDES_SHIPIT_DIR=/x/ship \
    CLAUDES_MANAGED_PREFS_DIR=/x/mp CLAUDES_LAUNCHAGENTS_DIR=/x/la CLAUDES_STATE_DIR=/x/st CLAUDES_LOG_DIR=/x/log \
    CLAUDES_POLL=1 CLAUDES_IDLE_MINUTES=2 CLAUDES_CPU_SAMPLE=3 CLAUDES_CPU_IDLE=4 CLAUDES_STOP_TIMEOUT=5 \
    CLAUDES_INSTALL_TIMEOUT=6 CLAUDES_MAX_WAIT=7 CLAUDES_MARKER_GRACE=8 CLAUDES_MARKER_MAX_AGE=9
  source "$REPO/lib/common.sh"
  [ "$CLAUDES_APP_SRC" = /x/Claude.app ]
  [ "$CLAUDES_SUPPORT_DIR" = /x/sup ]
  [ "$CLAUDES_SHIPIT_DIR" = /x/ship ]
  [ "$CLAUDES_MANAGED_PREFS_DIR" = /x/mp ]
  [ "$CLAUDES_LAUNCHAGENTS_DIR" = /x/la ]
  [ "$CLAUDES_STATE_DIR" = /x/st ]
  [ "$CLAUDES_LOG_DIR" = /x/log ]
  [ "$CLAUDES_POLL$CLAUDES_IDLE_MINUTES$CLAUDES_CPU_SAMPLE$CLAUDES_CPU_IDLE$CLAUDES_STOP_TIMEOUT$CLAUDES_INSTALL_TIMEOUT$CLAUDES_MAX_WAIT$CLAUDES_MARKER_GRACE$CLAUDES_MARKER_MAX_AGE" = 123456789 ]
}

@test "datadir_running is exact-match and stub bodies fail loudly" {
  source "$REPO/lib/common.sh"; source "$REPO/lib/procs.sh"
  run datadir_running "/definitely/not/a/running/dir"
  [ "$status" -eq 1 ]
  source "$REPO/lib/update.sh"
  run cmd_update
  [ "$status" -eq 1 ]
  [[ "$output" == *"not implemented yet"* ]]
}
