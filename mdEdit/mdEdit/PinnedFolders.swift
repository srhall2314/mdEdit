//
//  PinnedFolders.swift
//  mdEdit
//
//  The folders the sidebar keeps around. Pinning is deliberately shallow: a
//  list of paths in UserDefaults, no index, no copy of anything. The sidebar is
//  a view onto the filesystem, so a folder renamed or moved behind our back
//  simply stops resolving — nothing to migrate.
//
//  Plain paths rather than security-scoped bookmarks because the app runs
//  unsandboxed (see the architecture note): there is no scope to re-acquire.
//

import AppKit
import SwiftUI
import Combine
import CoreServices

@MainActor
final class PinnedFolders: ObservableObject {
    static let shared = PinnedFolders()

    private static let storageKey = "sidebar.pinnedFolders"

    @Published private(set) var urls: [URL] = []

    private init() {
        let paths = UserDefaults.standard.array(forKey: Self.storageKey) as? [String] ?? []
        urls = paths.map { URL(filePath: $0).standardizedFileURL }
    }

    func add(_ url: URL) {
        let folder = url.standardizedFileURL
        guard !urls.contains(folder) else { return }
        urls.append(folder)
        persist()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0 == url.standardizedFileURL }
        persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        urls.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Pin folders with the standard Open panel. Multiple selection allowed:
    /// pinning a handful of project folders in one go is the common case.
    func addWithOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders to keep in the sidebar."
        panel.prompt = "Pin"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(url) }
    }

    private func persist() {
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.storageKey)
    }
}

// MARK: - Expansion state

/// Which folders are open, and what's in them. Shared across windows on
/// purpose: opening a file from the sidebar lands you in a new tab, and
/// finding the tree collapsed there would undo the navigation you just did.
@MainActor
final class FolderTree: ObservableObject {
    static let shared = FolderTree()

    @Published private(set) var expanded: Set<URL> = []
    @Published private(set) var children: [URL: [FolderEntry]] = [:]

    private init() {}

    func isExpanded(_ folder: URL) -> Bool { expanded.contains(folder) }

    func toggle(_ folder: URL) {
        if expanded.contains(folder) {
            expanded.remove(folder)
        } else {
            expanded.insert(folder)
            children[folder] = FolderScan.entries(in: folder)
        }
    }

    /// Re-read every folder that's currently showing its contents, and forget
    /// the ones that have gone away. Roots are loaded on first sight so a newly
    /// pinned folder can be expanded straight away.
    func reload(roots: [URL]) {
        for folder in expanded where !FileManager.default.fileExists(atPath: folder.path) {
            expanded.remove(folder)
            children[folder] = nil
        }
        for folder in expanded {
            children[folder] = FolderScan.entries(in: folder)
        }
        for root in roots where children[root] == nil {
            children[root] = FolderScan.entries(in: root)
        }
    }
}

// MARK: - Change notification

/// Watches the pinned folders with FSEvents and bumps a token when anything
/// under them changes. The sidebar reloads expanded folders off that token, so
/// files created outside the app — including ones the AI writes through MCP —
/// show up without a relaunch.
@MainActor
final class FolderWatcher: ObservableObject {
    static let shared = FolderWatcher()

    @Published private(set) var changeToken = 0

    private var stream: FSEventStreamRef?
    private var watched: [URL] = []

    private init() {}

    /// Point the watcher at a set of roots. A no-op when they're unchanged, so
    /// every window can call this on appear without restarting the stream.
    func watch(_ urls: [URL]) {
        guard urls != watched else { return }
        watched = urls
        stop()
        guard !urls.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.changeToken &+= 1 }
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            urls.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4, // coalesce bursts (an AI edit plus its autosave) into one reload
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        // The callback lands on the main queue, which is where the sidebar's
        // @Published token has to change anyway.
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
