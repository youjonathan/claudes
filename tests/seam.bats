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
  run bash -c 'set -euo pipefail; for f in common config instance procs update_detect release install update watch; do source "$1/lib/$f.sh"; done; echo ok' _ "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "every contract function is defined" {
  run bash -c 'set -euo pipefail; for f in common config instance procs update_detect release install update watch; do source "$1/lib/$f.sh"; done
    for fn in claudes_sleep claude_main_procs datadir_main_pid datadir_running proc_tree crashpad_pids stop_datadir \
      installed_build shipit_waiting staged_bundle_path staged_build update_state shipit_log_size shipit_log_since \
      auto_updates_blocked known_accounts launcher_for marker_says_update_quit marker_age account_idle inside_claude_copy \
      cmd_update doctor_update_report update_open_accounts update_all_idle update_quit_all update_wait_install \
      update_close_plain_relaunch update_reopen_accounts update_safety_net update_lock update_unlock \
      cmd_watch watch_on watch_off watch_status \
      release_feed_url release_fetch_feed release_check release_is_newer release_verify_app release_prepare \
      release_ready_version release_ready_app release_ready_get release_ready_set release_discard \
      install_backup_old install_shipit_path install_via_shipit install_via_move install_new install_rollback install_finish; do
      declare -F "$fn" >/dev/null || { echo "missing $fn"; exit 1; }
    done; echo ok' _ "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "the idle functions of the update flow exist once update_detect.sh has them" {
  run bash -c 'set -euo pipefail; for f in common config instance procs update_detect; do source "$1/lib/$f.sh"; done
    declare -F account_idle_settled >/dev/null || exit 3
    declare -F idle_rules_report >/dev/null || exit 3
    ! declare -F user_idle_seconds >/dev/null' _ "$REPO"
  if [ "$status" -eq 3 ]; then skip "account_idle_settled / idle_rules_report arrive with piece 2"; fi
  [ "$status" -eq 0 ]
}

@test "bin/claudes sources release.sh and install.sh" {
  grep -q 'release.sh' "$REPO/bin/claudes"
  grep -q 'install.sh' "$REPO/bin/claudes"
}

@test "defaults apply when no overrides are set" {
  run env -i HOME=/home/x PATH="$PATH" bash -c 'source "$1/lib/common.sh"
    echo "$CLAUDES_APP_SRC|$CLAUDES_SUPPORT_DIR|$CLAUDES_STATE_DIR|$CLAUDES_POLL|$CLAUDES_MARKER_MAX_AGE"' _ "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "/Applications/Claude.app|/home/x/Library/Application Support|/home/x/Library/Application Support/claudes|60|43200" ]
}

@test "env overrides are honoured" {
  export CLAUDES_APP_SRC=/x/Claude.app CLAUDES_SUPPORT_DIR=/x/sup CLAUDES_SHIPIT_DIR=/x/ship \
    CLAUDES_MANAGED_PREFS_DIR=/x/mp CLAUDES_LAUNCHAGENTS_DIR=/x/la CLAUDES_STATE_DIR=/x/st CLAUDES_LOG_DIR=/x/log \
    CLAUDES_POLL=1 CLAUDES_IDLE_MINUTES=2 CLAUDES_CPU_SAMPLE=3 CLAUDES_CPU_IDLE=4 CLAUDES_STOP_TIMEOUT=5 \
    CLAUDES_INSTALL_TIMEOUT=6 CLAUDES_MARKER_GRACE=8 CLAUDES_MARKER_MAX_AGE=9
  source "$REPO/lib/common.sh"
  [ "$CLAUDES_APP_SRC" = /x/Claude.app ]
  [ "$CLAUDES_SUPPORT_DIR" = /x/sup ]
  [ "$CLAUDES_SHIPIT_DIR" = /x/ship ]
  [ "$CLAUDES_MANAGED_PREFS_DIR" = /x/mp ]
  [ "$CLAUDES_LAUNCHAGENTS_DIR" = /x/la ]
  [ "$CLAUDES_STATE_DIR" = /x/st ]
  [ "$CLAUDES_LOG_DIR" = /x/log ]
  [ "$CLAUDES_POLL$CLAUDES_IDLE_MINUTES$CLAUDES_CPU_SAMPLE$CLAUDES_CPU_IDLE$CLAUDES_STOP_TIMEOUT$CLAUDES_INSTALL_TIMEOUT$CLAUDES_MARKER_GRACE$CLAUDES_MARKER_MAX_AGE" = 12345689 ]
}

@test "datadir_running is false for a folder nothing is running" {
  source "$REPO/lib/common.sh"; source "$REPO/lib/procs.sh"
  run datadir_running "/definitely/not/a/running/dir"
  [ "$status" -eq 1 ]
}
