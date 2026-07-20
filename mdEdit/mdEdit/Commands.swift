//
//  Commands.swift
//  mdEdit
//
//  Native menu bar commands. Per-window state (preview toggle) and per-window
//  editing actions (Insert menu) are surfaced to the app-level menu via focused
//  values, so shortcuts always act on the frontmost document — the HIG pattern.
//

import SwiftUI

struct PreviewVisibleKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var previewVisible: Binding<Bool>? {
        get { self[PreviewVisibleKey.self] }
        set { self[PreviewVisibleKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedBinding(\.previewVisible) private var previewVisible
    @FocusedValue(\.editorActions) private var editorActions

    @AppStorage(SettingsKeys.focusMode) private var focusMode = false
    @AppStorage(SettingsKeys.showWordCount) private var showWordCount = true

    @Environment(\.openWindow) private var openWindow

    private var noEditor: Bool { editorActions == nil }

    var body: some Commands {
        // App menu: a one-click bridge setup, right below Settings…
        CommandGroup(after: .appSettings) {
            Button("Set Up Claude Desktop…") {
                openWindow(id: WindowID.claudeSetup)
            }
        }

        // View menu additions, next to "Show Toolbar".
        CommandGroup(after: .toolbar) {
            Button(previewVisible == true ? "Show Source" : "Show Preview") {
                previewVisible?.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(previewVisible == nil)

            Toggle("Focus Mode", isOn: $focusMode)
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Toggle("Show Word Count", isOn: $showWordCount)
            Divider()
        }

        // A dedicated Insert menu for markdown syntax.
        CommandMenu("Insert") {
            Button("Bold") { editorActions?.bold() }
                .keyboardShortcut("b").disabled(noEditor)
            Button("Italic") { editorActions?.italic() }
                .keyboardShortcut("i").disabled(noEditor)
            Button("Strikethrough") { editorActions?.strikethrough() }
                .disabled(noEditor)
            Button("Inline Code") { editorActions?.inlineCode() }
                .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(noEditor)

            Divider()

            Button("Link…") { editorActions?.link() }
                .keyboardShortcut("k").disabled(noEditor)
            Button("Image…") { editorActions?.image() }
                .keyboardShortcut("k", modifiers: [.command, .shift]).disabled(noEditor)

            Divider()

            Menu("Heading") {
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") { editorActions?.heading(level) }
                        .keyboardShortcut(KeyEquivalent(Character("\(level)")), modifiers: [.command, .control])
                        .disabled(noEditor)
                }
            }
            Button("Bulleted List") { editorActions?.bulletList() }.disabled(noEditor)
            Button("Numbered List") { editorActions?.numberedList() }.disabled(noEditor)
            Button("Block Quote") { editorActions?.quote() }.disabled(noEditor)

            Divider()

            Button("Code Block") { editorActions?.codeBlock() }.disabled(noEditor)
            Button("Table") { editorActions?.table() }.disabled(noEditor)
            Button("Horizontal Rule") { editorActions?.horizontalRule() }.disabled(noEditor)
        }

        // Replace the default (broken) Help item with our syntax window.
        CommandGroup(replacing: .help) {
            Button("mdEdit Markdown Syntax") {
                openWindow(id: WindowID.markdownHelp)
            }
            .keyboardShortcut("?", modifiers: [.command])
        }
    }
}

enum WindowID {
    static let markdownHelp = "markdown-help"
    static let claudeSetup = "claude-setup"
}
