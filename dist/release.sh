#!/usr/bin/env bash
#
# release.sh — build, sign, notarize, and package mdEdit for distribution
#              on lyr3.com. Produces a stapled, notarized DMG in dist/out/.
#
# Local dev signing is untouched: this operates on a fresh Release build and
# re-signs everything with your Developer ID identity + hardened runtime, which
# is what Gatekeeper requires for downloads from the web.
#
# Steps:
#   1. Build Release (deterministic DerivedData path).
#   2. Build the mdedit-mcp bridge and bundle it into the .app.
#   3. Sign inside-out (helper first, then app) with hardened runtime.
#   4. Zip + submit to Apple notary service; wait for the ticket.
#   5. Staple the ticket to the app.
#   6. Build a compressed DMG with an /Applications drop target; staple it.
#
# Usage:  dist/release.sh            (full pipeline)
#         SKIP_NOTARIZE=1 dist/release.sh   (build+sign+dmg only; for testing)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/dist/config.sh"

APP_PROJECT="$ROOT/mdEdit/mdEdit.xcodeproj"
BUILD_DIR="$ROOT/dist/build"
OUT_DIR="$ROOT/dist/out"
DD="$BUILD_DIR/DerivedData"
STAGE_APP="$BUILD_DIR/$APP_NAME.app"

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY" \
  || die "Signing identity not found in keychain: $SIGN_IDENTITY"

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notarytool profile '$NOTARY_PROFILE' not set up. Run:
    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id \"you@example.com\" --team-id \"$TEAM_ID\"
  (or re-run with SKIP_NOTARIZE=1 to test the build/sign/dmg steps only)."
fi

rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR" "$OUT_DIR"

# --- 1. build the app --------------------------------------------------------
log "Building $APP_NAME (Release)…"
xcodebuild -project "$APP_PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DD" -destination 'platform=macOS' \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build >/dev/null
BUILT="$DD/Build/Products/Release/$APP_NAME.app"
[ -d "$BUILT" ] || die "Build product not found at $BUILT"
cp -R "$BUILT" "$STAGE_APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGE_APP/Contents/Info.plist" 2>/dev/null || echo 0.0)"
BUILDNUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$STAGE_APP/Contents/Info.plist" 2>/dev/null || echo 0)"
log "Version $VERSION ($BUILDNUM)"

# --- 2. build + bundle the MCP bridge ---------------------------------------
log "Building $HELPER_NAME bridge (release)…"
( cd "$ROOT/mcp-server" && swift build -c release >/dev/null )
HELPER_SRC="$ROOT/mcp-server/.build/release/$HELPER_NAME"
[ -x "$HELPER_SRC" ] || die "Helper not built at $HELPER_SRC"
HELPER_DIR="$STAGE_APP/$HELPER_DEST_SUBPATH"
mkdir -p "$HELPER_DIR"
cp "$HELPER_SRC" "$HELPER_DIR/$HELPER_NAME"

# --- 3. sign inside-out ------------------------------------------------------
# Nested code (the helper) must be signed before the enclosing app bundle.
log "Signing helper…"
codesign --force --timestamp --options runtime \
  --sign "$SIGN_IDENTITY" "$HELPER_DIR/$HELPER_NAME"

log "Signing app…"
codesign --force --timestamp --options runtime \
  --sign "$SIGN_IDENTITY" "$STAGE_APP"

log "Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$STAGE_APP"

# --- 4. notarize -------------------------------------------------------------
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  log "SKIP_NOTARIZE=1 — skipping notarization + stapling."
else
  ZIP="$BUILD_DIR/$APP_NAME.zip"
  log "Zipping for notarization…"
  ditto -c -k --keepParent "$STAGE_APP" "$ZIP"
  log "Submitting to Apple notary service (this can take a few minutes)…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
    || die "Notarization failed. Inspect with: xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
  log "Stapling ticket…"
  xcrun stapler staple "$STAGE_APP"
fi

# --- 5. build DMG ------------------------------------------------------------
DMG="$OUT_DIR/$APP_NAME-$VERSION.dmg"
log "Building DMG…"
DMG_STAGE="$BUILD_DIR/dmg"
rm -rf "$DMG_STAGE"; mkdir -p "$DMG_STAGE"
cp -R "$STAGE_APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$DMG_STAGE" \
  -ov -format UDZO "$DMG" >/dev/null

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
  # The DMG is a separate artifact and needs its own notarization ticket before
  # it can be stapled — the app's ticket (stapled above) doesn't cover it.
  log "Notarizing DMG…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait \
    || die "DMG notarization failed. Inspect with: xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"
  log "Stapling DMG…"
  xcrun stapler staple "$DMG"
  log "Gatekeeper assessment (app):"
  spctl -a -vvv "$STAGE_APP" 2>&1 | sed 's/^/    /' || true
fi

echo
log "Done."
echo "    App : $STAGE_APP"
echo "    DMG : $DMG"
echo "    Upload the DMG to lyr3.com (serve over HTTPS)."
