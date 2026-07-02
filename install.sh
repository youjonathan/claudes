#!/bin/bash
set -euo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
source "$SELF/lib/common.sh"; preflight

TARGET="/usr/local/bin"; [ -w "$TARGET" ] || TARGET="$HOME/.local/bin"
mkdir -p "$TARGET"
ln -sf "$SELF/bin/claudes" "$TARGET/claudes"
echo "linked: $TARGET/claudes"
case ":$PATH:" in *":$TARGET:"*) ;; *) echo "NOTE: add $TARGET to your PATH";; esac
echo "done — try: claudes doctor"
