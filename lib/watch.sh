#!/bin/bash
# lib/watch.sh — claudes watch. Source, do not execute.
CLAUDES_WATCH_LABEL=io.github.youjonathan.claudes.update-watcher

# on|off|status -> dispatch to watch_on / watch_off / watch_status
cmd_watch() { echo "claudes: cmd_watch not implemented yet" >&2; return 1; }

# -> write the LaunchAgent plist and load it; refuses if auto-updates are blocked
watch_on() { echo "claudes: watch_on not implemented yet" >&2; return 1; }

# -> unload the LaunchAgent and remove its plist
watch_off() { echo "claudes: watch_off not implemented yet" >&2; return 1; }

# -> print installed/loaded state and the last 5 log lines
watch_status() { echo "claudes: watch_status not implemented yet" >&2; return 1; }
