#!/bin/bash
# make-claude-instance.sh <SUFFIX> [COLOR] [DATADIR_NAME]
#
# Creates "/Applications/Claude <SUFFIX>.app": a separate, isolated Claude Desktop
# instance that shows up as its own colored Dock icon you can pin.
#
#   SUFFIX        e.g. B, C            -> app name + bundle-id suffix
#   COLOR         default blue         -> icon color: red orange yellow green teal
#                                         blue purple pink, or a raw hue 0-255
#   DATADIR_NAME  default Claude-Acct-<SUFFIX>  -> profile dir under ~/Library/Application Support
#
# Re-run after a Claude auto-update to regenerate the instance (updates replace
# /Applications/Claude.app and stale this copy).
#
# WHY this exact recipe (learned the hard way):
#  * Claude is an Electron app with ElectronAsarIntegrity -> changing CFBundleName
#    makes it abort at launch (SIGTRAP). Changing CFBundleIdentifier is fine, and
#    CFBundleDisplayName gives a custom label without tripping integrity.
#  * Ad-hoc re-sign strips Anthropic's team-bound entitlements; we re-apply a
#    minimal hardened-runtime set and disable library validation, signing
#    inside-out (dylibs -> frameworks -> helpers -> real binary -> app).
set -euo pipefail

SUFFIX="${1:?usage: make-claude-instance.sh <SUFFIX e.g. B> [COLOR] [DATADIR_NAME]}"
COLOR="${2:-blue}"
DATADIR="$HOME/Library/Application Support/${3:-Claude-Acct-${SUFFIX}}"

# color name -> absolute hue (PIL HSV scale 0-255)
case "$(echo "$COLOR" | tr '[:upper:]' '[:lower:]')" in
  red) HUE=0;; orange) HUE=18;; yellow) HUE=38;; green) HUE=90;;
  teal|cyan) HUE=125;; blue) HUE=160;; purple|violet) HUE=190;; pink|magenta) HUE=220;;
  *[!0-9]*|'') echo "ERROR: unknown color '$COLOR' (try: red orange yellow green teal blue purple pink, or 0-255)"; exit 1;;
  *) HUE="$COLOR";;
esac

SRC="/Applications/Claude.app"
DST="/Applications/Claude ${SUFFIX}.app"
BUNDLE_ID="com.anthropic.claudefordesktop.$(echo "$SUFFIX" | tr '[:upper:]' '[:lower:]')"
PB=/usr/libexec/PlistBuddy
[ -d "$SRC" ] || { echo "ERROR: $SRC not found"; exit 1; }

ENT="$(mktemp -t claude-ent).plist"
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
</dict></plist>
PLIST

echo ">> fresh copy -> $DST"
pkill -f "Claude ${SUFFIX}.app" 2>/dev/null || true
rm -rf "$DST"; cp -R "$SRC" "$DST"
PLIST="$DST/Contents/Info.plist"

echo ">> identity: id=$BUNDLE_ID, DisplayName='Claude $SUFFIX' (CFBundleName left as 'Claude')"
$PB -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
$PB -c "Add :CFBundleDisplayName string Claude ${SUFFIX}" "$PLIST" 2>/dev/null \
  || $PB -c "Set :CFBundleDisplayName Claude ${SUFFIX}" "$PLIST"
# drop CFBundleIconName so the bundle uses our recolored electron.icns instead of Assets.car
$PB -c "Delete :CFBundleIconName" "$PLIST" 2>/dev/null || true

echo ">> shim executable -> --user-data-dir=$DATADIR"
MACOS="$DST/Contents/MacOS"
mv "$MACOS/Claude" "$MACOS/Claude-bin"
printf '#!/bin/bash\nexec "$(dirname "$0")/Claude-bin" --user-data-dir="%s" "$@"\n' "$DATADIR" > "$MACOS/Claude"
chmod +x "$MACOS/Claude"
mkdir -p "$DATADIR"

echo ">> colorize icon -> $COLOR (hue $HUE)"
ICONSET="$(mktemp -d)/icon.iconset"; mkdir -p "$ICONSET"
python3 - "$SRC/Contents/Resources/electron.icns" "$ICONSET" "$HUE" <<'PY'
import sys, os
from PIL import Image
img = Image.open(sys.argv[1]).convert("RGBA"); r, g, b, a = img.split()
h, s, v = Image.merge("RGB", (r, g, b)).convert("HSV").split()
h = h.point(lambda x: int(sys.argv[3]) % 256)  # set absolute target hue
r2, g2, b2 = Image.merge("HSV", (h, s, v)).convert("RGB").split()
t = Image.merge("RGBA", (r2, g2, b2, a))
for n, px in {"icon_16x16.png":16,"icon_16x16@2x.png":32,"icon_32x32.png":32,"icon_32x32@2x.png":64,
              "icon_128x128.png":128,"icon_128x128@2x.png":256,"icon_256x256.png":256,
              "icon_256x256@2x.png":512,"icon_512x512.png":512,"icon_512x512@2x.png":1024}.items():
    t.resize((px, px), Image.LANCZOS).save(os.path.join(sys.argv[2], n))
PY
iconutil -c icns "$ICONSET" -o "$DST/Contents/Resources/electron.icns"

echo ">> inside-out ad-hoc re-sign"
EF="$DST/Contents/Frameworks/Electron Framework.framework"
for d in "$EF/Versions/A/Libraries/"*.dylib; do codesign --force --sign - "$d"; done
codesign --force --sign - "$EF/Versions/A/Electron Framework"
codesign --force --sign - "$EF"
for fw in "$DST/Contents/Frameworks/"*.framework; do
  [ "$fw" = "$EF" ] && continue; codesign --force --sign - "$fw"
done
for h in "$DST/Contents/Frameworks/"*.app; do
  codesign --force --options runtime --entitlements "$ENT" --sign - "$h/Contents/MacOS/"*
  codesign --force --options runtime --entitlements "$ENT" --sign - "$h"
done
codesign --force --options runtime --entitlements "$ENT" --sign - "$MACOS/Claude-bin"   # real binary entitled
codesign --force --sign - "$MACOS/Claude"                                               # shim
codesign --force --sign - "$DST"

echo ">> set Finder custom icon (Assets.car + CFBundleIconName override electron.icns, so this is required)"
SETICON="$(mktemp -t seticon).swift"
cat > "$SETICON" <<'SW'
import AppKit
let a = CommandLine.arguments
guard a.count >= 3, let img = NSImage(contentsOfFile: a[1]) else { exit(1) }
_ = NSWorkspace.shared.setIcon(img, forFile: a[2], options: [])
SW
swift "$SETICON" "$DST/Contents/Resources/electron.icns" "$DST" 2>/dev/null || true
rm -f "$SETICON"

echo ">> refresh icon caches (else the Dock shows stale tiles)"
rm -rf "$HOME/Library/Caches/com.apple.iconservices.store" 2>/dev/null || true
touch "$DST"
killall Dock 2>/dev/null || true

echo "DONE: $DST"
echo "  profile : $DATADIR"
echo "  verify  : $(codesign --verify --verbose=1 "$DST" 2>&1 | tail -1)"
echo "  NOTE: if the tile is still stale, fully quit + relaunch the app once."
