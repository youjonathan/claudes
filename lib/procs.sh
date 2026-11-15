#!/bin/bash
# lib/procs.sh — process matching via ps, exact string comparison only. Source, do not execute.

_procs_ps() { ps -axo pid=,ppid=,command= 2>/dev/null || true; }   # one snapshot: PID PPID COMMAND

# SIG PID... -> signal through the kill found on PATH (the bash builtin cannot be stubbed)
_procs_signal() {
  local sig="$1" p; shift
  for p in "$@"; do env kill "-$sig" "$p" >/dev/null 2>&1 || true; done
}

# -> lines PID<TAB>DATADIR for every main Claude process under $CLAUDES_APP_SRC (no flag -> $CLAUDES_SUPPORT_DIR/Claude)
claude_main_procs() {
  local pid ppid cmd dd bin="$CLAUDES_APP_SRC/Contents/MacOS/Claude"
  while read -r pid ppid cmd; do
    case "$cmd" in
      "$bin"|"$bin "*) ;;
      *) continue;;
    esac
    case "$cmd" in
      *" --user-data-dir="*) dd="${cmd#*" --user-data-dir="}"; dd="${dd%% --*}";;
      *) dd="$CLAUDES_SUPPORT_DIR/Claude";;
    esac
    printf '%s\t%s\n' "$pid" "$dd"
  done < <(_procs_ps)
}

# DATADIR -> main PID for exactly that folder; nothing and status 1 if none
datadir_main_pid() {
  local want="$1" pid dd
  while IFS=$'\t' read -r pid dd; do
    if [ "$dd" = "$want" ]; then echo "$pid"; return 0; fi
  done < <(claude_main_procs)
  return 1
}

# DATADIR -> status 0 if a main process runs with that folder, else 1
datadir_running() { datadir_main_pid "$1" >/dev/null; }

# PID -> PID and all descendants (by ppid), one per line
proc_tree() {
  _procs_ps | awk -v root="$1" '
    { kids[$2] = kids[$2] " " $1 }
    END {
      n = 1; q[1] = root; seen[root] = 1
      for (i = 1; i <= n; i++) {
        print q[i]
        m = split(kids[q[i]], a, " ")
        for (j = 1; j <= m; j++) if (!(a[j] in seen)) { seen[a[j]] = 1; q[++n] = a[j] }
      }
    }'
}

# DATADIR -> pids of chrome_crashpad_handler with --database=DATADIR/Crashpad
crashpad_pids() {
  local want="--database=$1/Crashpad" pid ppid cmd
  while read -r pid ppid cmd; do
    case "$cmd" in *chrome_crashpad_handler*) ;; *) continue;; esac
    case "$cmd" in
      *" $want"|*" $want "*) echo "$pid";;
    esac
  done < <(_procs_ps)
}

# MAINPID -> main pid plus its descendants that live inside $CLAUDES_APP_SRC (never Squirrel/ShipIt)
_procs_owned() {
  local main="$1" tree pid ppid cmd
  tree=" $(proc_tree "$main" | tr '\n' ' ')"
  echo "$main"
  while read -r pid ppid cmd; do
    [ "$pid" = "$main" ] && continue
    case "$tree" in *" $pid "*) ;; *) continue;; esac
    case "$cmd" in *Squirrel.framework*|*ShipIt*) continue;; esac
    case "$cmd" in "$CLAUDES_APP_SRC/"*) echo "$pid";; esac
  done < <(_procs_ps)
}

# RECORDED PID -> the command line recorded for PID (RECORDED = lines PID<TAB>COMMAND); status 1 if PID is not recorded
_procs_recorded_cmd() {
  local p c
  while IFS=$'\t' read -r p c; do
    if [ "$p" = "$2" ]; then printf '%s' "$c"; return 0; fi
  done <<EOF
$1
EOF
  return 1
}

# "PIDS" -> lines PID<TAB>COMMAND for those pids as they are now
_procs_record() {
  local tracked=" $1 " pid ppid cmd
  while read -r pid ppid cmd; do
    case "$tracked" in *" $pid "*) printf '%s\t%s\n' "$pid" "$cmd";; esac
  done < <(_procs_ps)
}

# RECORDED DATADIR -> recorded pids still running with the SAME command line (a reused pid is not ours),
# plus any crashpad handler for DATADIR, one per line
_procs_alive() {
  local rec="$1" dd="$2" pid ppid cmd want
  {
    while read -r pid ppid cmd; do
      want="$(_procs_recorded_cmd "$rec" "$pid")" || continue
      if [ "$want" = "$cmd" ]; then echo "$pid"; fi
    done < <(_procs_ps)
    crashpad_pids "$dd"
  } | sort -un
}

# DATADIR [TIMEOUT] -> SIGTERM then SIGKILL the copy and its Claude-owned tree; 0 when gone, 1 if still alive; never signals ShipIt
stop_datadir() {
  local datadir="$1" timeout="${2:-$CLAUDES_STOP_TIMEOUT}" main tracked rec alive killable p now want i=0
  main="$(datadir_main_pid "$datadir")" || return 0
  tracked="$(_procs_owned "$main" | tr '\n' ' ')"
  rec="$(_procs_record "$tracked")"
  _procs_signal TERM "$main"
  while :; do
    alive="$(_procs_alive "$rec" "$datadir")"
    [ -z "$alive" ] && return 0
    [ "$i" -ge "$timeout" ] && break
    claudes_sleep 1; i=$((i + 1))
  done
  # only kill a pid that still has the command line recorded at the start (pids get reused)
  killable=""
  for p in $alive; do
    if want="$(_procs_recorded_cmd "$rec" "$p")"; then
      now="$(_procs_record "$p" | head -n 1 | cut -f2-)"
      [ "$now" = "$want" ] || continue
    fi
    killable="$killable $p"
  done
  # shellcheck disable=SC2086
  [ -z "$killable" ] || _procs_signal KILL $killable
  i=0
  while [ "$i" -lt 10 ]; do
    claudes_sleep 1; i=$((i + 1))
    alive="$(_procs_alive "$rec" "$datadir")"
    [ -z "$alive" ] && return 0
  done
  return 1
}
