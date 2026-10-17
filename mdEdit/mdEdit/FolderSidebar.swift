//
//  FolderSidebar.swift
//  mdEdit
//
//  A collapsible sidebar listing the pinned folders and the markdown inside
//  them. Clicking a file opens it as an ordinary document — same editor, same
//  autosave, same MCP addressability — so the sidebar is pure navigation and
//  owns no document state of its own.
//
//  The tree is kept as a flat list of visible rows plus a set of expanded
//  folders rather than nested views: it keeps List selection working on one
//  level, and it makes a reload after an external change a single pass.
//

import AppKit
import SwiftUI

struct FolderEntry: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum FolderScan {
    /// What counts as openable here. Matches what the document types claim, so
    /// nothing in the sidebar can be clicked into an error.
    static let readableExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt", "text"]

    static func entries(in folder: URL) -> [FolderEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let entries: [FolderEntry] = items.compactMap { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            // Packages (.app, .rtfd) are directories but behave like files —
            // descending into them is never what you meant.
            if values?.isPackage == true { return nil }
            if values?.isDirectory == true { return FolderEntry(url: item, isDirectory: true) }
            guard readableExtensions.contains(item.pathExtension.lowercased()) else { return nil }
            return FolderEntry(url: item, isDirectory: false)
        }

        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

struct FolderSidebar: View {
    /// The document showing in this window, so its row reads as selected.
    let currentFileURL: URL?

    @ObservedObject private var pinned = PinnedFolders.shared
    @ObservedObject private var watcher = FolderWatcher.shared
    @ObservedObject private var tree = FolderTree.shared

    @State private var selection: URL?

    private struct Row: Identifiable, Hashable {
        let entry: FolderEntry
        let depth: Int
        let isRoot: Bool

        var id: URL { entry.url }
    }

    var body: some View {
        Group {
            if pinned.urls.isEmpty {
                emptyState
            } else {
                treeList
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !pinned.urls.isEmpty { addFolderBar }
        }
        .onAppear {
            watcher.watch(pinned.urls)
            selection = currentFileURL
            reloadExpanded()
        }
        .onChange(of: pinned.urls) { _, now in
            watcher.watch(now)
            reloadExpanded()
        }
        .onChange(of: watcher.changeToken) { _, _ in
            reloadExpanded()
        }
        .onChange(of: currentFileURL) { _, now in
            selection = now
        }
        .onChange(of: selection) { _, now in
            // Selecting a file opens it; reflecting the window's own document
            // back into the list must not re-open anything.
            guard let now, now != currentFileURL else { return }
            NSDocumentController.shared.openDocument(withContentsOf: now, display: true) { _, _, _ in }
        }
    }

    // MARK: Tree

    private var treeList: some View {
        List(selection: $selection) {
            ForEach(rows) { row in
                rowView(row)
            }
        }
        .listStyle(.sidebar)
    }

    /// Flatten the pinned roots and their expanded descendants, depth-first.
    private var rows: [Row] {
        var result: [Row] = []
        for root in pinned.urls {
            result.append(Row(entry: FolderEntry(url: root, isDirectory: true), depth: 0, isRoot: true))
            append(childrenOf: root, depth: 1, into: &result)
        }
        return result
    }

    private func append(childrenOf folder: URL, depth: Int, into result: inout [Row]) {
        guard tree.isExpanded(folder) else { return }
        for entry in tree.children[folder] ?? [] {
            result.append(Row(entry: entry, depth: depth, isRoot: false))
            if entry.isDirectory {
                append(childrenOf: entry.url, depth: depth + 1, into: &result)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let entry = row.entry
        HStack(spacing: 4) {
            if entry.isDirectory {
                Button {
                    tree.toggle(entry.url)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(tree.isExpanded(entry.url) ? 90 : 0))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 12)
            }

            Label {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: entry.isDirectory ? "folder" : "doc.text")
            }
            .font(row.isRoot ? .body.weight(.medium) : .body)
        }
        .padding(.leading, CGFloat(row.depth) * 12)
        .tag(entry.url)
        .contextMenu {
            if entry.isDirectory {
                Button(tree.isExpanded(entry.url) ? "Collapse" : "Expand") { tree.toggle(entry.url) }
            } else {
                Button("Open") {
                    NSDocumentController.shared.openDocument(withContentsOf: entry.url, display: true) { _, _, _ in }
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
            if row.isRoot {
                Divider()
                Button("Unpin Folder") { pinned.remove(entry.url) }
            }
        }
    }

    // MARK: Chrome

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No Pinned Folders")
                .font(.headline)
            Text("Pin the folders you write in to keep them one click away.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Folder…") { pinned.addWithOpenPanel() }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var addFolderBar: some View {
        HStack {
            Button {
                pinned.addWithOpenPanel()
            } label: {
                Label("Add Folder…", systemImage: "plus")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func reloadExpanded() {
        tree.reload(roots: pinned.urls)
    }
}
