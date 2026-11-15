#!/bin/bash
# lib/install.sh — put a verified new Claude.app in place (ShipIt first, moving it ourselves as the fallback), and undo. Source, do not execute.

CLAUDES_APP_SRC="${CLAUDES_APP_SRC:-/Applications/Claude.app}"
CLAUDES_BASE_ID="${CLAUDES_BASE_ID:-com.anthropic.claudefordesktop}"
CLAUDES_SHIPIT_DIR="${CLAUDES_SHIPIT_DIR:-$HOME/Library/Caches/com.anthropic.claudefordesktop.ShipIt}"
CLAUDES_STATE_DIR="${CLAUDES_STATE_DIR:-$HOME/Library/Application Support/claudes}"
CLAUDES_INSTALL_TIMEOUT="${CLAUDES_INSTALL_TIMEOUT:-300}"
CLAUDES_TEAM_ID="${CLAUDES_TEAM_ID:-Q6L2SF6YDW}"
CLAUDES_INSTALL_POLL="${CLAUDES_INSTALL_POLL:-2}"

_INSTALL_PLIST_BUDDY=/usr/libexec/PlistBuddy
_INSTALL_SHIPIT_LABEL="com.anthropic.claudefordesktop.ShipIt"

# SRC DEST -> moves a folder (every move goes through here so tests can make one fail)
_install_mv() { mv "$1" "$2" 2>/dev/null; }

# -> pause between ShipIt log checks
_install_sleep() { sleep "$CLAUDES_INSTALL_POLL"; }

# -> epoch seconds
_install_now() { date +%s; }

# APP -> CFBundleVersion of that app, status 1 when unreadable
_install_app_build() {
  "$_INSTALL_PLIST_BUDDY" -c 'Print :CFBundleVersion' "$1/Contents/Info.plist" 2>/dev/null
}

# APP -> TeamIdentifier of that app (empty when it has none or codesign fails)
_install_team_id() {
  codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1 || true
}

# PATH -> file:// URL with a trailing slash; everything but letters, digits and -._~/ is percent-encoded
_install_file_url() {
  local p="${1%/}" out="" c i LC_ALL=C
  for (( i = 0; i < ${#p}; i++ )); do
    c="${p:i:1}"
    case "$c" in
      [A-Za-z0-9._~/-]) out="$out$c";;
      *) out="$out$(printf '%%%02X' "'$c")";;
    esac
  done
  printf 'file://%s/' "$out"
}

# -> copies the installed app to $CLAUDES_STATE_DIR/previous/Claude.app; status 1 if that fails
install_backup_old() {
  local dest="$CLAUDES_STATE_DIR/previous/Claude.app"
  if [ ! -d "$CLAUDES_APP_SRC" ]; then
    echo "Could not keep a copy of the current Claude: $CLAUDES_APP_SRC is missing."
    return 1
  fi
  rm -rf "$CLAUDES_STATE_DIR/previous"
  mkdir -p "$CLAUDES_STATE_DIR/previous" || { echo "Could not keep a copy of the current Claude: cannot create $CLAUDES_STATE_DIR/previous."; return 1; }
  if ! ditto "$CLAUDES_APP_SRC" "$dest"; then
    rm -rf "$CLAUDES_STATE_DIR/previous"
    echo "Could not keep a copy of the current Claude, so nothing was installed."
    return 1
  fi
}

# -> prints the ShipIt path when Claude's own installer exists and is signed by the same team as the installed app; status 1 otherwise
install_shipit_path() {
  local s="$CLAUDES_APP_SRC/Contents/Frameworks/Squirrel.framework/Resources/ShipIt" want have
  [ -f "$s" ] || return 1
  want="$(_install_team_id "$CLAUDES_APP_SRC")"
  [ -n "$want" ] || want="$CLAUDES_TEAM_ID"
  have="$(_install_team_id "$s")"
  [ -n "$have" ] && [ "$have" = "$want" ] || return 1
  printf '%s\n' "$s"
}

# NEWAPP -> status 0 when Claude's own installer put it in place; 1 when it failed; 2 when it refused to start because Claude's own install is already pending
install_via_shipit() {
  local new="$1" shipit state="$CLAUDES_SHIPIT_DIR/ShipItState.plist" log="$CLAUDES_SHIPIT_DIR/ShipIt_stderr.log"
  local want offset start now text ok=0 reason=""
  if launchctl print "gui/$(id -u)/$_INSTALL_SHIPIT_LABEL" >/dev/null 2>&1; then
    echo "Claude's own installer is already waiting to install an update, so claudes will not start a second one."
    return 2
  fi
  shipit="$(install_shipit_path)" || { echo "Claude's own installer was not found (or is not signed by Anthropic)."; return 1; }
  want="$(_install_app_build "$new")" || { echo "Could not read the version of the new Claude at $new."; return 1; }
  mkdir -p "$CLAUDES_SHIPIT_DIR" || return 1
  rm -f "$state"
  if ! { plutil -create xml1 "$state" \
      && plutil -insert bundleIdentifier -string "$CLAUDES_BASE_ID" "$state" \
      && plutil -insert launchAfterInstallation -bool NO "$state" \
      && plutil -insert targetBundleURL -string "$(_install_file_url "$CLAUDES_APP_SRC")" "$state" \
      && plutil -insert updateBundleURL -string "$(_install_file_url "$new")" "$state" \
      && plutil -insert useUpdateBundleName -bool YES "$state"; } 2>/dev/null; then
    echo "Could not write the installer's instruction file."
    return 1
  fi
  offset="$(shipit_log_size)"
  if ! launchctl submit -l "$_INSTALL_SHIPIT_LABEL" -e "$log" -- "$shipit" "$_INSTALL_SHIPIT_LABEL" "$state" >/dev/null 2>&1; then
    launchctl remove "$_INSTALL_SHIPIT_LABEL" >/dev/null 2>&1 || true
    echo "Could not start Claude's own installer."
    return 1
  fi
  start="$(_install_now)"
  while :; do
    text="$(shipit_log_since "$offset")"
    if printf '%s\n' "$text" | grep -q 'Installation completed successfully' \
       && [ "$(_install_app_build "$CLAUDES_APP_SRC" || true)" = "$want" ]; then
      ok=1; break
    fi
    if printf '%s\n' "$text" | grep -Eq 'Aborting update attempt|Installation cancelled|Installation error|Too many attempts|downgrade'; then
      reason="$(printf '%s\n' "$text" | grep -E 'Aborting update attempt|Installation cancelled|Installation error|Too many attempts|downgrade' | head -n 5)"
      break
    fi
    now="$(_install_now)"
    if [ $(( now - start )) -ge "$CLAUDES_INSTALL_TIMEOUT" ]; then
      reason="Claude's own installer did not finish within $CLAUDES_INSTALL_TIMEOUT seconds."
      break
    fi
    _install_sleep
  done
  # submitted jobs restart themselves, so the job always goes
  launchctl remove "$_INSTALL_SHIPIT_LABEL" >/dev/null 2>&1 || true
  [ "$ok" = 1 ] && return 0
  echo "Claude's own installer did not finish the update:"
  printf '%s\n' "$reason"
  return 1
}

# NEWAPP -> moves the installed app aside and the new one in; status 1 (old app untouched or put back) when macOS or anything else blocks it
install_via_move() {
  local new="$1" aside="$CLAUDES_STATE_DIR/previous-moved/Claude.app"
  if [ ! -d "$new" ]; then
    echo "The new Claude is not where it should be ($new), so it cannot be moved in."
    return 1
  fi
  rm -rf "$CLAUDES_STATE_DIR/previous-moved"
  mkdir -p "$CLAUDES_STATE_DIR/previous-moved" 2>/dev/null || { echo "Could not create the folder $CLAUDES_STATE_DIR/previous-moved."; return 1; }
  if ! _install_mv "$CLAUDES_APP_SRC" "$aside"; then
    echo "macOS blocked claudes from moving the old Claude out of the way. Nothing was changed."
    echo "To allow it: open System Settings > Privacy & Security > App Management, turn on Terminal, then run claudes update again."
    rmdir "$CLAUDES_STATE_DIR/previous-moved" 2>/dev/null || true
    return 1
  fi
  if ! _install_mv "$new" "$CLAUDES_APP_SRC"; then
    echo "The new Claude could not be moved into place, so the old one is being put back."
    if _install_mv "$aside" "$CLAUDES_APP_SRC"; then
      rmdir "$CLAUDES_STATE_DIR/previous-moved" 2>/dev/null || true
    else
      echo "The old Claude could not be put back either. It is safe at $aside - drag it into Applications in Finder."
    fi
    return 1
  fi
  return 0
}

# NEWAPP -> status 0 when the installed Claude is now NEWAPP's version; says which way it was installed
install_new() {
  local new="$1" want rc=0
  want="$(_install_app_build "$new")" || { echo "Could not read the version of the new Claude at $new."; return 1; }
  install_backup_old || return 1
  install_via_shipit "$new" || rc=$?
  if [ "$rc" = 0 ]; then
    echo "Installed through Claude's own installer."
  elif [ "$rc" = 2 ]; then
    return 1
  else
    echo "Trying to move the new Claude into place ourselves instead."
    if install_via_move "$new"; then
      echo "Installed by moving the app into place."
    else
      return 1
    fi
  fi
  [ "$(_install_app_build "$CLAUDES_APP_SRC" || true)" = "$want" ] || {
    echo "The installed Claude is not the new version after all."
    return 1
  }
}

# -> puts the old app back by moving (ShipIt refuses downgrades); status 1 with a plain message when that fails
install_rollback() {
  local src="" bad="$CLAUDES_STATE_DIR/failed-new/Claude.app"
  if [ -d "$CLAUDES_STATE_DIR/previous-moved/Claude.app" ]; then
    src="$CLAUDES_STATE_DIR/previous-moved/Claude.app"
  elif [ -d "$CLAUDES_STATE_DIR/previous/Claude.app" ]; then
    src="$CLAUDES_STATE_DIR/previous/Claude.app"
  else
    echo "There is no saved copy of the old Claude to go back to."
    return 1
  fi
  rm -rf "$CLAUDES_STATE_DIR/failed-new"
  mkdir -p "$CLAUDES_STATE_DIR/failed-new" 2>/dev/null || true
  if [ -d "$CLAUDES_APP_SRC" ] && ! _install_mv "$CLAUDES_APP_SRC" "$bad"; then
    echo "macOS blocked claudes from moving the new Claude out of the way. The old Claude is saved at $src."
    echo "Dragging it into Applications in Finder (replacing the new one) works."
    return 1
  fi
  if ! _install_mv "$src" "$CLAUDES_APP_SRC"; then
    echo "The old Claude could not be moved back. It is saved at $src."
    echo "Dragging it into Applications in Finder works."
    [ -d "$bad" ] && _install_mv "$bad" "$CLAUDES_APP_SRC" || true
    return 1
  fi
  rm -rf "$CLAUDES_STATE_DIR/failed-new"
  echo "Put the old Claude back."
}

# -> deletes the saved old copies and the used download folder; only call after the new app launched
install_finish() {
  local app dir
  app="$(awk -F'\t' '$1 == "app" { print $2 }' "$CLAUDES_STATE_DIR/ready" 2>/dev/null | head -n 1 || true)"
  rm -rf "$CLAUDES_STATE_DIR/previous" "$CLAUDES_STATE_DIR/previous-moved" "$CLAUDES_STATE_DIR/failed-new"
  case "$app" in
    "$CLAUDES_STATE_DIR"/download/*/app/Claude.app)
      dir="${app%/app/Claude.app}"
      rm -rf "$dir";;
  esac
  return 0
}
