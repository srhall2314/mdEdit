//
//  AppDelegate.swift
//  mdEdit
//
//  Owns process-wide services that outlive any single window — currently the
//  MCP endpoint (a local Unix-socket server backed by the document registry).
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mcpServer = MCPSocketServer(registry: .shared)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Persist edits (human or AI) to disk promptly, so the working tree on
        // disk stays close to the live buffer during a tight editing loop.
        NSDocumentController.shared.autosavingDelay = 3
        mcpServer.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        mcpServer.stop()
    }
}
