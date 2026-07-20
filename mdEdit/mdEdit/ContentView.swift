//
//  ContentView.swift
//  mdEdit
//
//  A calm, iA Writer-inspired writing surface: raw markdown source in a fixed,
//  centered measure with a preview toggle, focus mode, and a Liquid Glass word
//  count. The source view is an NSTextView so we keep real NSTextStorage,
//  cursor, and selection — the substrate the MCP layer needs for granular,
//  selection-aware edits.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var document: MarkdownDocument
    let fileURL: URL?

    @State private var showPreview = false
    @State private var actions = EditorActions()

    @AppStorage(SettingsKeys.fontFamily) private var fontFamily = EditorFontFamily.mono.rawValue
    @AppStorage(SettingsKeys.fontSize) private var fontSize = SettingsKeys.defaultFontSize
    @AppStorage(SettingsKeys.lineHeight) private var lineHeight = SettingsKeys.defaultLineHeight
    @AppStorage(SettingsKeys.focusMode) private var focusMode = false
    @AppStorage(SettingsKeys.showWordCount) private var showWordCount = true

    private var style: EditorStyle {
        EditorStyle(familyRaw: fontFamily, size: fontSize, lineHeight: lineHeight)
    }

    var body: some View {
        Group {
            if showPreview {
                MarkdownPreview(text: document.text, baseURL: fileURL)
            } else {
                MarkdownSourceView(document: document, style: style, focusMode: focusMode, actions: actions)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottomTrailing) {
            if showWordCount {
                WordCountPill(text: document.text)
                    .padding(16)
            }
        }
        // Register this window with the MCP document registry while it's live.
        .onAppear { DocumentRegistry.shared.register(document: document, url: fileURL) }
        .onDisappear { DocumentRegistry.shared.unregister(url: fileURL) }
        .onChange(of: fileURL) { old, new in
            DocumentRegistry.shared.unregister(url: old)
            DocumentRegistry.shared.register(document: document, url: new)
        }
        // Surface per-window preview state and editing actions to the menu bar.
        .focusedSceneValue(\.previewVisible, $showPreview)
        .focusedSceneValue(\.editorActions, actions)
        .toolbar {
            ToolbarItem {
                Button {
                    showPreview.toggle()
                } label: {
                    Label(showPreview ? "Source" : "Preview",
                          systemImage: showPreview ? "curlybraces" : "eye")
                }
                .help(showPreview ? "Show markdown source (⇧⌘P)" : "Show rendered preview (⇧⌘P)")
            }
        }
    }
}

// MARK: - Source editor

struct MarkdownSourceView: NSViewRepresentable {
    @ObservedObject var document: MarkdownDocument
    var style: EditorStyle
    var focusMode: Bool
    var actions: EditorActions

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.postsFrameChangedNotifications = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        // Touch the layout manager to pin TextKit 1, so focus mode can use
        // temporary attributes without mutating the document or undo stack.
        _ = textView.layoutManager

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.style = style
        context.coordinator.focusMode = focusMode
        context.coordinator.applyStyle()
        context.coordinator.setText(document.text)
        context.coordinator.startObservingWidth()

        // Let the registry reach this window's live text view for selection/edits.
        DocumentRegistry.shared.attach(textView: textView, to: document)
        // Let the menu's Insert commands act on this text view.
        actions.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator

        if coordinator.style != style {
            coordinator.style = style
            coordinator.applyStyle()
            coordinator.reapplyStyleToBuffer()
            coordinator.updateMeasure()
        }

        if coordinator.focusMode != focusMode {
            coordinator.focusMode = focusMode
            coordinator.refreshFocus()
        }

        // Only push the model into the view when they've genuinely diverged
        // (an AI edit), so we never clobber the human's caret while typing.
        if textView.string != document.text {
            let previous = textView.selectedRange()
            coordinator.setText(document.text)
            let length = (document.text as NSString).length
            textView.setSelectedRange(NSRange(location: min(previous.location, length), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let document: MarkdownDocument
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var style = EditorStyle(familyRaw: EditorFontFamily.mono.rawValue,
                                size: SettingsKeys.defaultFontSize,
                                lineHeight: SettingsKeys.defaultLineHeight)
        var focusMode = false
        private var frameObserver: NSObjectProtocol?

        init(document: MarkdownDocument) { self.document = document }

        deinit {
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        }

        func applyStyle() {
            guard let textView else { return }
            textView.typingAttributes = style.typingAttributes
            textView.defaultParagraphStyle = style.paragraphStyle
            textView.font = style.nsFont
        }

        /// Set the whole buffer and (re)apply the writing typography to it.
        func setText(_ string: String) {
            guard let textView else { return }
            textView.string = string
            reapplyStyleToBuffer()
            refreshFocus()
        }

        func reapplyStyleToBuffer() {
            guard let textView else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            textView.textStorage?.setAttributes(style.typingAttributes, range: full)
        }

        func startObservingWidth() {
            guard let scrollView else { return }
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.updateMeasure()
            }
            updateMeasure()
        }

        /// Grow the horizontal inset so the text column stays centered at the
        /// target measure, iA Writer-style.
        func updateMeasure() {
            guard let textView, let scrollView else { return }
            let width = scrollView.contentSize.width
            let inset = max(Theme.minHorizontalInset, (width - Theme.maxMeasure) / 2)
            textView.textContainerInset = NSSize(width: inset, height: Theme.verticalInset)
        }

        // MARK: Focus mode (dim inactive paragraphs)

        func refreshFocus() {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            guard focusMode else { return }
            layoutManager.addTemporaryAttributes(
                [.foregroundColor: NSColor.labelColor.withAlphaComponent(0.25)],
                forCharacterRange: full
            )
            let active = (textView.string as NSString).paragraphRange(for: textView.selectedRange())
            layoutManager.addTemporaryAttributes(
                [.foregroundColor: NSColor.labelColor],
                forCharacterRange: active
            )
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            document.replaceText(textView.string)
            // Both human typing and AI edits reach here; mark the document dirty
            // so SwiftUI's autosave persists the change.
            DocumentRegistry.shared.markDirty(document: document)
            refreshFocus()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if focusMode { refreshFocus() }
        }
    }
}

// MARK: - Rendered preview

/// The rendered markdown preview, backed by a read-only NSTextView so it behaves
/// like a real document: Select All (⌘A), drag-selection across blocks, and ⌘C
/// that copies rich text (formatting preserved) to the pasteboard. Content is
/// built by `MarkdownAttributedRenderer`.
struct MarkdownPreview: NSViewRepresentable {
    let text: String
    var baseURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.postsFrameChangedNotifications = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: Theme.minHorizontalInset, height: Theme.verticalInset)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.render(text: text, baseURL: baseURL)
        context.coordinator.startObservingWidth()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.render(text: text, baseURL: baseURL)
    }

    final class Coordinator: NSObject {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        private var renderedText: String?
        private var renderedBase: URL?
        private var frameObserver: NSObjectProtocol?

        deinit {
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        }

        /// Rebuild the attributed content only when the source or base URL changed.
        func render(text: String, baseURL: URL?) {
            guard let textView else { return }
            if renderedText == text && renderedBase == baseURL { return }
            renderedText = text
            renderedBase = baseURL

            let attributed = MarkdownAttributedRenderer.attributedString(from: text, baseURL: baseURL)
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(attributed)
            let length = attributed.length
            if selection.location + selection.length <= length {
                textView.setSelectedRange(selection)
            }
        }

        func startObservingWidth() {
            guard let scrollView else { return }
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.updateMeasure()
            }
            updateMeasure()
        }

        /// Grow the horizontal inset so the rendered column stays centered at the
        /// target measure, matching the source editor.
        func updateMeasure() {
            guard let textView, let scrollView else { return }
            let width = scrollView.contentSize.width
            let inset = max(Theme.minHorizontalInset, (width - Theme.maxMeasure) / 2)
            textView.textContainerInset = NSSize(width: inset, height: Theme.verticalInset)
        }
    }
}

// MARK: - Word count (Liquid Glass)

struct WordCountPill: View {
    let text: String

    private var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    var body: some View {
        Text("\(wordCount) words")
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
    }
}
