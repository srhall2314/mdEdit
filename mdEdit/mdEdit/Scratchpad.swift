//
//  Scratchpad.swift
//  mdEdit
//
//  One always-there document for text in transit: paste something in from a
//  web page (the source editor is plain text, so the formatting is dropped on
//  the way in), hold it while it moves somewhere else, and find it again after
//  a relaunch. It is an ordinary markdown file on disk, so it gets the same
//  editor, autosave, and MCP addressability as any other document — the app
//  just guarantees that it exists and that it opens first.
//

import AppKit
import SwiftUI

enum Scratchpad {
    /// Beside the MCP socket, in the app's own support directory: this is app
    /// state the app maintains, not a document the user filed somewhere.
    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("mdEdit/Scratchpad.md")
    }

    static func isScratchpad(_ candidate: URL?) -> Bool {
        guard let candidate else { return false }
        return candidate.standardizedFileURL == url.standardizedFileURL
    }

    /// Create the file when it's missing — first launch, or the user threw it
    /// away between runs. Seeded empty: a scratchpad with boilerplate in it is
    /// one more thing to delete.
    static func ensureExists() {
        let fileURL = url
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: fileURL)
    }

    /// Open the scratchpad, or bring it forward if it's already open.
    /// Idempotent: NSDocumentController hands back the existing document for a
    /// URL it already has open rather than opening a second copy.
    @MainActor
    static func openOrFocus() {
        ensureExists()
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }
}

// MARK: - Window placement and close confirmation

/// A zero-size view that adopts the scratchpad's window: it keeps the tab
/// pinned leftmost, and it makes ⌘W ask first. Both exist because the
/// scratchpad's whole value is being the tab that's reliably *there* — at
/// launch, macOS restores previously-open documents before we get to open the
/// scratchpad, so without this it lands wherever restoration happens to leave
/// it.
struct ScratchpadWindowGuard: NSViewRepresentable {
    func makeCoordinator() -> Guard { Guard() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window isn't set until the view joins the hierarchy, and the tab
        // group forms later still — hence the second, delayed attempt.
        DispatchQueue.main.async {
            context.coordinator.adopt(view.window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            context.coordinator.adopt(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Sits in front of the window's real delegate (the document's window
    /// controller) and forwards everything it doesn't handle, so document
    /// behavior — saving, restoration, tabbing — is otherwise untouched.
    final class Guard: NSObject, NSWindowDelegate {
        weak var next: NSWindowDelegate?

        func adopt(_ window: NSWindow?) {
            guard let window else { return }
            if !(window.delegate is Guard) {
                next = window.delegate
                window.delegate = self
            }
            moveToFirstTab(window)
        }

        /// Pull the scratchpad to the head of its tab group. No-op when it's
        /// already there, or when the window isn't tabbed at all.
        private func moveToFirstTab(_ window: NSWindow) {
            guard let group = window.tabGroup,
                  group.windows.count > 1,
                  let leader = group.windows.first,
                  leader !== window else { return }
            let wasSelected = group.selectedWindow === window
            group.removeWindow(window)
            leader.addTabbedWindow(window, ordered: .below)
            if wasSelected { window.makeKeyAndOrderFront(nil) }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            let alert = NSAlert()
            alert.messageText = "Close the Scratchpad?"
            alert.informativeText = "Its contents are saved, and reopening it with ⌥⌘S brings them back."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            return next?.windowShouldClose?(sender) ?? true
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || next?.responds(to: aSelector) == true
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if next?.responds(to: aSelector) == true { return next }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
