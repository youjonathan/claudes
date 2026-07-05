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

Nothing to do. Your instances run your real Claude Desktop app, so when Claude updates
itself, every instance runs the new version on next launch.

If you installed instances with an older version of `claudes` (full-copy clones), re-add each
one once to convert it to a launcher — `claudes list` marks them `legacy`:

    claudes add B blue Claude-Acct-Work

## How it works

Each instance is a small launcher app — it does **not** copy or modify Claude. When you run
`claudes add`:

1. **Create a launcher bundle** at `/Applications/Claude <LETTER>.app` (a few hundred KB: an
   `Info.plist`, a launch script, and an icon).
2. **Give it its own identity** — distinct `CFBundleIdentifier` and display name, so macOS
   treats it as a separate app with its own Dock tile and Cmd-Tab entry.
3. **Delegate to your real Claude** — the launch script `exec`s your existing
   `/Applications/Claude.app` with its own `--user-data-dir`, so each instance keeps a
   separate login/session.
4. **Recolor the icon** to the requested hue.

Because your `Claude.app` is never touched, it keeps its original Anthropic signature — there
is no re-signing and nothing disables any macOS security protection. And since every instance
runs your live `Claude.app`, they pick up Claude's auto-updates automatically.

## License

MIT — see [LICENSE](LICENSE).
