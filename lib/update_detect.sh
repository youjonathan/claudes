#!/bin/bash
# lib/update_detect.sh — read-only facts about updates and accounts. Source, do not execute.

# -> CFBundleVersion of $CLAUDES_APP_SRC/Contents/Info.plist
installed_build() { echo "claudes: installed_build not implemented yet" >&2; return 1; }

# -> status 0 when launchctl shows the ShipIt job with state = running
shipit_waiting() { echo "claudes: shipit_waiting not implemented yet" >&2; return 1; }

# -> path of staged bundle from updateBundleURL in ShipItState.plist, only if the folder exists
staged_bundle_path() { echo "claudes: staged_bundle_path not implemented yet" >&2; return 1; }

# -> CFBundleVersion of the staged bundle
staged_build() { echo "claudes: staged_build not implemented yet" >&2; return 1; }

# -> one word: none | waiting | no-installer
update_state() { echo "claudes: update_state not implemented yet" >&2; return 1; }

# -> byte size of ShipIt_stderr.log (0 if missing)
shipit_log_size() { echo "claudes: shipit_log_size not implemented yet" >&2; return 1; }

# OFFSET -> ShipIt log text after that byte offset
shipit_log_since() { echo "claudes: shipit_log_since not implemented yet" >&2; return 1; }

# -> status 0 and prints the plist path when disableAutoUpdates is true in managed prefs
auto_updates_blocked() { echo "claudes: auto_updates_blocked not implemented yet" >&2; return 1; }

# -> lines DATADIR<TAB>LAUNCHER (LAUNCHER may be empty), one per DATADIR
known_accounts() { echo "claudes: known_accounts not implemented yet" >&2; return 1; }

# DATADIR -> launcher path, or nothing
launcher_for() { echo "claudes: launcher_for not implemented yet" >&2; return 1; }

# DATADIR -> status 0 when stealth-relaunch exists with userQuit and navOnly not true
marker_says_update_quit() { echo "claudes: marker_says_update_quit not implemented yet" >&2; return 1; }

# DATADIR -> seconds since the stealth-relaunch ts
marker_age() { echo "claudes: marker_age not implemented yet" >&2; return 1; }

# DATADIR -> status 0 when idle; prints a short reason on stdout when busy; not running -> idle
account_idle() { echo "claudes: account_idle not implemented yet" >&2; return 1; }

# -> status 0 when this process has a Claude main process as an ancestor
inside_claude_copy() { echo "claudes: inside_claude_copy not implemented yet" >&2; return 1; }
