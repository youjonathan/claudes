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
  `CLAUDES_STOP_TIMEOUT`, `CLAUDES_INSTALL_TIMEOUT`, `CLAUDES_MAX_WAIT`, `CLAUDES_MARKER_GRACE`,
  `CLAUDES_MARKER_MAX_AGE`, `CLAUDES_PENDING_MAX_AGE` (age limit of `reopen-pending`, 86400)
- `claudes_sleep` wraps `sleep` so tests can replace it and run instantly.
- Wrappers tests replace: `claudes_open` (every `open`), `claudes_now` (`date +%s`, so waits are
  measured with a fake clock), `claudes_notify` (macOS notification), `user_idle_seconds`
  (`HIDIdleTime` through `ioreg`).
- Every suite runs `set -euo pipefail` after sourcing the libs, as `bin/claudes` does, so an
  unset variable or an aborted pipeline fails a test. `tests/update.bats` also runs
  `bin/claudes update --dry-run` as a subprocess against a fake world.
