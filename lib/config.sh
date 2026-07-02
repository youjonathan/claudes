#!/bin/bash
# lib/config.sh — read/write ~/.config/claudes/instances. Source, do not execute.
CLAUDES_CONFIG="${CLAUDES_CONFIG:-$HOME/.config/claudes/instances}"

config_init() {
  mkdir -p "$(dirname "$CLAUDES_CONFIG")"
  [ -f "$CLAUDES_CONFIG" ] || printf '# suffix\tcolor\tprofile-dir\n' > "$CLAUDES_CONFIG"
}

config_set() { # suffix color profile — upsert (replace existing row for suffix)
  config_init
  local tmp; tmp="$(mktemp)"
  grep -viE "^[[:space:]]*$1[[:space:]]" "$CLAUDES_CONFIG" > "$tmp" || true
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$tmp"
  mv "$tmp" "$CLAUDES_CONFIG"
}

config_remove() { # suffix
  config_init
  local tmp; tmp="$(mktemp)"
  grep -viE "^[[:space:]]*$1[[:space:]]" "$CLAUDES_CONFIG" > "$tmp" || true
  mv "$tmp" "$CLAUDES_CONFIG"
}

config_each() { # callback -> called as: callback suffix color profile
  config_init
  local cb="$1" s c p
  while IFS=$' \t' read -r s c p _; do
    [ -z "$s" ] && continue
    case "$s" in \#*) continue;; esac
    "$cb" "$s" "$c" "$p"
  done < "$CLAUDES_CONFIG"
}

config_list() {
  config_init
  grep -vE '^[[:space:]]*(#|$)' "$CLAUDES_CONFIG" || true
}
