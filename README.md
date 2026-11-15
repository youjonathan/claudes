# claudes

Run multiple Claude Desktop accounts side by side on macOS, each with its own colored Dock icon.

![Claude instances in the Dock](docs/screenshot.png)

## Why

If you have a work Claude account and a personal one, macOS only lets you run one Claude Desktop session at a time. `claudes` creates a small launcher for your local Claude Desktop install, each pointed at its own profile directory and given its own color-coded Dock icon, so you can keep, say, a red "work" instance and a blue "personal" instance open side by side and tell them apart at a glance.

## Disclaimer

For Claude accounts you legitimately hold. No Anthropic binaries are redistributed — the tool operates only on your own local install by creating small launcher apps that point at it; Claude.app itself is never copied or modified. It does not share accounts or bypass usage limits.

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
claudes update [--dry-run]               install a waiting Claude update and reopen your accounts
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

Your instances run your real Claude Desktop app, so once Claude has updated itself, every
instance runs the new version on its next launch.

The catch is how Claude's built-in updater installs the update. It waits until every Claude
window from every account is closed. With several accounts open, that can take hours. When it
finally installs, it reopens only a plain Claude, not your accounts.

`claudes update` finishes the job. It:

1. checks that an update is waiting,
2. waits until every open account is idle (see "What counts as idle" below),
3. quits them all together,
4. lets Claude's own installer finish,
5. closes the plain Claude the installer opens, and
6. reopens each account from its own launcher, so every Dock icon is right.

An account that closed itself for the update while others were still busy is reopened at the
end, together with the others, however long the wait was.

`claudes update --dry-run` shows what it would do without quitting anything. Run it from
Terminal, not from inside Claude. It refuses to run there, because quitting Claude would stop it.

To have this happen on its own, run `claudes watch on`. That installs a background helper (a
launchd agent, which is macOS's built-in way to run something on a timer). Every 5 minutes it
checks for a waiting update and does the same as `claudes update`. `claudes watch status` shows
whether it is running, and `claudes watch off` removes it. Its log is
`~/Library/Logs/claudes/update-watcher.log` (cut to its last 2000 lines once it passes 1 MB).
If an account does not come back after a reopen, the helper shows a macOS notification.

The helper also has a safety net. An account that closed itself for an update is reopened once
no update is waiting any more and Claude's installer isn't running. That is what happens after
Claude installed and reopened only a plain Claude, or when the update went away. It only
applies to an account that has stayed closed for 5 minutes (and less than 12 hours). While
an update is still waiting and other accounts are busy, that account stays closed; when the
update installs, it is reopened together with the others.

If you close the Terminal during a run, the run carries on without it and writes its messages to
`~/Library/Logs/claudes/update.log`.

### What counts as idle

An account counts as busy if any of these is true:

- a Claude Code or Cowork session file in its data folder changed in the last 10 minutes
  (`CLAUDES_IDLE_MINUTES`),
- Claude Code used more than 2 seconds of CPU during a 20 second sample
  (`CLAUDES_CPU_IDLE`, `CLAUDES_CPU_SAMPLE`).

The background helper also waits until nobody has touched the keyboard or mouse for 10
minutes (the same `CLAUDES_IDLE_MINUTES`). If it can't read that, it waits. A manual
`claudes update` does not look at keyboard use, since you are typing in Terminal.

Other settings, all environment variables: `CLAUDES_POLL` (seconds between idle re-checks, 60),
`CLAUDES_MAX_WAIT` (how long a manual run waits for busy accounts before giving up, 14400),
`CLAUDES_STOP_TIMEOUT`, `CLAUDES_INSTALL_TIMEOUT`, `CLAUDES_MARKER_GRACE`,
`CLAUDES_MARKER_MAX_AGE` (how old an update-quit marker may be, 43200), `CLAUDES_PENDING_MAX_AGE`
(how old a `reopen-pending` list may be before it is ignored, 86400).

### Where it keeps its notes

`~/Library/Application Support/claudes` (`CLAUDES_STATE_DIR`) holds `reopen-pending`, the list
of accounts closed for an update that still need reopening (an interrupted run picks it up
next time; entries older than 24 hours are ignored), and `update.lock`, which stops two runs
from overlapping.

If your Mac has a management profile that turns Claude's auto-updates off
(`disableAutoUpdates`), the helper can't work. `claudes doctor` tells you.

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
as unsigned and re-scans on every launch, adding a 20-30+ second delay. Either way, your
`Claude.app` is never touched — it keeps its original Anthropic signature, and since every
instance runs your live `Claude.app`, they pick up Claude's auto-updates automatically.

The update helper never modifies Claude.app either. It only quits and reopens your accounts,
and lets Claude's own installer do the install.

## License

MIT — see [LICENSE](LICENSE).
