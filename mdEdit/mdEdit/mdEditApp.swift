//
//  mdEditApp.swift
//  mdEdit
//
//  A local-first markdown editor whose open documents are directly
//  readable and editable by an AI over a local MCP transport.
//

import SwiftUI

@main
struct mdEditApp: App {
    // Owns the MCP endpoint lifecycle (Unix socket server + document registry).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @AppStorage(SettingsKeys.appearance) private var appearance = AppAppearance.system.rawValue

    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument() }) { config in
            ContentView(document: config.document, fileURL: config.fileURL)
                .preferredColorScheme(resolvedAppearance.colorScheme)
        }
        .commands {
            AppCommands()
        }

        Settings {
            SettingsView()
                .preferredColorScheme(resolvedAppearance.colorScheme)
        }

        Window("Markdown Syntax", id: WindowID.markdownHelp) {
            MarkdownHelpView()
                .preferredColorScheme(resolvedAppearance.colorScheme)
        }
        .defaultSize(width: 760, height: 820)

        Window("Set Up Claude Desktop", id: WindowID.claudeSetup) {
            ClaudeSetupView()
                .preferredColorScheme(resolvedAppearance.colorScheme)
        }
        .defaultSize(width: 640, height: 560)
        .windowResizability(.contentSize)
    }

    private var resolvedAppearance: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }
}
