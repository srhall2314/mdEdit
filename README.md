# mdEdit

A local-first macOS markdown editor whose **open documents are directly readable and
editable by an AI** over a local MCP (Model Context Protocol) transport — no server in
between. Clean, iA Writer-inspired writing surface; fully native (menus, key equivalents,
Liquid Glass on macOS 26).

## Download

**[Get mdEdit at lyr3.com](https://www.lyr3.com/Products/mdedit)** — a signed, notarized
build for macOS 26. No Xcode, no build step. That's the way in for most people.

Everything below is for working with the source (requires macOS 26 and Xcode 26; no
external dependencies).

## Layout

- `mdEdit/` — the macOS app (SwiftUI `DocumentGroup`, Xcode project `mdEdit/mdEdit.xcodeproj`).
- `mcp-server/` — `mdedit-mcp`, the stdio↔Unix-socket bridge Claude Desktop launches (SwiftPM).

## How it fits together

```
Claude Desktop ──stdio JSON-RPC──▶ mdedit-mcp ──Unix socket──▶ mdEdit.app
                                   (no state)                  (source of truth:
                                                                live buffers, revisions,
                                                                file coordination)
```

The app owns everything. The bridge is a thin pipe, so **every tool call passes through
the app and is visible on screen** — no off-screen side effects. Socket path:
`~/Library/Application Support/mdEdit/mcp.sock`.

## Install from source

Run `./install.sh` — it builds the app in **Release**, copies it to `/Applications/mdEdit.app`
(independent of Xcode/DerivedData), builds the `mdedit-mcp` bridge, and prints the Claude
Desktop config snippet. Re-run it whenever you change the code.

## Distribution (lyr3.com)

`dist/release.sh` produces a notarized, stapled DMG for public download — Developer ID
signed with hardened runtime, `mdedit-mcp` bundled inside the app. See
[dist/README.md](dist/README.md) for the one-time notary-credential setup and the
end-user Claude Desktop config.

## Build

**App** (Xcode, or CLI):

```sh
cd mdEdit
xcodebuild -project mdEdit.xcodeproj -scheme mdEdit -configuration Release build
# then copy the built mdEdit.app to /Applications (recommended for a stable path)
```

> The MCP server runs only in the real `@main` app — **not** in Xcode Previews. If you
> launch from Xcode, use Run (⌘R), not a preview canvas. When driving the socket from a
> script, launch the binary directly (`mdEdit.app/Contents/MacOS/mdEdit`).

**Bridge**:

```sh
cd mcp-server
swift build -c release          # -> .build/release/mdedit-mcp
```

## Connect to Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (see
`claude_desktop_config.sample.json`), pointing at your built binary and app:

```json
{
  "mcpServers": {
    "mdedit": {
      "command": "/absolute/path/to/mdEdit/mcp-server/.build/release/mdedit-mcp",
      "env": { "MDEDIT_APP_PATH": "/Applications/mdEdit.app" }
    }
  }
}
```

`MDEDIT_APP_PATH` lets the bridge launch the app if it isn't already running; if omitted it
falls back to launching by bundle id `com.lyr3.mdEdit` (requires the app to be registered
with Launch Services, i.e. run at least once).

## Tools

| Tool | Purpose |
|---|---|
| `list_open_files()` | Paths of files currently live in app windows |
| `open_file(path)` | Promote an existing file disk→live; opens/focuses its window (does not create files) |
| `read_file(path)` | Open files return `{content, revision}`; others are read from disk |
| `edit_file(path, edit, base_revision)` | Range replace `[start,end)`→`text` (UTF-16). Requires `base_revision` |
| `get_selection(path)` | Current cursor/selection for an open file |

**Promotion rule.** `edit_file` on a file that isn't open returns `{"error":"not_open"}` —
the AI should `open_file` then retry, and that sequence is visible in the tool trace.

**Stale-write detection.** Each open doc has a monotonic `revision` (not a timestamp).
If the human typed since the AI's last read, `edit_file` is rejected with
`{"error":"stale","current_revision":N,"current_content":"..."}` so the AI can reconcile
without another round trip.

## Editing & viewing

- **Preview** (⇧⌘P) renders markdown natively — sized headings, indented lists, boxed code,
  quotes, tables, images, and inline styling — via the app's own renderer over Apple's
  markdown parser (no external dependencies).
- **Insert menu** — bold (⌘B), italic (⌘I), inline code (⇧⌘C), link (⌘K), image (⇧⌘K),
  heading 1–6 (⌃⌘1–6), lists, block quote, code block, table, horizontal rule. Each wraps
  the selection or prefixes the current lines, and is undoable.
- **Help ▸ mdEdit Markdown Syntax** (⌘?) opens a live cheat sheet (syntax beside its
  rendered result).
- AI edits **flush to disk immediately**; human typing autosaves on a short delay.

## Design notes

- App Sandbox is **off** — mdEdit is a personal tool that opens arbitrary AI-named paths
  and rendezvous with an externally-launched subprocess over a socket. Not App Store bound.
- Writing surface is a calm solid canvas; Liquid Glass is used only for chrome and the
  word-count pill, per HIG.
- Typography (font family/size/line spacing) and appearance are in Settings (⌘,).

## Markdown as a document type

The app declares and claims the markdown UTI (`net.daringfireball.markdown`, via
`Info.plist`), so it opens `.md`/`.markdown`/`.mdown`/`.markdn`, and **new documents save
as `.md`** by default. mdEdit registers as a candidate editor for markdown.

To make it your **default** `.md` app (optional — the OS keeps TextEdit until you choose):
Finder ▸ select a `.md` file ▸ Get Info ▸ *Open with* ▸ mdEdit ▸ **Change All…**. Putting
`mdEdit.app` in `/Applications` first is recommended so the association is stable.

## Not yet done

- "Push to Kyle" promotion action.
- Focus mode / typewriter-scrolling refinements.

## License

MIT — see [LICENSE](LICENSE). Fork it, build it, make it yours.
