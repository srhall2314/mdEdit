//
//  MarkdownHelp.swift
//  mdEdit
//
//  A live markdown cheat sheet: each entry shows the literal syntax next to its
//  rendered result, produced by the app's own renderer — so the Help window is
//  always faithful to what Preview actually does.
//

import SwiftUI

struct MarkdownHelpItem: Identifiable {
    let id = UUID()
    let syntax: String
}

struct MarkdownHelpSection: Identifiable {
    let id = UUID()
    let title: String
    let items: [MarkdownHelpItem]
}

enum MarkdownHelpContent {
    static let sections: [MarkdownHelpSection] = [
        MarkdownHelpSection(title: "Headings", items: [
            .init(syntax: "# Heading 1"),
            .init(syntax: "## Heading 2"),
            .init(syntax: "### Heading 3"),
        ]),
        MarkdownHelpSection(title: "Emphasis", items: [
            .init(syntax: "**bold**"),
            .init(syntax: "*italic*"),
            .init(syntax: "***bold italic***"),
            .init(syntax: "~~strikethrough~~"),
            .init(syntax: "`inline code`"),
        ]),
        MarkdownHelpSection(title: "Lists", items: [
            .init(syntax: "- First item\n- Second item"),
            .init(syntax: "1. First\n2. Second"),
            .init(syntax: "- Item\n    - Nested item"),
        ]),
        MarkdownHelpSection(title: "Links & Images", items: [
            .init(syntax: "[link text](https://example.com)"),
            .init(syntax: "![alt text](image.png)"),
        ]),
        MarkdownHelpSection(title: "Code", items: [
            .init(syntax: "```\nlet code = true\n```"),
        ]),
        MarkdownHelpSection(title: "Quotes", items: [
            .init(syntax: "> A block quote"),
        ]),
        MarkdownHelpSection(title: "Tables", items: [
            .init(syntax: "| Name | Role |\n| --- | --- |\n| Ada | Engineer |"),
        ]),
        MarkdownHelpSection(title: "Rules", items: [
            .init(syntax: "---"),
        ]),
    ]
}

struct MarkdownHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(MarkdownHelpContent.sections) { section in
                    VStack(alignment: .leading, spacing: 14) {
                        Text(section.title)
                            .font(.title3.weight(.semibold))
                        ForEach(section.items) { item in
                            HStack(alignment: .top, spacing: 20) {
                                Text(item.syntax)
                                    .font(.system(size: 13, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(width: 240, alignment: .leading)
                                    .padding(10)
                                    .background(Color.secondary.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                MarkdownRenderedView(markdown: item.syntax, baseURL: nil)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Divider()
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Markdown Syntax")
    }
}
