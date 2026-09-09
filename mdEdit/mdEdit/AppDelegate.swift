//
//  AppDelegate.swift
//  mdEdit
//
//  Owns process-wide services that outlive any single window — the MCP
//  endpoint (a local Unix-socket server backed by the document registry) and
//  the scratchpad, which the app keeps on disk and opens on every launch.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mcpServer = MCPSocketServer(registry: .shared)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Persist edits (human or AI) to disk promptly, so the working tree on
        // disk stays close to the live buffer during a tight editing loop.
        NSDocumentController.shared.autosavingDelay = 3
        mcpServer.start()
        Scratchpad.openOrFocus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        mcpServer.stop()
    }

    /// Launching with nothing to restore lands on the scratchpad, not on a new
    /// Untitled document — otherwise every launch opens two tabs and one of
    /// them is the throwaway the scratchpad exists to replace.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with every window closed brings the scratchpad
    /// back, for the same reason.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Scratchpad.openOrFocus() }
        return true
    }
}
