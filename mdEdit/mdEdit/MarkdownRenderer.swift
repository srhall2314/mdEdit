//
//  MarkdownRenderer.swift
//  mdEdit
//
//  A native, dependency-free markdown renderer. It leans on Apple's own parser
//  (`AttributedString(markdown:)` with full syntax), which captures block
//  structure as `PresentationIntent` run attributes, then lays those blocks out
//  as real SwiftUI views — headings sized, lists bulleted and indented, code
//  blocks boxed, quotes barred, tables gridded, images loaded. Inline styling
//  (bold/italic/code/strikethrough/links) is rendered by SwiftUI's Text.
//

import SwiftUI
import Foundation

// MARK: - Model

struct MarkdownBlock: Identifiable {
    let id: Int
    let kind: Kind
    let text: AttributedString

    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case unorderedItem(depth: Int)
        case orderedItem(depth: Int, number: Int)
        case codeBlock
        case blockQuote(depth: Int)
        case thematicBreak
        case table(rows: [[AttributedString]], hasHeader: Bool)
        case image(url: URL, alt: String)
    }
}

// MARK: - Parser

enum MarkdownParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let attributed = try? AttributedString(markdown: markdown, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(markdown))]
        }

        // 1. Segment runs into blocks by identical presentation intent.
        var segments: [(intent: PresentationIntent?, text: AttributedString)] = []
        var currentIntent: PresentationIntent?
        var currentText = AttributedString()
        var started = false

        for run in attributed.runs {
            let intent = run.presentationIntent
            if !started || intent != currentIntent {
                if started { segments.append((currentIntent, currentText)) }
                currentIntent = intent
                currentText = AttributedString()
                started = true
            }
            currentText.append(AttributedString(attributed[run.range]))
        }
        if started { segments.append((currentIntent, currentText)) }

        // 2. Classify each segment; coalesce table cells into table blocks.
        var blocks: [MarkdownBlock] = []
        var pendingCells: [(row: Int, column: Int, header: Bool, text: AttributedString)] = []
        var nextID = 0

        func flushTable() {
            guard !pendingCells.isEmpty else { return }
            let hasHeader = pendingCells.contains { $0.header }
            // Preserve row order of first appearance.
            var rowOrder: [Int] = []
            var byRow: [Int: [(Int, AttributedString)]] = [:]
            for cell in pendingCells {
                if byRow[cell.row] == nil { rowOrder.append(cell.row) }
                byRow[cell.row, default: []].append((cell.column, cell.text))
            }
            let rows = rowOrder.map { rowID in
                byRow[rowID]!.sorted { $0.0 < $1.0 }.map { trimmed($0.1) }
            }
            blocks.append(MarkdownBlock(id: nextID, kind: .table(rows: rows, hasHeader: hasHeader), text: AttributedString()))
            nextID += 1
            pendingCells.removeAll()
        }

        for segment in segments {
            let text = trimmed(segment.text)

            if let cell = tableCell(from: segment.intent, text: text) {
                pendingCells.append(cell)
                continue
            }
            flushTable()

            // Lone image paragraph → image block.
            if let image = imageBlock(from: text) {
                blocks.append(MarkdownBlock(id: nextID, kind: image, text: text))
                nextID += 1
                continue
            }

            let kind = classify(segment.intent)
            // Skip empty paragraphs (blank lines between blocks).
            if case .paragraph = kind, text.characters.isEmpty { continue }
            blocks.append(MarkdownBlock(id: nextID, kind: kind, text: text))
            nextID += 1
        }
        flushTable()

        return blocks
    }

    private static func classify(_ intent: PresentationIntent?) -> MarkdownBlock.Kind {
        guard let components = intent?.components else { return .paragraph }

        var listDepth = 0
        var ordered = false
        var ordinal = 1
        var quoteDepth = 0

        for component in components {
            switch component.kind {
            case .header(let level):
                return .heading(level)
            case .codeBlock:
                return .codeBlock
            case .thematicBreak:
                return .thematicBreak
            case .orderedList:
                ordered = true
                listDepth += 1
            case .unorderedList:
                listDepth += 1
            case .listItem(let number):
                ordinal = number
            case .blockQuote:
                quoteDepth += 1
            default:
                break
            }
        }

        if listDepth > 0 {
            return ordered
                ? .orderedItem(depth: listDepth, number: ordinal)
                : .unorderedItem(depth: listDepth)
        }
        if quoteDepth > 0 { return .blockQuote(depth: quoteDepth) }
        return .paragraph
    }

    private static func tableCell(
        from intent: PresentationIntent?,
        text: AttributedString
    ) -> (row: Int, column: Int, header: Bool, text: AttributedString)? {
        guard let components = intent?.components else { return nil }
        var column: Int?
        var rowIdentity: Int?
        var header = false
        for component in components {
            switch component.kind {
            case .tableCell(let columnIndex):
                column = columnIndex
            case .tableHeaderRow:
                header = true
                rowIdentity = component.identity
            case .tableRow:
                rowIdentity = component.identity
            default:
                break
            }
        }
        guard let column, let rowIdentity else { return nil }
        return (rowIdentity, column, header, text)
    }

    private static func imageBlock(from text: AttributedString) -> MarkdownBlock.Kind? {
        for run in text.runs {
            if let url = run.imageURL {
                let alt = String(text.characters)
                return .image(url: url, alt: alt.isEmpty ? "image" : alt)
            }
        }
        return nil
    }

    private static func trimmed(_ input: AttributedString) -> AttributedString {
        var result = input
        while let last = result.characters.last, last.isNewline || last == " " {
            let end = result.endIndex
            let start = result.characters.index(before: end)
            result.removeSubrange(start..<end)
        }
        return result
    }
}

// MARK: - Views

struct MarkdownRenderedView: View {
    let markdown: String
    let baseURL: URL?

    var body: some View {
        let blocks = MarkdownParser.parse(markdown)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block, baseURL: baseURL)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let baseURL: URL?

    var body: some View {
        switch block.kind {
        case .paragraph:
            Text(block.text)
                .font(.system(size: 15))
                .lineSpacing(4)
                .textSelection(.enabled)

        case .heading(let level):
            Text(block.text)
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, level <= 2 ? 8 : 2)
                .textSelection(.enabled)

        case .unorderedItem(let depth):
            listRow(marker: bullet(depth: depth), depth: depth)

        case .orderedItem(let depth, let number):
            listRow(marker: "\(number).", depth: depth)

        case .codeBlock:
            Text(block.text)
                .font(.system(size: 13.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                .clipShape(RoundedRectangle(cornerRadius: 6))

        case .blockQuote(let depth):
            HStack(spacing: 10) {
                ForEach(0..<depth, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 3)
                }
                Text(block.text)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }

        case .thematicBreak:
            Divider().padding(.vertical, 4)

        case .table(let rows, let hasHeader):
            MarkdownTableView(rows: rows, hasHeader: hasHeader)

        case .image(let url, let alt):
            MarkdownImageView(url: url, alt: alt, baseURL: baseURL)
        }
    }

    private func listRow(marker: String, depth: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
            Text(block.text)
                .font(.system(size: 15))
                .lineSpacing(4)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(max(0, depth - 1)) * 22)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 28
        case 2: 22
        case 3: 18
        case 4: 16
        default: 14
        }
    }

    private func bullet(depth: Int) -> String {
        switch depth {
        case 1: "•"
        case 2: "◦"
        default: "▪"
        }
    }
}

private struct MarkdownTableView: View {
    let rows: [[AttributedString]]
    let hasHeader: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                GridRow {
                    ForEach(rows[rowIndex].indices, id: \.self) { colIndex in
                        Text(rows[rowIndex][colIndex])
                            .font(.system(size: 14, weight: hasHeader && rowIndex == 0 ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(Rectangle().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
                    }
                }
                .background(hasHeader && rowIndex == 0 ? Color.secondary.opacity(0.08) : .clear)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)))
    }
}

private struct MarkdownImageView: View {
    let url: URL
    let alt: String
    let baseURL: URL?

    var body: some View {
        let resolved = resolvedURL
        Group {
            if resolved.isFileURL, let image = NSImage(contentsOf: resolved) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                AsyncImage(url: resolved) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: placeholder
                    default: ProgressView()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(alt)
    }

    private var resolvedURL: URL {
        if url.scheme != nil { return url }
        if let baseURL { return URL(fileURLWithPath: url.relativePath, relativeTo: baseURL.deletingLastPathComponent()) }
        return url
    }

    private var placeholder: some View {
        Label(alt, systemImage: "photo")
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
