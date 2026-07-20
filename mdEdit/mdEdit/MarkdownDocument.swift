//
//  MarkdownDocument.swift
//  mdEdit
//
//  The document is a reference type on purpose: it owns a live text buffer
//  and a monotonic revision counter that both the human (via the editor) and
//  the AI (via MCP) mutate. The revision counter — not a timestamp — backs
//  stale-write detection, so it stays valid regardless of clock skew.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

extension UTType {
    /// Markdown, matching the type the app imports/claims in Info.plist. Using
    /// the same identifier keeps DocumentGroup, Launch Services, and the Open
    /// panel in agreement.
    static let markdown = UTType(importedAs: "net.daringfireball.markdown")
}

final class MarkdownDocument: ReferenceFileDocument {
    typealias Snapshot = String

    // Markdown first so new documents default to a `.md` file on first save.
    static let readableContentTypes: [UTType] = [.markdown, .plainText]
    static let writableContentTypes: [UTType] = [.markdown, .plainText]

    /// The single source of truth for the document's contents. Every mutation,
    /// human or AI, flows through here and bumps `revision`.
    @Published private(set) var text: String
    @Published private(set) var revision: Int = 0

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = String(decoding: data, as: UTF8.self)
    }

    /// Replace the whole buffer, bumping the revision. Used by the editor
    /// binding today and by whole-file MCP edits later.
    func replaceText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        revision &+= 1
    }

    func snapshot(contentType: UTType) throws -> Snapshot {
        text
    }

    nonisolated func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(snapshot.utf8))
    }
}
