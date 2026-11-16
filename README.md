# claudes

Run multiple Claude Desktop accounts side by side on macOS, each with its own colored Dock icon.

![Claude instances in the Dock](docs/screenshot.png)

## Why

If you have a work Claude account and a personal one, macOS only lets you run one Claude Desktop session at a time. `claudes` creates a small launcher for your local Claude Desktop install, each pointed at its own profile directory and given its own color-coded Dock icon, so you can keep, say, a red "work" instance and a blue "personal" instance open side by side and tell them apart at a glance.

## Disclaimer

For Claude accounts you legitimately hold. No Anthropic binaries are redistributed — the tool operates only on your own local install by creating small launcher apps that point at it; the launchers never copy or modify Claude.app, and `claudes update` only installs Anthropic's own verified, signed download. It does not share accounts or bypass usage limits.

## Install

Requirements: macOS, and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/youjonathan/claudes.git
cd claudes
./install.sh
```

`install.sh` symlinks `bin/claudes` onto your `PATH` (`/usr/local/bin` or `~/.local/bin`).

## Usage

```
claudes add <LETTER> <COLOR> [PROFILE]   create/replace a colored instance
claudes list                             show configured instances + status
claudes remove <LETTER> [--purge]        delete instance (keeps profile unless --purge)
claudes rainbow                          create R,O,Y,G,B,I,V instances
claudes doctor                           check environment
claudes update [--dry-run]               download, check and install a new Claude, then reopen your accounts
claudes watch on|off|status              background helper that runs 'update' by itself
```

Examples:

```bash
# Create a red instance called "Claude W" backed by its own profile
claudes add W red Claude-Acct-Work

# See what's configured, and whether each instance is currently running
claudes list

# Remove an instance, keeping its profile data around
claudes remove W

# Spin up seven color-coded instances at once (R, O, Y, G, B, I, V)
claudes rainbow

# Check that required tools and the main Claude.app are present
claudes doctor
```

Colors: `red orange yellow green teal blue indigo violet purple pink`, or a raw hue value `0-255`.

## Updating

Your instances run your real Claude Desktop app, so once Claude is updated, every instance runs
the new version on its next launch.

The catch is Claude's built-in updater. It installs only when every Claude window from every
account is closed, and then it reopens only a plain Claude, not your accounts. With several
accounts open, that is awkward. So `claudes` does the update itself, at a moment when none of
your accounts is in use.

### Turn off Claude's own updater

Install the management profile `docs/block-claude-updates.mobileconfig`. It sets
`disableAutoUpdates` to true for `com.anthropic.claudefordesktop`. Claude reads that setting
only from `/Library/Managed Preferences`, so it has to be installed as a configuration profile
(you need to be an admin):

1. Double-click the file. macOS says a profile was downloaded.
2. Open System Settings > Privacy & Security > Profiles (on some macOS versions, General >
   Device Management), select "Block Claude Desktop auto-updates (claudes)" and click Install.
3. To remove it, select it in the same place and click the minus button.

With the profile on, this is the expected state, and `claudes doctor` and
`claudes update --dry-run` report it. Without it, `claudes update` still works, but Claude's
own updater may close your accounts one at a time by itself when an update arrives, and
`claudes` warns about that.

### What `claudes update` does

`claudes update` checks for a new Claude and installs it itself. It:

1. checks Anthropic's update address for a newer version (at most once an hour,
   `CLAUDES_RELEASE_CHECK_EVERY`),
2. downloads it with `curl` and verifies it: signed by Anthropic's team ID (`Q6L2SF6YDW`), the
   published checksum and size, the exact version, and a macOS `spctl` check,
3. waits until every open account is idle at the same moment (see "What counts as idle"),
   with no time limit,
4. saves a copy of the current Claude, so it can be put back,
5. quits them all together,
6. checks the download again, then installs it by handing it to Claude's own installer
   (ShipIt). If that isn't possible, it moves the app into place itself instead, which needs
   Terminal to have App Management permission (see below),
7. reopens each account from its own launcher, so every Dock icon is right, and
8. checks 20 seconds later (`CLAUDES_FIRST_LAUNCH_WAIT`) that the accounts are still open. If
   the new Claude fails to launch, it puts the old one back and reopens your accounts on it.
   It doesn't try that version again for 6 hours (`CLAUDES_RETRY_FAILED`).

`claudes update --dry-run` shows what it would do without quitting anything. Run `claudes
update` from Terminal, not from inside Claude. It refuses to run inside Claude, because quitting
Claude would stop it.

If a check can't run, the account counts as busy and nothing is quit. For example, the
full-screen check needs the Xcode Command Line Tools (`xcode-select --install`).

To have this happen on its own, run `claudes watch on`. That installs a background helper (a
launchd agent, which is macOS's built-in way to run something on a timer). Every 5 minutes it
runs one update check and does the same as `claudes update`, except that it never waits: if
an account is busy, it tries again later. `claudes watch status` shows whether it is running,
and `claudes watch off` removes it. Its log is `~/Library/Logs/claudes/update-watcher.log`
(cut to its last 2000 lines once it passes 1 MB). If an account does not come back after a
reopen, the helper shows a macOS notification.

If the helper can't use Claude's own installer, replacing the app needs Terminal, because
macOS asks Terminal for permission. The helper shows a notification and leaves that step to a
manual `claudes update`. It then stays quiet for 24 hours (`CLAUDES_TERMINAL_BACKOFF`).

If a verified download has waited 7 days (`CLAUDES_NOTICE_AFTER`) because your accounts are
never all idle at once, the helper shows one notification per version. Run `claudes update` in
Terminal to see what is busy.

If you close the Terminal during a run, the run carries on without it and writes its messages to
`~/Library/Logs/claudes/update.log`. That log also gets a line whenever an idle check could not run
(for example `lsappinfo` failing); like the helper's log it is cut to its last 2000 lines once it passes 1 MB.

### App Management permission

If the app has to be moved into place, macOS may block it. `claudes update` then changes
nothing and tells you to open System Settings > Privacy & Security > App Management, turn on
Terminal, and run `claudes update` again.

### What counts as idle

An account counts as busy if any of these is true:

- its Claude window is in front,
- one of its windows is full screen,
- a Claude Code or Cowork session file in its data folder changed in the last 10 minutes
  (`CLAUDES_IDLE_MINUTES`),
- Claude Code used more than 2 seconds of CPU during a 20 second sample
  (`CLAUDES_CPU_IDLE`, `CLAUDES_CPU_SAMPLE`).

Each account has its own clock: it has to stay idle for 10 minutes in a row
(`CLAUDES_IDLE_MINUTES`) before it counts, and any busy sign restarts that clock.

When every open account looks idle, `claudes` checks again for about 2 minutes
(`CLAUDES_CONFIRM_SECONDS`). All accounts are checked together, a new round every 15 seconds
(`CLAUDES_CONFIRM_EVERY`), and the 2 minutes are real clock time. If anything was used in that time,
nothing is quit, that account's 10-minute clock starts over, and it goes back to waiting.

Other settings, all environment variables: `CLAUDES_POLL` (seconds between idle re-checks, 60),
`CLAUDES_STOP_TIMEOUT` (30), `CLAUDES_INSTALL_TIMEOUT` (300), `CLAUDES_FEED_BASE` (Anthropic's
update address, `https://api.anthropic.com`), `CLAUDES_RELEASE_CHECK_EVERY` (seconds between
update checks, 3600), `CLAUDES_RETRY_FAILED` (seconds before a failed version is tried
again, 21600), `CLAUDES_NOTICE_AFTER` (604800), `CLAUDES_TERMINAL_BACKOFF` (86400),
`CLAUDES_FIRST_LAUNCH_WAIT` (20), `CLAUDES_CONFIRM_SECONDS` (120), `CLAUDES_CONFIRM_EVERY` (15),
`CLAUDES_MARKER_GRACE` (300), `CLAUDES_MARKER_MAX_AGE` (how old an update-quit marker may be,
43200), `CLAUDES_PENDING_MAX_AGE` (how old a `reopen-pending` list may be before it is
ignored, 86400).

### If Claude's own updater is on

Without the block profile, Claude's own updater can close an account for an update while
others are still open. The helper then has a safety net: an account that closed itself for an
update is reopened once no update is waiting any more and Claude's installer isn't running.
It only applies to an account that has stayed closed for 5 minutes (and less than 12 hours).
While an update is still waiting and other accounts are busy, that account stays closed; when
the update installs, it is reopened together with the others.

### Where it keeps its notes

`~/Library/Application Support/claudes` (`CLAUDES_STATE_DIR`) holds:

- `release-check`: the newest version found, and when it was first seen.
- `release-failed`: a version that failed its checks or its first launch, and when.
- `ready` and `download/`: the verified download waiting to be installed.
- `previous/`: the copy of the old Claude, kept until the update succeeds.
- `previous-moved/`: the old app, when the install moved it aside.
- `failed-new/`: the new Claude that failed to launch. It is deleted after a successful roll back, so it only
  stays when the old Claude could not be put back.
- `idle-since`: when each account was first seen idle (the 10-minute clock).
- `bin/claudes-windows`: the small full-screen checker, compiled on first use.
- `reopen-pending`: the list of accounts closed for an update that still need reopening (an
  interrupted run picks it up next time; entries older than 24 hours are ignored).
- `update.lock`: stops two runs from overlapping.

If you installed instances with an older version of `claudes` (full-copy clones), re-add each
one once to convert it to a launcher — `claudes list` marks them `legacy`:

    claudes add B blue Claude-Acct-Work

## How it works

Each instance is a small launcher app — it does **not** copy or modify Claude. When you run
`claudes add`:

1. **Create a launcher bundle** at `/Applications/Claude <LETTER>.app` (a couple hundred KB: an
   `Info.plist`, a tiny compiled launcher binary, and an icon).
2. **Give it its own identity** — distinct `CFBundleIdentifier` and display name, so macOS
   treats it as a separate app with its own Dock tile and Cmd-Tab entry.
3. **Delegate to your real Claude** — the launcher `exec`s your existing
   `/Applications/Claude.app` with its own `--user-data-dir`, so each instance keeps a
   separate login/session.
4. **Recolor the icon** to the requested hue.

The launcher itself is a small, freshly-compiled binary (built from source each time, via
`clang`) with an ad-hoc code signature — this is what gives it a fast, clean launch under
macOS's Gatekeeper checks; earlier versions used a plain shell script here, which macOS treats
as unsigned and re-scans on every launch, adding a 20-30+ second delay. Either way, the
launchers never touch your `Claude.app` — it keeps its original Anthropic signature, and since
every instance runs your live `Claude.app`, they pick up a new version on their next launch.

`claudes update` never modifies the contents of Claude.app. It installs Anthropic's own signed
download, which it has verified, by handing it to Claude's own installer or by moving the whole
app into place (the old one is kept until the update works), then reopens your accounts.

## License

MIT — see [LICENSE](LICENSE).
