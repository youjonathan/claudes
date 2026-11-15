#!/bin/bash
# lib/procs.sh — process matching via ps (never pgrep/pkill -f patterns). Source, do not execute.

# -> lines PID<TAB>DATADIR for every main Claude process under $CLAUDES_APP_SRC (no flag -> $CLAUDES_SUPPORT_DIR/Claude)
claude_main_procs() { echo "claudes: claude_main_procs not implemented yet" >&2; return 1; }

# DATADIR -> main PID for exactly that folder; nothing and status 1 if none
datadir_main_pid() { echo "claudes: datadir_main_pid not implemented yet" >&2; return 1; }

# DATADIR -> status 0 if a main process runs with that folder, else 1 (temporary exact-match body)
datadir_running() {
  local line needle="--user-data-dir=$1" found=1
  while IFS= read -r line; do
    case "$line" in
      *"$needle "*|*"$needle") found=0; break;;
    esac
  done < <(ps -axo command= 2>/dev/null)
  return $found
}

# PID -> PID and all descendants (by ppid), one per line
proc_tree() { echo "claudes: proc_tree not implemented yet" >&2; return 1; }

# DATADIR -> pids of chrome_crashpad_handler with --database=DATADIR/Crashpad
crashpad_pids() { echo "claudes: crashpad_pids not implemented yet" >&2; return 1; }

# DATADIR [TIMEOUT] -> SIGTERM then SIGKILL the copy and its Claude-owned tree; 0 when gone, 1 if still alive; never signals ShipIt
stop_datadir() { echo "claudes: stop_datadir not implemented yet" >&2; return 1; }
