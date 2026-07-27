#!/usr/bin/env bash
#
# package.sh — produce a distributable AppBox DMG.
#
# Identity-aware by design: it signs and notarizes properly when a Developer ID
# certificate is present, and falls back to the ad-hoc signature when one isn't,
# so the same command works before and after you enroll in the Developer
# Program. Nothing needs changing on the day your certificate arrives.
#
# Usage:
#   ./package.sh                          # build + DMG (signs if it can)
#   ./package.sh --notarize               # also notarize and staple
#   ./package.sh --identity "Developer ID Application: Name (TEAM)"
#   ./package.sh --notary-profile myname  # keychain profile for notarytool
#
# One-time notarization setup (after enrolling):
#   xcrun notarytool store-credentials "appbox-notary" \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="AppBox"
APP="build/$APP_NAME.app"
DIST="dist"
NOTARY_PROFILE="appbox-notary"
IDENTITY=""
DO_NOTARIZE=0

for arg in "$@"; do
  case "$arg" in
    --notarize) DO_NOTARIZE=1 ;;
    --identity=*)       IDENTITY="${arg#*=}" ;;
    --notary-profile=*) NOTARY_PROFILE="${arg#*=}" ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

cyan()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[33mwarning:\033[0m %s\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

VERSION="$(grep -m1 '^VERSION=' build-app.sh | cut -d'"' -f2)"
DMG="$DIST/$APP_NAME-$VERSION.dmg"

# ---- 1. build ----------------------------------------------------------------
cyan "building release app…"
./build-app.sh --release >/dev/null

# ---- 2. sign -----------------------------------------------------------------
# Auto-detect a Developer ID Application certificate unless one was given.
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
fi

if [ -n "$IDENTITY" ]; then
  cyan "signing with: $IDENTITY"
  # Nested code must be signed before the enclosing bundle. --options runtime
  # (the hardened runtime) is mandatory for notarization.
  codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$APP/Contents/Helpers/appbox"
  codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP" 2>&1 | tail -2
else
  warn "no Developer ID Application certificate found — keeping the ad-hoc signature."
  echo "         The app still runs; macOS will warn only if it is transferred"
  echo "         by something that sets the quarantine flag (browser, Mail, AirDrop)."
  echo "         Recipients can clear it with:"
  echo "           xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
  if [ "$DO_NOTARIZE" -eq 1 ]; then
    warn "--notarize ignored: notarization requires a Developer ID certificate."
    DO_NOTARIZE=0
  fi
fi

# ---- 3. build the DMG --------------------------------------------------------
cyan "building $DMG"
rm -rf "$DIST" && mkdir -p "$DIST"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
# Drag-to-install target.
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$DMG"
fi

# ---- 4. notarize -------------------------------------------------------------
if [ "$DO_NOTARIZE" -eq 1 ]; then
  cyan "submitting for notarization (this usually takes a few minutes)…"
  if xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait; then
    cyan "stapling…"
    xcrun stapler staple "$DMG"
    xcrun stapler staple "$APP"
    green "notarized and stapled."
  else
    warn "notarization failed. Check the log with:"
    echo "         xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
    exit 1
  fi
fi

# ---- 5. report ---------------------------------------------------------------
echo
green "packaged $DMG  ($(du -h "$DMG" | cut -f1))"
echo
echo "  Gatekeeper: $(spctl -a -t open --context context:primary-signature "$DMG" 2>&1 | tail -1)"
echo "  Install:    open $DMG, then drag $APP_NAME to Applications"
echo
