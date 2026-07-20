//
//  DocumentRegistry.swift
//  mdEdit
//
//  The single source of truth for what the AI can see and touch. It maps file
//  paths to the live document (and its NSTextView) for every open window, and
//  it implements the five MCP tool operations against those live buffers.
//
//  Everything here runs on the main actor: tool calls arriving on the socket
//  hop onto the main thread before dispatching, so edits are applied to the
//  real text view the human is looking at — no off-screen side effects.
//

import AppKit
import SwiftUI

@MainActor
final class DocumentRegistry {
    static let shared = DocumentRegistry()

    private struct WeakDocument { weak var document: MarkdownDocument? }
    private struct WeakTextView { weak var textView: NSTextView? }

    /// Open documents addressable by their on-disk path.
    private var documentsByPath: [String: WeakDocument] = [:]
    /// The live text view for each document, keyed by document identity.
    private var textViewsByDocument: [ObjectIdentifier: WeakTextView] = [:]
    /// The on-disk URL for each document, so we can reach its NSDocument wrapper.
    private var urlByDocument: [ObjectIdentifier: URL] = [:]

    private init() {}

    // MARK: Registration (called from the SwiftUI layer)

    func register(document: MarkdownDocument, url: URL?) {
        guard let url else { return } // unsaved docs aren't addressable by path
        documentsByPath[Self.key(for: url)] = WeakDocument(document: document)
        urlByDocument[ObjectIdentifier(document)] = url
    }

    func unregister(url: URL?) {
        guard let url else { return }
        documentsByPath[Self.key(for: url)] = nil
    }

    /// Flag the document's NSDocument wrapper dirty so autosave persists the
    /// change. Called from the editor's textDidChange — the single choke point
    /// both human typing and AI edits funnel through — because SwiftUI's
    /// ReferenceFileDocument does not observe our out-of-band buffer mutations.
    func markDirty(document: MarkdownDocument) {
        guard let url = urlByDocument[ObjectIdentifier(document)] else { return }
        NSDocumentController.shared.document(for: url)?.updateChangeCount(.changeDone)
    }

    func attach(textView: NSTextView, to document: MarkdownDocument) {
        textViewsByDocument[ObjectIdentifier(document)] = WeakTextView(textView: textView)
    }

    // MARK: Tool dispatch

    /// Route a socket request (a decoded JSON object with an `op`) to a tool and
    /// return a JSON-ready response dictionary.
    func handle(op: String, args: [String: Any]) -> [String: Any] {
        switch op {
        case "list_open_files": return ["open_files": openFiles()]
        case "open_file": return openFile(path: args["path"] as? String)
        case "read_file": return readFile(path: args["path"] as? String)
        case "edit_file": return editFile(args)
        case "get_selection": return getSelection(path: args["path"] as? String)
        default: return ["error": "unknown_op", "op": op]
        }
    }

    // MARK: Tools

    private func openFiles() -> [String] {
        pruneDead()
        return documentsByPath.keys.sorted()
    }

    private func openFile(path: String?) -> [String: Any] {
        guard let path else { return ["error": "bad_request"] }
        let url = URL(fileURLWithPath: path)
        let key = Self.key(for: url)

        if let document = documentsByPath[key]?.document {
            focusWindow(for: document)
            return ["ok": true, "already_open": true, "revision": document.revision]
        }

        guard FileManager.default.fileExists(atPath: url.standardizedFileURL.path) else {
            return ["error": "not_found", "path": path]
        }

        NSApp.activate(ignoringOtherApps: true)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        return ["ok": true, "already_open": false]
    }

    private func readFile(path: String?) -> [String: Any] {
        guard let path else { return ["error": "bad_request"] }
        let url = URL(fileURLWithPath: path)

        if let document = documentsByPath[Self.key(for: url)]?.document {
            return ["content": document.text, "revision": document.revision, "open": true]
        }

        // Disk tier: plain whole-file read.
        guard FileManager.default.fileExists(atPath: url.standardizedFileURL.path) else {
            return ["error": "not_found", "path": path]
        }
        guard let data = FileManager.default.contents(atPath: url.standardizedFileURL.path) else {
            return ["error": "read_failed", "path": path]
        }
        return ["content": String(decoding: data, as: UTF8.self), "open": false]
    }

    private func editFile(_ args: [String: Any]) -> [String: Any] {
        guard let path = args["path"] as? String, let edit = args["edit"] as? [String: Any] else {
            return ["error": "bad_request"]
        }
        let url = URL(fileURLWithPath: path)

        // Promotion rule: editing a file that isn't open is an explicit error,
        // not a silent open. The AI should call open_file, then retry.
        guard let document = documentsByPath[Self.key(for: url)]?.document else {
            return ["error": "not_open", "path": path]
        }

        guard let base = args["base_revision"] as? Int else {
            return ["error": "base_revision_required", "path": path, "current_revision": document.revision]
        }

        // Stale-write detection: the human may have typed since the AI's read.
        guard base == document.revision else {
            return [
                "error": "stale",
                "path": path,
                "current_revision": document.revision,
                "current_content": document.text,
            ]
        }

        guard let start = edit["start"] as? Int,
              let end = edit["end"] as? Int,
              let text = edit["text"] as? String else {
            return ["error": "bad_edit"]
        }

        let length = (document.text as NSString).length
        guard start >= 0, end >= start, end <= length else {
            return ["error": "invalid_range", "start": start, "end": end, "length": length]
        }

        let range = NSRange(location: start, length: end - start)
        let insertedLength = (text as NSString).length

        if let textView = textViewsByDocument[ObjectIdentifier(document)]?.textView {
            // Route through the live text view so the edit is visible and undoable.
            if textView.shouldChangeText(in: range, replacementString: text) {
                textView.textStorage?.replaceCharacters(in: range, with: text)
                let inserted = NSRange(location: start, length: insertedLength)
                textView.textStorage?.setAttributes(textView.typingAttributes, range: inserted)
                textView.didChangeText() // fires textDidChange → document bumps revision
                textView.setSelectedRange(NSRange(location: start + insertedLength, length: 0))
            }
        } else {
            // No live view (shouldn't happen while a window is open) — mutate the
            // model directly. This bypasses textDidChange, so mark dirty here.
            let newString = (document.text as NSString).replacingCharacters(in: range, with: text)
            document.replaceText(newString)
            markDirty(document: document)
        }
        // The live-view branch marks dirty via the editor's textDidChange, which
        // didChangeText() above triggers — so no explicit mark is needed here.

        // Flush AI edits to disk immediately. Unlike human typing (which autosaves
        // on a short delay), an AI edit is a discrete action, and the git-like
        // model wants the on-disk working tree current the moment it's written.
        NSDocumentController.shared.document(for: url)?
            .autosave(withImplicitCancellability: false) { _ in }

        return ["ok": true, "revision": document.revision]
    }

    private func getSelection(path: String?) -> [String: Any] {
        guard let path else { return ["error": "bad_request"] }
        let url = URL(fileURLWithPath: path)
        guard let document = documentsByPath[Self.key(for: url)]?.document else {
            return ["error": "not_open", "path": path]
        }
        guard let textView = textViewsByDocument[ObjectIdentifier(document)]?.textView else {
            return ["error": "no_view", "path": path]
        }
        let selection = textView.selectedRange()
        let selectedText = (textView.string as NSString).substring(with: selection)
        return [
            "start": selection.location,
            "end": selection.location + selection.length,
            "selected_text": selectedText,
            "revision": document.revision,
        ]
    }

    // MARK: Helpers

    private func focusWindow(for document: MarkdownDocument) {
        NSApp.activate(ignoringOtherApps: true)
        textViewsByDocument[ObjectIdentifier(document)]?.textView?.window?.makeKeyAndOrderFront(nil)
    }

    private func pruneDead() {
        documentsByPath = documentsByPath.filter { $0.value.document != nil }
        textViewsByDocument = textViewsByDocument.filter { $0.value.textView != nil }
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
