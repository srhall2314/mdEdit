#!/usr/bin/env bash
#
# install.sh — build a personal Release build of mdEdit and install it.
#
# Builds the app (Release, optimized, no debugger/preview dylibs), copies it to
# /Applications so it lives independently of Xcode, and builds the mdedit-mcp
# stdio bridge. Re-run this any time you change the code.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PROJECT="$ROOT/mdEdit/mdEdit.xcodeproj"

echo "==> Building mdEdit (Release)…"
xcodebuild -project "$APP_PROJECT" -scheme mdEdit -configuration Release \
  -destination 'platform=macOS' build >/dev/null

REL="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/mdEdit-*/Build/Products/Release/mdEdit.app | head -1)"

DEST="/Applications/mdEdit.app"
if ! ( rm -rf "$DEST" 2>/dev/null && cp -R "$REL" "$DEST" 2>/dev/null ); then
  DEST="$HOME/Applications/mdEdit.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$REL" "$DEST"
  echo "    (no write access to /Applications — installed to ~/Applications instead)"
fi

# Register with Launch Services so double-click / bundle-id launch work.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"

echo "==> Building mdedit-mcp bridge (release)…"
( cd "$ROOT/mcp-server" && swift build -c release >/dev/null )
BRIDGE="$ROOT/mcp-server/.build/release/mdedit-mcp"

echo
echo "Installed app : $DEST"
echo "MCP bridge    : $BRIDGE"
echo
echo "Claude Desktop config — ~/Library/Application Support/Claude/claude_desktop_config.json:"
cat <<EOF
  "mcpServers": {
    "mdedit": {
      "command": "$BRIDGE",
      "env": { "MDEDIT_APP_PATH": "$DEST" }
    }
  }
EOF
echo
echo "Done. (Restart Claude Desktop to pick up config changes.)"
