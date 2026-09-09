//
//  MCPSocketServer.swift
//  mdEdit
//
//  A tiny local Unix-domain socket server. The `mdedit-mcp` stdio bridge (the
//  process Claude Desktop launches) connects here and forwards tool calls as
//  newline-delimited JSON. Each request is dispatched onto the main actor and
//  executed against the live document registry, then the JSON reply is written
//  back on the same connection.
//
//  This is intentionally minimal POSIX socket code: one background queue runs
//  the accept loop, connections are handled inline, and per-request work hops
//  to the main thread. Personal, single-user, localhost-only — no auth layer.
//

import Foundation

final class MCPSocketServer: @unchecked Sendable {
    private let registry: DocumentRegistry
    private let queue = DispatchQueue(label: "com.lyr3.mdEdit.mcp-socket")
    private var listenFD: Int32 = -1
    private var running = false
    /// Identity (device + inode) of the socket file this process created, so
    /// shutdown only removes its own — never one another instance has since
    /// put in its place.
    private var ownedNode: (dev: dev_t, ino: ino_t)?

    init(registry: DocumentRegistry) {
        self.registry = registry
    }

    /// The well-known socket path, shared with the mdedit-mcp bridge.
    static var socketURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("mdEdit/mcp.sock")
    }

    func start() {
        queue.async { [weak self] in self?.run() }
    }

    func stop() {
        running = false
        if listenFD >= 0 { close(listenFD) }

        // Only remove the socket file if it's still the one we bound. An
        // instance that never bound (or whose file has been replaced) must
        // leave the path alone: unlinking it here would cut off whichever
        // instance is actually serving, and it would do so silently — that
        // process keeps a listening fd on an inode nothing can reach any more.
        guard let owned = ownedNode else { return }
        var info = stat()
        guard stat(Self.socketURL.path, &info) == 0,
              info.st_dev == owned.dev,
              info.st_ino == owned.ino else { return }
        unlink(Self.socketURL.path)
        ownedNode = nil
    }

    // MARK: Accept loop

    private func run() {
        let url = Self.socketURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let path = url.path

        // The path is shared by every mdEdit instance, so it may already be in
        // use — commonly a Debug build running alongside the installed app.
        // Probe before touching it: a socket that accepts a connection belongs
        // to a live instance and is not ours to replace. Only a socket left
        // behind by a process that died without cleaning up gets cleared.
        if FileManager.default.fileExists(atPath: path) {
            guard !Self.isLive(path: path) else {
                NSLog("mdEdit MCP: another instance is already listening at \(path) — this one will not serve MCP")
                return
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("mdEdit MCP: socket() failed (\(errno))")
            return
        }

        var addr = Self.address(for: path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            NSLog("mdEdit MCP: bind() failed (\(errno)) at \(path)")
            close(fd)
            return
        }
        guard listen(fd, 8) == 0 else {
            NSLog("mdEdit MCP: listen() failed (\(errno))")
            close(fd)
            return
        }

        listenFD = fd
        running = true
        var info = stat()
        if stat(path, &info) == 0 { ownedNode = (info.st_dev, info.st_ino) }
        NSLog("mdEdit MCP: listening at \(path)")

        while running {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if running { continue } else { break }
            }
            handleConnection(client)
        }
    }

    // MARK: Socket helpers

    /// Fill a `sockaddr_un` for a filesystem path.
    private static func address(for path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                    _ = strncpy(dst, cstr, capacity - 1)
                }
            }
        }
        return addr
    }

    /// Is something accepting connections at `path` right now? A socket file
    /// orphaned by a killed process refuses the connection (ECONNREFUSED); a
    /// live listener accepts it.
    private static func isLive(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = address(for: path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        return connected == 0
    }

    // MARK: Per-connection request loop

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        let chunkSize = 4096
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        while running {
            let n = read(fd, &chunk, chunkSize)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])

            // Process every complete newline-delimited request in the buffer.
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                var response = dispatch(line)
                response.append(0x0A)
                response.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        _ = write(fd, base, raw.count)
                    }
                }
            }
        }
    }

    /// Decode one request line, run it on the main actor, and encode the reply.
    private func dispatch(_ line: Data) -> Data {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let op = object["op"] as? String
        else {
            return Self.encode(["error": "bad_request"])
        }

        var result: [String: Any] = [:]
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                result = self.registry.handle(op: op, args: object)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return Self.encode(result)
    }

    private static func encode(_ dictionary: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dictionary)) ?? Data("{\"error\":\"encode_failed\"}".utf8)
    }
}
