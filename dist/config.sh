# config.sh — signing/notarization settings for mdEdit distribution.
# Sourced by release.sh. Edit values here, not in the scripts.

# Developer ID Application identity (from: security find-identity -v -p codesigning)
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID1234)"
TEAM_ID="TEAMID1234"

# App
APP_NAME="mdEdit"
SCHEME="mdEdit"
BUNDLE_ID="com.lyr3.mdEdit"

# notarytool keychain profile name. Create it once with:
#   xcrun notarytool store-credentials mdedit-notary \
#     --apple-id "you@example.com" --team-id "TEAMID1234"
# (paste an app-specific password from appleid.apple.com when prompted),
# or use --key/--key-id/--issuer for an App Store Connect API key.
NOTARY_PROFILE="mdedit-notary"

# Where the bundled MCP helper lands inside the .app.
HELPER_NAME="mdedit-mcp"
HELPER_DEST_SUBPATH="Contents/Helpers"

# Personal overrides (signing identity, team id) live in config.local.sh —
# untracked, so forks don't inherit anyone's Developer ID.
[ -f "$(dirname "${BASH_SOURCE[0]}")/config.local.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/config.local.sh"
