//
//  VersionCheckpoints.swift
//  mdEdit
//
//  Restorable checkpoints, built on the version store macOS already keeps for
//  these documents rather than on a snapshot format of our own.
//
//  What the system already does: DocumentGroup autosaves in place, so NSDocument
//  files versions into /.DocumentRevisions-V100 and File ▸ Revert To ▸ Browse All
//  Versions reads them. What it does *not* do is file one per edit — it coalesces
//  autosaves within an editing burst, so two AI rewrites in a row leave only one
//  restorable point and the intermediate text is gone. Human typing doesn't care
//  (the undo stack covers it), but an AI edit is flushed to disk the moment it
//  lands, so without an explicit boundary there is nothing to go back to.
//
//  A checkpoint is therefore one `NSFileVersion.addOfItem` per discrete action —
//  per MCP tool call, never per keystroke — and it needs no UI of its own: the
//  versions it files show up in the standard Revert To browser alongside the
//  system's own.
//

import AppKit

@MainActor
enum VersionCheckpoint {

    /// File `contents` as a restorable version of the document at `url`.
    ///
    /// `contents` is the live buffer rather than the bytes on disk: when the
    /// human has typed since the last autosave the two differ, and the point
    /// worth preserving is the text that was actually on screen before we
    /// changed it.
    @discardableResult
    static func record(contents: String, of url: URL) -> Bool {
        let target = url.standardizedFileURL
        // Only files have a version store. Unsaved documents have no URL at all
        // and never reach here, but a document whose file was moved or deleted
        // underneath us can.
        guard FileManager.default.fileExists(atPath: target.path) else { return false }

        // Nothing to preserve if the newest version already holds this text —
        // two Pins in a row, or an edit that replaced a range with itself.
        if newestVersionContents(of: target) == contents { return false }

        // addOfItem copies from a file, so the buffer has to land on disk first.
        // Keeping the document's own filename makes the version's localizedName
        // read correctly in the Revert To browser.
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let staged = staging.appendingPathComponent(target.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: staged, options: .atomic)
            try NSFileVersion.addOfItem(at: target, withContentsOf: staged)
            // Left alone deliberately: a new version is already non-discardable,
            // which is what we want — the checkpoint has to still be there when
            // you decide the AI's rewrite was wrong. Assigning `isDiscardable`
            // at all raises an ObjC exception no `catch` here could contain.
            return true
        } catch {
            // A checkpoint is a safety net, never a gate — if the version store
            // refuses, the edit still goes through.
            NSLog("mdEdit: could not checkpoint %@: %@", target.lastPathComponent, error.localizedDescription)
            return false
        }
    }

    /// Everything the Pin command needs from the frontmost window, handed to the
    /// menu bar as a focused value so the shortcut always acts on that window.
    struct Target: Equatable {
        let document: MarkdownDocument
        let fileURL: URL?

        /// A document that has never been saved has no file, and so no version
        /// store to pin into.
        var canPin: Bool { fileURL != nil }

        @MainActor
        func pin() {
            guard let fileURL else { return }
            VersionCheckpoint.record(contents: document.text, of: fileURL)
        }

        /// Identity, not contents: the menu only needs to know when focus moved
        /// to a different window, and the buffer changes on every keystroke.
        static func == (lhs: Target, rhs: Target) -> Bool {
            lhs.document === rhs.document && lhs.fileURL == rhs.fileURL
        }
    }

    /// The text of the most recently filed version, used to avoid duplicates.
    private static func newestVersionContents(of url: URL) -> String? {
        guard let newest = NSFileVersion.otherVersionsOfItem(at: url)?
            .max(by: { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }),
              let data = try? Data(contentsOf: newest.url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
