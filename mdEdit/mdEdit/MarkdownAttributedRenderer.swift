//
//  MarkdownAttributedRenderer.swift
//  mdEdit
//
//  Renders parsed markdown blocks into a single `NSAttributedString` for the
//  preview's read-only NSTextView. Going through an attributed string (instead
//  of per-block SwiftUI `Text` views) is what makes the preview behave like a
//  real document: Select All, drag-selection across blocks, and ⌘C that writes
//  rich text (RTF/HTML) to the pasteboard so formatting survives a paste into
//  Mail, Pages, Notes, etc.
//
//  It reuses `MarkdownParser.parse` for block structure and inline intents, then
//  translates each block's typography into concrete fonts, colors, paragraph
//  styles, table blocks, and image attachments.
//

import AppKit
import Foundation

enum MarkdownAttributedRenderer {

    // MARK: - Entry point

    static func attributedString(from markdown: String, baseURL: URL?) -> NSAttributedString {
        let blocks = MarkdownParser.parse(markdown)
        let out = NSMutableAttributedString()

        for block in blocks {
            switch block.kind {
            case .paragraph:
                append(paragraph: block.text, to: out)
            case .heading(let level):
                append(heading: block.text, level: level, to: out)
            case .unorderedItem(let depth):
                append(listItem: block.text, marker: bullet(depth: depth), depth: depth, to: out)
            case .orderedItem(let depth, let number):
                append(listItem: block.text, marker: "\(number).", depth: depth, to: out)
            case .codeBlock:
                append(codeBlock: block.text, to: out)
            case .blockQuote(let depth):
                append(blockQuote: block.text, depth: depth, to: out)
            case .thematicBreak:
                appendThematicBreak(to: out)
            case .table(let rows, let hasHeader):
                append(tableRows: rows, hasHeader: hasHeader, to: out)
            case .image(let url, let alt):
                append(imageURL: url, alt: alt, baseURL: baseURL, to: out)
            }
        }

        return out
    }

    // MARK: - Block builders

    private static func append(paragraph text: AttributedString, to out: NSMutableAttributedString) {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 4
        ps.paragraphSpacing = 12
        appendPiece(styledInline(text, baseFont: bodyFont(15), baseColor: .labelColor), paragraphStyle: ps, to: out)
    }

    private static func append(heading text: AttributedString, level: Int, to out: NSMutableAttributedString) {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 2
        ps.paragraphSpacing = 8
        ps.paragraphSpacingBefore = level <= 2 ? 12 : 6
        let font = NSFont.systemFont(ofSize: headingSize(level), weight: .semibold)
        appendPiece(styledInline(text, baseFont: font, baseColor: .labelColor), paragraphStyle: ps, to: out)
    }

    private static func append(listItem text: AttributedString, marker: String, depth: Int, to out: NSMutableAttributedString) {
        let indent = CGFloat(depth) * 22
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 4
        ps.paragraphSpacing = 6
        ps.firstLineHeadIndent = indent - 18
        ps.headIndent = indent
        ps.tabStops = [NSTextTab(textAlignment: .left, location: indent)]

        let piece = NSMutableAttributedString()
        piece.append(NSAttributedString(string: "\(marker)\t", attributes: [
            .font: bodyFont(15),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        piece.append(styledInline(text, baseFont: bodyFont(15), baseColor: .labelColor))
        appendPiece(piece, paragraphStyle: ps, to: out)
    }

    private static func append(codeBlock text: AttributedString, to out: NSMutableAttributedString) {
        let ps = NSMutableParagraphStyle()
        ps.firstLineHeadIndent = 10
        ps.headIndent = 10
        ps.tailIndent = -10
        ps.lineSpacing = 2
        ps.paragraphSpacing = 12
        ps.paragraphSpacingBefore = 2

        let piece = NSMutableAttributedString(attributedString:
            styledInline(text, baseFont: monoFont(13.5), baseColor: .labelColor))
        piece.addAttribute(.backgroundColor, value: codeBackground,
                           range: NSRange(location: 0, length: piece.length))
        appendPiece(piece, paragraphStyle: ps, to: out, background: codeBackground)
    }

    private static func append(blockQuote text: AttributedString, depth: Int, to out: NSMutableAttributedString) {
        let indent = CGFloat(depth) * 18
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 4
        ps.paragraphSpacing = 12
        ps.firstLineHeadIndent = indent
        ps.headIndent = indent
        appendPiece(styledInline(text, baseFont: bodyFont(15), baseColor: .secondaryLabelColor),
                    paragraphStyle: ps, to: out)
    }

    private static func appendThematicBreak(to out: NSMutableAttributedString) {
        // A strikethrough drawn across a full-width tab reads as a horizontal rule.
        let ps = NSMutableParagraphStyle()
        ps.tabStops = [NSTextTab(textAlignment: .right, location: Theme.maxMeasure)]
        ps.paragraphSpacing = 10
        ps.paragraphSpacingBefore = 10
        out.append(NSAttributedString(string: "\t\n", attributes: [
            .paragraphStyle: ps,
            .font: NSFont.systemFont(ofSize: 8),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: NSColor.separatorColor,
        ]))
    }

    private static func append(tableRows rows: [[AttributedString]], hasHeader: Bool, to out: NSMutableAttributedString) {
        guard let columns = rows.map(\.count).max(), columns > 0 else { return }
        let table = NSTextTable()
        table.numberOfColumns = columns

        for (r, row) in rows.enumerated() {
            let isHeader = hasHeader && r == 0
            for c in 0..<columns {
                let cellText = c < row.count ? row[c] : AttributedString("")
                let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1,
                                            startingColumn: c, columnSpan: 1)
                cell.setBorderColor(.separatorColor)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setWidth(7, type: .absoluteValueType, for: .padding)
                if isHeader { cell.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08) }

                let ps = NSMutableParagraphStyle()
                ps.textBlocks = [cell]

                let font = isHeader ? NSFont.systemFont(ofSize: 14, weight: .semibold) : bodyFont(14)
                let piece = NSMutableAttributedString(attributedString:
                    styledInline(cellText, baseFont: font, baseColor: .labelColor))
                piece.append(NSAttributedString(string: "\n"))
                piece.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: piece.length))
                out.append(piece)
            }
        }

        // Close the table region and add breathing room before the next block.
        let after = NSMutableParagraphStyle()
        after.paragraphSpacing = 12
        out.append(NSAttributedString(string: "\n", attributes: [
            .paragraphStyle: after,
            .font: NSFont.systemFont(ofSize: 4),
        ]))
    }

    private static func append(imageURL url: URL, alt: String, baseURL: URL?, to out: NSMutableAttributedString) {
        let resolved = resolve(url: url, baseURL: baseURL)
        let ps = NSMutableParagraphStyle()
        ps.paragraphSpacing = 12

        if resolved.isFileURL, let image = NSImage(contentsOf: resolved) {
            image.accessibilityDescription = alt
            let attachment = NSTextAttachment()
            attachment.image = image
            // Scale down to the measure width while preserving aspect ratio.
            let size = image.size
            if size.width > Theme.maxMeasure, size.width > 0 {
                let scale = Theme.maxMeasure / size.width
                attachment.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
            }
            let piece = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
            piece.append(NSAttributedString(string: "\n"))
            piece.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: piece.length))
            out.append(piece)
        } else {
            // Remote images aren't loaded synchronously; show the alt text as a link.
            let piece = NSMutableAttributedString(string: "🖼 \(alt)", attributes: [
                .font: bodyFont(15),
                .foregroundColor: NSColor.secondaryLabelColor,
                .link: resolved,
                .paragraphStyle: ps,
            ])
            piece.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: ps]))
            out.append(piece)
        }
    }

    // MARK: - Inline styling

    /// Translate an inline `AttributedString`'s presentation intents into concrete
    /// fonts, colors, strikethrough, and links over a block's base font.
    private static func styledInline(_ attributed: AttributedString, baseFont: NSFont, baseColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()

        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            guard !text.isEmpty else { continue }

            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? monoFont(baseFont.pointSize - 1.5) : baseFont

            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty { font = font.applying(traits: traits) }

            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: baseColor,
            ]
            if intent.contains(.code) { attrs[.backgroundColor] = codeBackground }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = NSColor.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }

            result.append(NSAttributedString(string: text, attributes: attrs))
        }

        return result
    }

    // MARK: - Helpers

    /// Append a block's content plus a trailing newline, applying the paragraph
    /// style (and optional background) across the whole run so spacing and boxes
    /// cover the line break too.
    private static func appendPiece(_ piece: NSAttributedString, paragraphStyle: NSParagraphStyle,
                                    to out: NSMutableAttributedString, background: NSColor? = nil) {
        let mutable = NSMutableAttributedString(attributedString: piece)
        mutable.append(NSAttributedString(string: "\n"))
        let full = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.paragraphStyle, value: paragraphStyle, range: full)
        if let background { mutable.addAttribute(.backgroundColor, value: background, range: full) }
        out.append(mutable)
    }

    private static func resolve(url: URL, baseURL: URL?) -> URL {
        if url.scheme != nil { return url }
        if let baseURL {
            return URL(fileURLWithPath: url.relativePath, relativeTo: baseURL.deletingLastPathComponent())
        }
        return url
    }

    private static func bodyFont(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size) }
    private static func monoFont(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }

    private static var codeBackground: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.12) }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 28
        case 2: 22
        case 3: 18
        case 4: 16
        default: 14
        }
    }

    private static func bullet(depth: Int) -> String {
        switch depth {
        case 1: "•"
        case 2: "◦"
        default: "▪"
        }
    }
}

private extension NSFont {
    func applying(traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
