#!/bin/bash
# lib/update.sh — claudes update. Source, do not execute.

# [--dry-run] [--watch-run] -> install a waiting Claude update and reopen accounts; exit status 0/1
cmd_update() { echo "claudes: cmd_update not implemented yet" >&2; return 1; }

# -> prints update/watcher/launcher lines for claudes doctor; always status 0 (placeholder prints nothing)
doctor_update_report() { return 0; }

# -> lines DATADIR<TAB>LAUNCHER for running accounts plus accounts down with a fresh update marker
update_open_accounts() { echo "claudes: update_open_accounts not implemented yet" >&2; return 1; }

# -> status 0 when every open account is idle; prints who is busy otherwise
update_all_idle() { echo "claudes: update_all_idle not implemented yet" >&2; return 1; }

# -> write reopen-pending, record build and log offset, stop every open account together; status 1 if any refuses
update_quit_all() { echo "claudes: update_quit_all not implemented yet" >&2; return 1; }

# -> poll ShipIt up to $CLAUDES_INSTALL_TIMEOUT; status 0 on success, 1 on failure/timeout (prints matching log lines)
update_wait_install() { echo "claudes: update_wait_install not implemented yet" >&2; return 1; }

# -> stop the plain copy ShipIt relaunches when it is not wanted; status 0
update_close_plain_relaunch() { echo "claudes: update_close_plain_relaunch not implemented yet" >&2; return 1; }

# -> reopen every account in reopen-pending and confirm each is running; status 1 if any did not come up
update_reopen_accounts() { echo "claudes: update_reopen_accounts not implemented yet" >&2; return 1; }

# -> reopen accounts that quit for an update but never came back; status 0
update_safety_net() { echo "claudes: update_safety_net not implemented yet" >&2; return 1; }

# -> take $CLAUDES_STATE_DIR/update.lock (pid file inside); status 1 if busy
update_lock() { echo "claudes: update_lock not implemented yet" >&2; return 1; }

# -> release the update lock
update_unlock() { echo "claudes: update_unlock not implemented yet" >&2; return 1; }
