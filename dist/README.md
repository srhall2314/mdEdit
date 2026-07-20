# Distributing mdEdit

Tooling to ship mdEdit as a free, notarized download on **lyr3.com**. This is
the Developer ID path (outside the Mac App Store), so Gatekeeper lets users open
it without warnings.

## One-time setup

Store notary credentials in the keychain (only needed once per machine):

```sh
xcrun notarytool store-credentials mdedit-notary \
  --apple-id "you@appleid.com" \
  --team-id "YOURTEAMID"
```

When prompted, paste an **app-specific password** created at
[appleid.apple.com](https://appleid.apple.com) → Sign-In & Security → App-Specific
Passwords. (Alternatively use an App Store Connect API key with
`--key/--key-id/--issuer`.)

Put your signing identity and team ID in `dist/config.local.sh` (untracked; it
overrides the placeholders in [config.sh](config.sh)):

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)"
TEAM_ID="YOURTEAMID"
```

## Cut a release

```sh
dist/release.sh
```

Produces `dist/out/mdEdit-<version>.dmg` — signed with hardened runtime,
notarized, and stapled. Upload it to lyr3.com and serve over HTTPS.

To test the build/sign/packaging without hitting Apple's notary service:

```sh
SKIP_NOTARIZE=1 dist/release.sh
```

## What the pipeline does

1. Builds Release (local dev signing is untouched).
2. Builds the `mdedit-mcp` bridge and bundles it at
   `mdEdit.app/Contents/Helpers/mdedit-mcp`.
3. Signs inside-out (helper, then app) with `--options runtime`.
4. Zips → `notarytool submit --wait` → `stapler staple`.
5. Builds a compressed DMG with an `/Applications` drop target; staples it.

## Bumping the version

Set **Marketing Version** (`CFBundleShortVersionString`) and **Current Project
Version** (`CFBundleVersion`) in the Xcode target's build settings before running
`release.sh` — the DMG filename and volume name follow the marketing version.

## End users: enabling the Claude Desktop bridge

The MCP bridge ships *inside* the app bundle. The easiest path is the built-in
setup: in mdEdit, choose **mdEdit ▸ Set Up Claude Desktop…**, then click **Set Up
Automatically**. It writes the entry into Claude Desktop's config (preserving any
other MCP servers, with a backup), using the app's real install path. Restart
Claude Desktop afterward.

The same window offers **Copy Configuration** for anyone who prefers to edit
`~/Library/Application Support/Claude/claude_desktop_config.json` by hand:

```json
{
  "mcpServers": {
    "mdedit": {
      "command": "/Applications/mdEdit.app/Contents/Helpers/mdedit-mcp",
      "env": { "MDEDIT_APP_PATH": "/Applications/mdEdit.app" }
    }
  }
}
```

See [claude_desktop_config.sample.json](claude_desktop_config.sample.json). The
helper is signed and notarized as part of the app, so Gatekeeper allows Claude
Desktop to launch it.

## Ideas for later

- **Sparkle** for in-app auto-updates (with an appcast on lyr3.com).
- A fancier DMG (background image, icon positions) via `create-dmg`.
