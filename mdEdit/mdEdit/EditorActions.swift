//
//  EditorActions.swift
//  mdEdit
//
//  Markdown insertion commands that act on the frontmost document's live text
//  view. Every mutation goes through the NSTextView's shouldChangeText /
//  didChangeText dance, so it is undoable, visible, and persisted like any human
//  edit. The active instance is published to the menu bar via a focused value.
//

import SwiftUI
import AppKit

@MainActor
final class EditorActions {
    weak var textView: NSTextView?

    var isAvailable: Bool { textView != nil }

    // MARK: Inline (wrap the selection)

    func bold() { wrap("**", "**", placeholder: "bold") }
    func italic() { wrap("*", "*", placeholder: "italic") }
    func strikethrough() { wrap("~~", "~~", placeholder: "text") }
    func inlineCode() { wrap("`", "`", placeholder: "code") }

    func link() {
        replaceSelection(makeReplacement: { selected in
            let label = selected.isEmpty ? "title" : selected
            return ("[\(label)](url)", "url")
        })
    }

    func image() {
        replaceSelection(makeReplacement: { selected in
            let alt = selected.isEmpty ? "alt" : selected
            return ("![\(alt)](path)", "path")
        })
    }

    // MARK: Line-prefixed blocks

    func heading(_ level: Int) {
        let hashes = String(repeating: "#", count: level)
        prefixLines { _ in hashes + " " }
    }

    func bulletList() { prefixLines { _ in "- " } }
    func numberedList() { prefixLines { index in "\(index). " } }
    func quote() { prefixLines { _ in "> " } }

    // MARK: Multi-line inserts

    func codeBlock() {
        replaceSelection(makeReplacement: { selected in
            let body = selected.isEmpty ? "code" : selected
            return ("```\n\(body)\n```\n", selected.isEmpty ? "code" : nil)
        })
    }

    func table() {
        let template = """
        | Column | Column |
        | --- | --- |
        | Cell | Cell |
        """
        insert("\(template)\n", selecting: "Column")
    }

    func horizontalRule() {
        insert("\n---\n\n")
    }

    // MARK: Primitives

    private func wrap(_ prefix: String, _ suffix: String, placeholder: String) {
        guard let textView else { return }
        let ns = textView.string as NSString
        let range = textView.selectedRange()
        let selected = ns.substring(with: range)
        let inner = selected.isEmpty ? placeholder : selected
        let replacement = prefix + inner + suffix
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        let innerStart = range.location + (prefix as NSString).length
        textView.setSelectedRange(NSRange(location: innerStart, length: (inner as NSString).length))
    }

    /// Replace the selection with computed text, optionally reselecting a token.
    private func replaceSelection(makeReplacement: (String) -> (text: String, reselect: String?)) {
        guard let textView else { return }
        let ns = textView.string as NSString
        let range = textView.selectedRange()
        let selected = ns.substring(with: range)
        let (replacement, reselect) = makeReplacement(selected)
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        if let reselect, case let token = (replacement as NSString).range(of: reselect), token.location != NSNotFound {
            textView.setSelectedRange(NSRange(location: range.location + token.location, length: token.length))
        } else {
            textView.setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
        }
    }

    private func insert(_ text: String, selecting: String? = nil) {
        guard let textView else { return }
        let range = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        if let selecting, case let token = (text as NSString).range(of: selecting), token.location != NSNotFound {
            textView.setSelectedRange(NSRange(location: range.location + token.location, length: token.length))
        } else {
            textView.setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        }
    }

    /// Prefix each line touched by the selection (or the caret's line).
    private func prefixLines(_ makePrefix: (Int) -> String) {
        guard let textView else { return }
        let ns = textView.string as NSString
        let lineRange = ns.lineRange(for: textView.selectedRange())
        let block = ns.substring(with: lineRange)
        let hasTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() } // drop the empty tail

        let transformed = lines.enumerated()
            .map { makePrefix($0.offset + 1) + $0.element }
            .joined(separator: "\n")
        let result = hasTrailingNewline ? transformed + "\n" : transformed

        guard textView.shouldChangeText(in: lineRange, replacementString: result) else { return }
        textView.textStorage?.replaceCharacters(in: lineRange, with: result)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: lineRange.location, length: (result as NSString).length))
    }
}

// MARK: - Focused value plumbing

struct EditorActionsKey: FocusedValueKey {
    typealias Value = EditorActions
}

extension FocusedValues {
    var editorActions: EditorActions? {
        get { self[EditorActionsKey.self] }
        set { self[EditorActionsKey.self] = newValue }
    }
}
