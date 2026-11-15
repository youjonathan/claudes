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
2. waits until every open account is idle (no Claude Code session working: no session activity
   for 10 minutes and almost no CPU use by Claude Code),
3. quits them all together,
4. lets Claude's own installer finish,
5. closes the plain Claude the installer opens, and
6. reopens each account from its own launcher, so every Dock icon is right.

`claudes update --dry-run` shows what it would do without quitting anything. Run it from
Terminal, not from inside Claude. It refuses to run there, because quitting Claude would stop it.

To have this happen on its own, run `claudes watch on`. That installs a background helper (a
launchd agent, which is macOS's built-in way to run something on a timer). Every 5 minutes it
checks for a waiting update and does the same as `claudes update`. It also reopens an account
that closed itself for an update while other accounts were still busy. `claudes watch status`
shows whether it is running, and `claudes watch off` removes it.

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
