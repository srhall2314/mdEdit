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
        unlink(Self.socketURL.path)
    }

    // MARK: Accept loop

    private func run() {
        let url = Self.socketURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let path = url.path
        unlink(path) // clear any stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("mdEdit MCP: socket() failed (\(errno))")
            return
        }

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
        NSLog("mdEdit MCP: listening at \(path)")

        while running {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if running { continue } else { break }
            }
            handleConnection(client)
        }
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
