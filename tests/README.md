# Tests

Unit tests for the pure shell helpers. Requires `bats-core` (`brew install bats-core`).

Run: `bats tests/`

## Environment overrides

Tests never touch real Claude processes, `/Applications`, launchd, or your real Library
folders. Every external command (`ps`, `launchctl`, `open`, `sleep`, ...) is reached through
`PATH`, so a test puts a stub script first on `PATH` (the stub records its arguments to a file
the test can read). Every path is an environment variable that a test points at a temp dir:

- Paths: `CLAUDES_APP_SRC`, `CLAUDES_APPS_DIR`, `CLAUDES_SUPPORT_DIR`, `CLAUDES_SHIPIT_DIR`,
  `CLAUDES_MANAGED_PREFS_DIR`, `CLAUDES_LAUNCHAGENTS_DIR`, `CLAUDES_STATE_DIR`, `CLAUDES_LOG_DIR`
- Timing: `CLAUDES_POLL`, `CLAUDES_IDLE_MINUTES`, `CLAUDES_CPU_SAMPLE`, `CLAUDES_CPU_IDLE`,
  `CLAUDES_STOP_TIMEOUT`, `CLAUDES_INSTALL_TIMEOUT`, `CLAUDES_MARKER_GRACE`,
  `CLAUDES_MARKER_MAX_AGE`, `CLAUDES_PENDING_MAX_AGE` (age limit of `reopen-pending`, 86400),
  `CLAUDES_NOTICE_AFTER` (age of a waiting download that triggers the one-time notice, 604800),
  `CLAUDES_TERMINAL_BACKOFF` (how long the watcher stays quiet after asking for Terminal, 86400),
  `CLAUDES_FIRST_LAUNCH_WAIT` (seconds before checking reopened accounts are still up, 20)
- `claudes_sleep` wraps `sleep` so tests can replace it and run instantly.
- Wrappers tests replace: `claudes_open` (every `open`), `claudes_now` (`date +%s`, so waits are
  measured with a fake clock), `claudes_notify` (macOS notification).
- `tests/update.bats` also replaces the functions of the other libs (`release_*`, `install_*`,
  `account_idle_settled`, `idle_rules_report`) with fakes that keep the real state files
  (`ready`, `reopen-pending`) but do no downloading, installing or process work. The end-to-end
  tests run a copy of the repo whose `release.sh` and `install.sh` are test doubles.
- `tests/watch.bats` fakes `auto_updates_blocked` and puts a `launchctl` stub on `PATH`.
- Every suite runs `set -euo pipefail` after sourcing the libs, as `bin/claudes` does, so an
  unset variable or an aborted pipeline fails a test. `tests/update.bats` also runs
  `bin/claudes update --dry-run` as a subprocess against a fake world.
