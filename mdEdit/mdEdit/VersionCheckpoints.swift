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

        // Nothing to preserve if some stored version already holds this text —
        // two Pins in a row, an edit that replaced a range with itself, or the
        // save that just preserved these contents on its own. Every version is
        // checked, not just the newest: a version carries the modification date
        // of the contents it holds, so "newest" by date is not the last one
        // filed.
        if hasStoredVersion(matching: contents, of: target) { return false }

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

    /// Drop versions whose contents exactly match one already in the store,
    /// keeping the first of each set. Saving in place files its own copy of the
    /// contents a checkpoint just preserved, so without this every AI edit can
    /// leave two identical entries in Revert To.
    ///
    /// The delay exists because that copy appears a moment after the save
    /// finishes; the work is idempotent, so a prune that runs too early simply
    /// finds nothing and the next edit clears it.
    static func pruneDuplicates(of url: URL, after delay: DispatchTimeInterval = .seconds(0)) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var keptBySize: [Int: [Data]] = [:]
            for version in NSFileVersion.otherVersionsOfItem(at: url) ?? [] {
                guard let data = try? Data(contentsOf: version.url) else { continue }
                if keptBySize[data.count]?.contains(data) == true {
                    try? version.remove()
                } else {
                    keptBySize[data.count, default: []].append(data)
                }
            }
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

    /// Whether the version store already holds a version with exactly these
    /// contents. Sizes are compared first so a document with a long history
    /// costs one `stat` per version rather than a full read.
    private static func hasStoredVersion(matching contents: String, of url: URL) -> Bool {
        let wanted = Data(contents.utf8)
        for version in NSFileVersion.otherVersionsOfItem(at: url) ?? [] {
            let size = (try? version.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            guard size == wanted.count else { continue }
            if let stored = try? Data(contentsOf: version.url), stored == wanted { return true }
        }
        return false
    }
}
