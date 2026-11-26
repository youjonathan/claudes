#!/usr/bin/env bats
# Tests for lib/install.sh — fake app folders in a temp dir, every outside command a stub.

mkapp() { # DIR VERSION -> fake Claude.app with a version, a ShipIt file
  mkdir -p "$1/Contents/Frameworks/Squirrel.framework/Resources"
  plutil -create xml1 "$1/Contents/Info.plist"
  plutil -insert CFBundleVersion -string "$2" "$1/Contents/Info.plist"
  echo "shipit" > "$1/Contents/Frameworks/Squirrel.framework/Resources/ShipIt"
  echo "$2" > "$1/Contents/marker"
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home" "$T/app" "$T/shipit" "$T/state" "$T/new"
  export HOME="$T/home"
  export CLAUDES_APP_SRC="$T/app/Claude.app"
  export CLAUDES_SHIPIT_DIR="$T/shipit"
  export CLAUDES_STATE_DIR="$T/state"
  export CLAUDES_INSTALL_TIMEOUT=2
  export CLAUDES_INSTALL_POLL=0.1
  export T
  export PATH="$T/bin:$PATH"
  mkapp "$CLAUDES_APP_SRC" 100
  mkapp "$T/new/Claude.app" 200
  # codesign: TeamIdentifier from a file named after the path (default Q6L2SF6YDW)
  cat > "$T/bin/codesign" <<'SH'
#!/bin/bash
p="${!#}"
if [ -f "$T/codesign_fail" ]; then exit 1; fi
case "$p" in *ShipIt) t="$(cat "$T/shipit_team" 2>/dev/null || echo Q6L2SF6YDW)";; *) t=Q6L2SF6YDW;; esac
echo "TeamIdentifier=$t" >&2
SH
  # ditto: plain copy, or failure on demand
  cat > "$T/bin/ditto" <<'SH'
#!/bin/bash
if [ -f "$T/ditto_fail" ]; then exit 1; fi
mkdir -p "$2" && cp -R "$1/." "$2/"
SH
  # launchctl: print succeeds only when asked; submit runs a scripted "ShipIt"; everything is logged
  cat > "$T/bin/launchctl" <<'SH'
#!/bin/bash
echo "$*" >> "$T/launchctl.log"
case "$1" in
  print) [ -f "$T/job_exists" ];;
  submit) cp "${!#}" "$T/submitted_state" 2>/dev/null || true   # what ShipIt would have read
          [ -f "$T/submit_fail" ] && exit 1; [ -f "$T/shipit_script" ] && bash "$T/shipit_script"; exit 0;;
  remove) exit 0;;
esac
SH
  chmod +x "$T/bin/"*
  source "$REPO/lib/common.sh"
  source "$REPO/lib/update_detect.sh"
  source "$REPO/lib/release.sh"
  source "$REPO/lib/install.sh"
  # the real check needs codesign/spctl on a real app; here it passes unless told to fail
  release_verify_app() { echo "verify $1 $2" >> "$T/verify.log"; [ ! -f "$T/verify_fail" ] || { echo "the downloaded Claude app's signature is damaged or incomplete"; return 1; }; }
  set -euo pipefail
}

# a fake ShipIt run: appends log lines, optionally swaps in the new app
shipit_does() { # LOGLINE [swap]
  {
    echo "echo '$1' >> \"\$CLAUDES_SHIPIT_DIR/ShipIt_stderr.log\""
    if [ "${2:-}" = swap ]; then
      echo "rm -rf \"\$CLAUDES_APP_SRC\"; cp -R \"$T/new/Claude.app\" \"\$CLAUDES_APP_SRC\""
    fi
  } > "$T/shipit_script"
}

@test "install_backup_old copies the app and replaces an older backup" {
  mkdir -p "$T/state/previous/Claude.app"; echo old > "$T/state/previous/Claude.app/stale"
  run install_backup_old
  [ "$status" -eq 0 ]
  [ "$(cat "$T/state/previous/Claude.app/Contents/marker")" = 100 ]
  [ ! -e "$T/state/previous/Claude.app/stale" ]
}

@test "install_backup_old fails when ditto fails" {
  touch "$T/ditto_fail"
  run install_backup_old
  [ "$status" -eq 1 ]
  [[ "$output" == *"nothing was installed"* ]]
}

@test "install_new checks the download again right before installing, with the announced version" {
  shipit_does "Installation completed successfully" swap
  run install_new "$T/new/Claude.app" 200
  [ "$status" -eq 0 ]
  [ "$(cat "$T/verify.log")" = "verify $T/new/Claude.app 200" ]
}

@test "install_new: a download that fails the second check installs nothing and records the failure" {
  touch "$T/verify_fail"
  mkdir -p "$T/state/download/200"
  printf 'version\t200\n' > "$T/state/ready"
  run install_new "$T/new/Claude.app" 200
  [ "$status" -eq 3 ]
  [[ "$output" == *"failed its check just before installing"* ]]
  [ "$(installed_build)" = 100 ]
  [ -d "$T/new/Claude.app" ]
  [ ! -f "$T/launchctl.log" ]
  [ ! -e "$T/state/previous-moved" ]
  [ "$(awk -F'\t' '$1=="version"{print $2}' "$T/state/release-failed")" = 200 ]
  grep -q '^reason' "$T/state/release-failed"
  [ ! -e "$T/state/ready" ]
}

@test "install_shipit_path finds ShipIt when the team matches" {
  run install_shipit_path
  [ "$status" -eq 0 ]
  [ "$output" = "$CLAUDES_APP_SRC/Contents/Frameworks/Squirrel.framework/Resources/ShipIt" ]
}

@test "install_shipit_path fails for the wrong team" {
  echo WRONGTEAM > "$T/shipit_team"
  run install_shipit_path
  [ "$status" -eq 1 ]
}

@test "install_shipit_path fails when ShipIt is missing" {
  rm "$CLAUDES_APP_SRC/Contents/Frameworks/Squirrel.framework/Resources/ShipIt"
  run install_shipit_path
  [ "$status" -eq 1 ]
}

@test "install_shipit_path fails when ShipIt has no team at all" {
  touch "$T/codesign_fail"
  run install_shipit_path
  [ "$status" -eq 1 ]
}

@test "install_via_shipit writes the state plist with encoded URLs" {
  mkdir -p "$T/sp ace/new"
  mkapp "$T/sp ace/new/Claude.app" 200
  shipit_does "Installation completed successfully" swap
  run install_via_shipit "$T/sp ace/new/Claude.app"
  [ "$status" -eq 0 ]
  p="$T/submitted_state"
  [ "$(plutil -extract bundleIdentifier raw -o - "$p")" = com.anthropic.claudefordesktop ]
  [ "$(plutil -extract launchAfterInstallation raw -o - "$p")" = false ]
  [ "$(plutil -extract useUpdateBundleName raw -o - "$p")" = true ]
  [ "$(plutil -extract targetBundleURL raw -o - "$p")" = "file://$CLAUDES_APP_SRC/" ]
  [ "$(plutil -extract updateBundleURL raw -o - "$p")" = "file://${T}/sp%20ace/new/Claude.app/" ]
}

@test "install_via_shipit writes the state file as JSON, the format ShipIt reads" {
  shipit_does "Installation completed successfully" swap
  run install_via_shipit "$T/new/Claude.app"
  [ "$status" -eq 0 ]
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["bundleIdentifier"] == "com.anthropic.claudefordesktop"
assert d["launchAfterInstallation"] is False and d["useUpdateBundleName"] is True
assert d["targetBundleURL"].startswith("file://") and d["updateBundleURL"].startswith("file://")
' "$T/submitted_state"
}

@test "install_via_shipit removes its state file after success, failure, timeout and a failed submit" {
  shipit_does "Installation completed successfully" swap
  run install_via_shipit "$T/new/Claude.app"
  [ "$status" -eq 0 ]
  [ ! -e "$T/shipit/ShipItState.plist" ]
  mkapp "$CLAUDES_APP_SRC" 100
  shipit_does "Installation error: x"
  run install_via_shipit "$T/new/Claude.app"
  [ "$status" -eq 1 ]
  [ ! -e "$T/shipit/ShipItState.plist" ]
  : > "$T/shipit_script"
  run install_via_shipit "$T/new/Claude.app"
  [ "$status" -eq 1 ]
  [ ! -e "$T/shipit/ShipItState.plist" ]
  touch "$T/submit_fail"
  run install_via_shipit "$T/new/Claude.app"
  [ "$status" -eq 1 ]
  [ ! -e "$T/shipit/ShipItState.plist" ]
}

@test "install_via_shipit submits the job with the right arguments" {
  shipit_does "Installation completed successfully" swap
  run install_via_shipit "$T/new/Claude.app"
  [ "$status" -eq 0 ]
  grep -qF -- "submit -l com.anthropic.claudefordesktop.ShipIt -e $T/shipit/ShipIt_stderr.log -- $CLAUDES_APP_SRC/Contents/Frameworks/Squirrel.framework/Resources/ShipIt com.anthropic.claudefordesktop.ShipIt $T/shipit/ShipItState.plist" "$T/launchctl.log"
}

@test "install_via_shipit refuses when a ShipIt job already exists" {
  touch "$T/job_exists"
  run install_via_shipit "$T/new/Claude.app"
  [ "$status" -eq 2 ]
  [[ "$output" == *"already waiting"* ]]
  ! grep -q submit "$T/launchctl.log"
  [ ! -e "$T/shipit/ShipItState.plist" ]
}

@test "install_via_shipit ignores log lines from before the run" {
  echo "Installation completed successfully" > "$T/shipit/ShipIt_stderr.log"
  echo "Aborting update attempt" >> "$T/shipit/ShipIt_stderr.log"
  : > "$T/shipit_script"
  run install_via_shipit "$T/new/Claude.app"
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not finish within 2 seconds"* ]]
}

@test "install_via_shipit: success line without the new version is not success" {
  shipit_does "Installation completed successfully"
  run install_via_shipit "$T/new/Claude.app"
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not finish within"* ]]
}

@test "install_via_shipit fails on each failure line and prints it" {
  for line in "Aborting update attempt" "Installation cancelled" "Installation error: x" "Too many attempts" "refusing to downgrade"; do
    shipit_does "$line"
    run install_via_shipit "$T/new/Claude.app"
    [ "$status" -eq 1 ]
    [[ "$output" == *"$line"* ]]
  done
}

@test "install_via_shipit times out" {
  : > "$T/shipit_script"
  run install_via_shipit "$T/new/Claude.app"
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not finish within 2 seconds"* ]]
}

@test "install_via_shipit always removes the job" {
  shipit_does "Installation completed successfully" swap
  install_via_shipit "$T/new/Claude.app"
  [ "$(grep -c '^remove com.anthropic.claudefordesktop.ShipIt$' "$T/launchctl.log")" -eq 1 ]
  : > "$T/launchctl.log"
  shipit_does "Aborting update attempt"
  run install_via_shipit "$T/new/Claude.app"
  grep -q '^remove com.anthropic.claudefordesktop.ShipIt$' "$T/launchctl.log"
  : > "$T/launchctl.log"
  : > "$T/shipit_script"
  run install_via_shipit "$T/new/Claude.app"
  grep -q '^remove com.anthropic.claudefordesktop.ShipIt$' "$T/launchctl.log"
  : > "$T/launchctl.log"
  touch "$T/submit_fail"
  run install_via_shipit "$T/new/Claude.app"
  [ "$status" -eq 1 ]
  grep -q '^remove com.anthropic.claudefordesktop.ShipIt$' "$T/launchctl.log"
}

@test "install_new through ShipIt says which way" {
  shipit_does "Installation completed successfully" swap
  run install_new "$T/new/Claude.app"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installed through Claude's own installer"* ]]
  [ "$(installed_build)" = 200 ]
}

@test "install_new falls to the move when ShipIt is missing" {
  rm "$CLAUDES_APP_SRC/Contents/Frameworks/Squirrel.framework/Resources/ShipIt"
  run install_new "$T/new/Claude.app"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installed by moving"* ]]
  [ "$(installed_build)" = 200 ]
  [ "$(cat "$T/state/previous-moved/Claude.app/Contents/marker")" = 100 ]
}

@test "install_new falls to the move when ShipIt has the wrong team" {
  echo WRONGTEAM > "$T/shipit_team"
  run install_new "$T/new/Claude.app"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installed by moving"* ]]
  ! grep -q submit "$T/launchctl.log"
}

@test "install_new falls to the move when ShipIt fails" {
  shipit_does "Installation error: boom"
  run install_new "$T/new/Claude.app"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installation error: boom"* ]]
  [[ "$output" == *"Installed by moving"* ]]
  [ "$(installed_build)" = 200 ]
}

@test "install_new does not move when Claude's own install is already pending" {
  touch "$T/job_exists"
  run install_new "$T/new/Claude.app"
  [ "$status" -eq 1 ]
  [ "$(installed_build)" = 100 ]
  [ -d "$T/new/Claude.app" ]
}

@test "install_via_move swaps the apps and keeps the old one aside" {
  run install_via_move "$T/new/Claude.app"
  [ "$status" -eq 0 ]
  [ "$(installed_build)" = 200 ]
  [ "$(cat "$T/state/previous-moved/Claude.app/Contents/marker")" = 100 ]
  [ ! -e "$T/new/Claude.app" ]
}

@test "install_via_move blocked: old app untouched, plain message" {
  _install_mv() { return 1; }
  run install_via_move "$T/new/Claude.app"
  [ "$status" -eq 1 ]
  [[ "$output" == *"macOS blocked"* ]]
  [[ "$output" == *"App Management"* ]]
  [[ "$output" == *"Terminal"* ]]
  [[ "$output" == *"claudes update again"* ]]
  [ "$(installed_build)" = 100 ]
  [ -d "$T/new/Claude.app" ]
  [ ! -e "$T/state/previous-moved/Claude.app" ]
}

@test "install_via_move: second move fails, old app restored" {
  _install_mv() { if [ "$1" = "$T/new/Claude.app" ]; then return 1; fi; mv "$1" "$2"; }
  run install_via_move "$T/new/Claude.app"
  [ "$status" -eq 1 ]
  [[ "$output" == *"put back"* ]]
  [ "$(installed_build)" = 100 ]
  [ ! -e "$T/state/previous-moved/Claude.app" ]
  [ -d "$T/new/Claude.app" ]
}

@test "install_via_move: second move fails and restore fails, says where the old app is" {
  _install_mv() { case "$1" in "$T/new/Claude.app") return 1;; "$T/state/previous-moved/Claude.app") return 1;; esac; mv "$1" "$2"; }
  run install_via_move "$T/new/Claude.app"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$T/state/previous-moved/Claude.app"* ]]
  [[ "$output" == *"Finder"* ]]
}

@test "install_rollback from previous-moved" {
  install_via_move "$T/new/Claude.app"
  run install_rollback
  [ "$status" -eq 0 ]
  [ "$(installed_build)" = 100 ]
  [ ! -e "$T/state/previous-moved/Claude.app" ]
  [ ! -e "$T/state/failed-new" ]
}

@test "install_rollback prefers previous-moved over previous" {
  install_backup_old
  install_via_move "$T/new/Claude.app"
  mkapp "$T/state/previous/Claude.app" 50
  run install_rollback
  [ "$status" -eq 0 ]
  [ "$(installed_build)" = 100 ]
}

@test "install_rollback from previous when only the backup exists" {
  install_backup_old
  rm -rf "$CLAUDES_APP_SRC"; cp -R "$T/new/Claude.app" "$CLAUDES_APP_SRC"   # as if ShipIt installed 200
  run install_rollback
  [ "$status" -eq 0 ]
  [ "$(installed_build)" = 100 ]
  [ ! -e "$T/state/previous/Claude.app" ]
}

@test "install_rollback with nothing saved fails plainly" {
  run install_rollback
  [ "$status" -eq 1 ]
  [[ "$output" == *"no saved copy"* ]]
  [ "$(installed_build)" = 100 ]
}

@test "install_rollback blocked: says where the old copy is" {
  install_via_move "$T/new/Claude.app"
  _install_mv() { return 1; }
  run install_rollback
  [ "$status" -eq 1 ]
  [[ "$output" == *"$T/state/previous-moved/Claude.app"* ]]
  [[ "$output" == *"Finder"* ]]
  [ "$(installed_build)" = 200 ]
}

@test "install_rollback: second move fails, new app put back" {
  install_via_move "$T/new/Claude.app"
  _install_mv() { if [ "$1" = "$T/state/previous-moved/Claude.app" ]; then return 1; fi; mv "$1" "$2"; }
  run install_rollback
  [ "$status" -eq 1 ]
  [ "$(installed_build)" = 200 ]
  [ -d "$T/state/previous-moved/Claude.app" ]
}

@test "install_finish removes the saved copies and the used download folder" {
  mkdir -p "$T/state/previous/Claude.app" "$T/state/previous-moved/Claude.app" "$T/state/download/9.9/app/Claude.app" "$T/state/download/8.8"
  printf 'version\t9.9\napp\t%s\n' "$T/state/download/9.9/app/Claude.app" > "$T/state/ready"
  run install_finish
  [ "$status" -eq 0 ]
  [ ! -e "$T/state/previous" ]
  [ ! -e "$T/state/previous-moved" ]
  [ ! -e "$T/state/download/9.9" ]
  [ -d "$T/state/download/8.8" ]
}

@test "install_finish never deletes a download path outside the state folder" {
  mkdir -p "$T/elsewhere/app/Claude.app"
  printf 'app\t%s\n' "$T/elsewhere/app/Claude.app" > "$T/state/ready"
  run install_finish
  [ "$status" -eq 0 ]
  [ -d "$T/elsewhere/app/Claude.app" ]
}

@test "install_finish works with nothing to clean" {
  run install_finish
  [ "$status" -eq 0 ]
}

@test "install_via_shipit has the submitted flag up while it waits and clears it at the end" {
  : > "$T/shipit_script"
  _install_sleep() { echo "$INSTALL_SHIPIT_SUBMITTED" >> "$T/flag.log"; sleep 0.1; }
  install_via_shipit "$T/new/Claude.app" || true
  grep -qx 1 "$T/flag.log"
  [ "$INSTALL_SHIPIT_SUBMITTED" = 0 ]
}

@test "install_shipit_cancel removes the job only when one was submitted" {
  : > "$T/launchctl.log"
  install_shipit_cancel
  [ ! -s "$T/launchctl.log" ]
  INSTALL_SHIPIT_SUBMITTED=1
  install_shipit_cancel
  grep -q '^remove com.anthropic.claudefordesktop.ShipIt$' "$T/launchctl.log"
  [ "$INSTALL_SHIPIT_SUBMITTED" = 0 ]
}

@test "install_via_move: app missing from Applications says so, not 'nothing was changed'" {
  rm -rf "$CLAUDES_APP_SRC"
  run install_via_move "$T/new/Claude.app"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing"* ]]
  [[ "$output" != *"Nothing was changed"* ]]
  [ -d "$T/new/Claude.app" ]
}

@test "install_via_move: the move fails and the app is gone afterwards: no false 'nothing was changed'" {
  _install_mv() { rm -rf "$1"; return 1; }
  run install_via_move "$T/new/Claude.app"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing"* ]]
  [[ "$output" != *"Nothing was changed"* ]]
}

@test "install_rollback clears claudes' own ShipItState.plist" {
  install_backup_old
  rm -rf "$CLAUDES_APP_SRC"; mkapp "$CLAUDES_APP_SRC" 200
  echo x > "$CLAUDES_SHIPIT_DIR/ShipItState.plist"
  run install_rollback
  [ "$status" -eq 0 ]
  [ "$(installed_build)" = 100 ]
  [ ! -e "$CLAUDES_SHIPIT_DIR/ShipItState.plist" ]
}
