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

struct SidebarVisibleKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

/// The frontmost window's type-size nudge, in points off the size set in Settings.
struct EditorZoomKey: FocusedValueKey {
    typealias Value = Binding<CGFloat>
}

extension FocusedValues {
    var previewVisible: Binding<Bool>? {
        get { self[PreviewVisibleKey.self] }
        set { self[PreviewVisibleKey.self] = newValue }
    }

    var sidebarVisible: Binding<Bool>? {
        get { self[SidebarVisibleKey.self] }
        set { self[SidebarVisibleKey.self] = newValue }
    }

    var editorZoom: Binding<CGFloat>? {
        get { self[EditorZoomKey.self] }
        set { self[EditorZoomKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedBinding(\.previewVisible) private var previewVisible
    @FocusedBinding(\.sidebarVisible) private var sidebarVisible
    @FocusedBinding(\.editorZoom) private var editorZoom
    @FocusedValue(\.editorActions) private var editorActions

    @AppStorage(SettingsKeys.focusMode) private var focusMode = false
    @AppStorage(SettingsKeys.showWordCount) private var showWordCount = true

    @Environment(\.openWindow) private var openWindow

    private var noEditor: Bool { editorActions == nil }

    var body: some Commands {
        // File menu: the scratchpad sits with New/Open because that's what it
        // is — a document you reach for, not a panel.
        CommandGroup(after: .newItem) {
            Button("Scratchpad") {
                Scratchpad.openOrFocus()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
        }

        // App menu: a one-click bridge setup, right below Settings…
        CommandGroup(after: .appSettings) {
            Button("Set Up Claude Desktop…") {
                openWindow(id: WindowID.claudeSetup)
            }
        }

        // View menu: the sidebar sits in the system's own sidebar slot, with
        // the standard ⌃⌘S.
        CommandGroup(after: .sidebar) {
            Button(sidebarVisible == true ? "Hide Sidebar" : "Show Sidebar") {
                sidebarVisible?.toggle()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(sidebarVisible == nil)
        }

        // View menu additions, next to "Show Toolbar".
        CommandGroup(after: .toolbar) {
            Button(previewVisible == true ? "Show Source" : "Show Preview") {
                previewVisible?.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(previewVisible == nil)

            // Type size for this window only: it is not written to settings,
            // and it goes away with the window.
            Button("Bigger") { editorZoom = (editorZoom ?? 0) + 1 }
                .keyboardShortcut("+", modifiers: [.command])
                .disabled(editorZoom == nil)
            Button("Smaller") { editorZoom = (editorZoom ?? 0) - 1 }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(editorZoom == nil)
            Button("Actual Size") { editorZoom = 0 }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(editorZoom == nil || editorZoom == 0)

            Divider()

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
