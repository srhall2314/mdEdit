//
//  ClaudeDesktopSetup.swift
//  mdEdit
//
//  "Set Up Claude Desktop" — writes (or copies) the MCP server entry Claude
//  Desktop needs in order to launch the bundled `mdedit-mcp` bridge. Paths are
//  resolved from the running app bundle, so the config is correct wherever the
//  user dragged mdEdit.app. The bridge ships inside the bundle at
//  Contents/Helpers/mdedit-mcp, signed and notarized with the app.
//

import SwiftUI
import AppKit

enum ClaudeDesktopSetup {
    /// Absolute path to the bundled stdio bridge Claude Desktop launches.
    static var helperPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/mdedit-mcp")
            .path
    }

    /// Absolute path to the running app bundle (passed to the bridge as MDEDIT_APP_PATH).
    static var appPath: String {
        Bundle.main.bundleURL.path
    }

    /// Claude Desktop's config file. Sandbox is off, so this resolves to the real
    /// ~/Library/Application Support/Claude, not an app container.
    static var configURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude_desktop_config.json")
    }

    /// True when the bridge is actually present in the bundle (false in dev/Xcode
    /// builds that haven't run the distribution packaging step).
    static var helperExists: Bool {
        FileManager.default.isExecutableFile(atPath: helperPath)
    }

    /// A complete, paste-ready config using the resolved paths — for manual setup.
    static var configSnippet: String {
        """
        {
          "mcpServers": {
            "mdedit": {
              "command": "\(helperPath)",
              "env": { "MDEDIT_APP_PATH": "\(appPath)" }
            }
          }
        }
        """
    }

    enum SetupError: LocalizedError {
        case invalidExistingConfig

        var errorDescription: String? {
            switch self {
            case .invalidExistingConfig:
                return "Claude Desktop's existing configuration file isn't valid JSON, "
                     + "so it wasn't changed. Use “Copy Configuration” and paste it in by hand."
            }
        }
    }

    /// Merge the `mdedit` server into Claude Desktop's config, preserving any other
    /// servers and settings. Backs up an existing file before writing. Returns
    /// whether a fresh config file had to be created.
    @discardableResult
    static func apply() throws -> Bool {
        let entry: [String: Any] = [
            "command": helperPath,
            "env": ["MDEDIT_APP_PATH": appPath],
        ]

        let fm = FileManager.default
        try fm.createDirectory(at: configURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        var createdNew = true

        if fm.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            if !data.isEmpty {
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw SetupError.invalidExistingConfig
                }
                root = obj
                createdNew = false
                // Keep a one-shot backup next to the original before we touch it.
                let backup = configURL.appendingPathExtension("mdedit-backup")
                try? data.write(to: backup)
            }
        }

        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["mdedit"] = entry
        root["mcpServers"] = servers

        let out = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try out.write(to: configURL)
        return createdNew
    }

    static func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configSnippet, forType: .string)
    }

    static func revealConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }
}

struct ClaudeSetupView: View {
    @State private var alert: SetupAlert?

    private struct SetupAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Set Up Claude Desktop")
                    .font(.title2.weight(.semibold))

                Text("mdEdit lets Claude Desktop read and edit your open documents "
                   + "through a small bridge that ships inside this app. To enable it, "
                   + "Claude Desktop needs the entry below in its configuration.")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)

                if !ClaudeDesktopSetup.helperExists {
                    Label("The bridge isn’t bundled in this build — this is expected when "
                        + "running from Xcode. A distributed mdEdit.app includes it.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(ClaudeDesktopSetup.configSnippet)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 12) {
                    Button("Set Up Automatically") { runApply() }
                        .buttonStyle(.borderedProminent)
                    Button("Copy Configuration") {
                        ClaudeDesktopSetup.copyToPasteboard()
                        alert = SetupAlert(
                            title: "Copied",
                            message: "Paste it into Claude Desktop’s "
                                   + "claude_desktop_config.json, then restart Claude Desktop.")
                    }
                    Spacer()
                    Button("Reveal Config File") { ClaudeDesktopSetup.revealConfigInFinder() }
                        .buttonStyle(.link)
                }

                Text("“Set Up Automatically” merges the entry into your existing "
                   + "configuration (other MCP servers are preserved, and a backup is "
                   + "written alongside the original). Restart Claude Desktop afterward "
                   + "for it to take effect.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Set Up Claude Desktop")
        .alert(item: $alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }

    private func runApply() {
        do {
            let createdNew = try ClaudeDesktopSetup.apply()
            alert = SetupAlert(
                title: "Claude Desktop Is Set Up",
                message: (createdNew
                    ? "Created a new configuration for Claude Desktop. "
                    : "Added mdEdit to your Claude Desktop configuration. ")
                    + "Restart Claude Desktop for it to take effect.")
        } catch {
            alert = SetupAlert(title: "Couldn’t Set Up Automatically",
                               message: error.localizedDescription)
        }
    }
}
