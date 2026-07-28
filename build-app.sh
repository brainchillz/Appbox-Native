#!/usr/bin/env bash
#
# build-app.sh — build AppBox.app from the Swift package.
#
# SPM cannot emit a .app bundle, so we build the executables and assemble the
# bundle here. This keeps the whole project buildable from the command line with
# no .xcodeproj to hand-maintain.
#
# The `appbox` CLI is bundled inside the app at Contents/Helpers/appbox so a
# single download provides both the GUI and the command line tool — the app can
# then offer to symlink it onto PATH rather than making the user install twice.
#
# Usage:
#   ./build-app.sh              # release build -> build/AppBox.app
#   ./build-app.sh --debug      # faster build, for iterating
#   ./build-app.sh --run        # build, then launch it

set -euo pipefail

cd "$(dirname "$0")"

CONFIG=release
RUN=0
for arg in "$@"; do
  case "$arg" in
    --debug)   CONFIG=debug ;;
    --release) CONFIG=release ;;
    --run)     RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

APP_NAME="AppBox"
BUNDLE_ID="net.onthenile.appbox"
VERSION="0.2.0"
OUT="build/$APP_NAME.app"

cyan() { printf '\033[36m==>\033[0m %s\n' "$*"; }

cyan "building ($CONFIG)…"
swift build -c "$CONFIG" --product AppBoxApp
swift build -c "$CONFIG" --product appbox

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

cyan "assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$OUT/Contents/Helpers"

cp "$BIN_DIR/AppBoxApp" "$OUT/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/appbox"    "$OUT/Contents/Helpers/appbox"

# The icon is generated from Tools/make-icon.swift rather than committed as a
# binary blob. Build it on demand if it's missing.
if [ ! -f Resources/AppIcon.icns ]; then
  cyan "generating app icon…"
  mkdir -p Resources
  swift Tools/make-icon.swift
fi
cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

# LSUIElement=1 makes this a menu bar app with no Dock icon.
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>    <string>15.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSHumanReadableCopyright</key>  <string>appbox</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough to run locally; distributing to another Mac needs a
# Developer ID identity and notarization instead.
cyan "signing (ad-hoc)…"
codesign --force --deep --sign - "$OUT" 2>/dev/null

cyan "built $OUT"
echo
echo "  Launch it:   open $OUT"
echo "  Install it:  cp -R $OUT /Applications/"
echo "  Bundled CLI: $OUT/Contents/Helpers/appbox"
echo

if [ "$RUN" -eq 1 ]; then
  # Replace any previously running copy so you always test the new build.
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  cyan "launching…"
  open "$OUT"
fi
