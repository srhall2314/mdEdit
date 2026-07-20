//
//  main.swift
//  mdedit-mcp
//
//  A thin MCP server over stdio that Claude Desktop launches as a subprocess.
//  It holds no document state of its own: every tool call is forwarded, as
//  newline-delimited JSON, to the running mdEdit app over a local Unix-domain
//  socket, and the app's reply is returned verbatim as the tool result.
//
//  MCP stdio transport = one JSON-RPC 2.0 message per line, both directions.
//

import Foundation

// MARK: - Configuration

let socketPath: String = {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("mdEdit/mcp.sock").path
}()

let protocolVersion = "2025-06-18"

// MARK: - Unix socket client

func connectSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    socketPath.withCString { cstr in
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                _ = strncpy(dst, cstr, capacity - 1)
            }
        }
    }

    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
    }
    if result != 0 {
        close(fd)
        return nil
    }
    return fd
}

/// Launch the mdEdit app (without stealing focus) so a subsequent connect can
/// succeed. `open_file` itself brings the app forward when appropriate.
func launchApp() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let appPath = ProcessInfo.processInfo.environment["MDEDIT_APP_PATH"] {
        process.arguments = ["-g", appPath]
    } else {
        process.arguments = ["-g", "-b", "com.lyr3.mdEdit"]
    }
    try? process.run()
    process.waitUntilExit()
}

func connectOrLaunch() -> Int32? {
    if let fd = connectSocket() { return fd }
    launchApp()
    for _ in 0..<60 { // poll up to ~6s for the app to bind its socket
        usleep(100_000)
        if let fd = connectSocket() { return fd }
    }
    return nil
}

/// Send one request to the app and read its single-line JSON reply.
func roundTrip(_ request: [String: Any]) -> [String: Any] {
    guard var payload = try? JSONSerialization.data(withJSONObject: request) else {
        return ["error": "encode_failed"]
    }
    payload.append(0x0A)

    guard let fd = connectOrLaunch() else { return ["error": "app_unavailable"] }
    defer { close(fd) }

    payload.withUnsafeBytes { raw in
        if let base = raw.baseAddress { _ = write(fd, base, raw.count) }
    }

    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, 4096)
        if n <= 0 { break }
        buffer.append(contentsOf: chunk[0..<n])
        if buffer.contains(0x0A) { break }
    }
    if let newline = buffer.firstIndex(of: 0x0A) {
        buffer = buffer.subdata(in: buffer.startIndex..<newline)
    }
    return (try? JSONSerialization.jsonObject(with: buffer)) as? [String: Any] ?? ["error": "bad_response"]
}

// MARK: - JSON-RPC output

func emit(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

func respond(id: Any?, result: [String: Any]) {
    var message: [String: Any] = ["jsonrpc": "2.0", "result": result]
    if let id { message["id"] = id }
    emit(message)
}

func respondError(id: Any?, code: Int, message text: String) {
    var message: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": text]]
    if let id { message["id"] = id }
    emit(message)
}

// MARK: - Tool definitions

let pathProperty: [String: Any] = ["type": "string", "description": "Absolute path to the file on disk."]

let toolDefinitions: [[String: Any]] = [
    [
        "name": "list_open_files",
        "description": "List the files currently open (live) in mdEdit windows. These are the files that can be edited with cursor/selection awareness.",
        "inputSchema": ["type": "object", "properties": [String: Any]()],
    ],
    [
        "name": "open_file",
        "description": "Open (or focus) an existing file in mdEdit, promoting it to the live tier so it can be edited. The file must already exist; this does not create files.",
        "inputSchema": [
            "type": "object",
            "properties": ["path": pathProperty],
            "required": ["path"],
        ],
    ],
    [
        "name": "read_file",
        "description": "Read a file's contents. For files open in mdEdit, also returns the current revision (needed for edit_file). For files not open, reads directly from disk.",
        "inputSchema": [
            "type": "object",
            "properties": ["path": pathProperty],
            "required": ["path"],
        ],
    ],
    [
        "name": "edit_file",
        "description": "Apply a range-based edit to a file that is open in mdEdit. Replaces the UTF-16 range [start, end) with text (a full replace is start:0, end:length). Requires base_revision from a prior read_file; if the human has typed since, the edit is rejected as stale. If the file is not open, returns {\"error\":\"not_open\"} — call open_file first, then retry.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "path": pathProperty,
                "edit": [
                    "type": "object",
                    "description": "A range replacement using UTF-16 offsets.",
                    "properties": [
                        "start": ["type": "integer", "description": "UTF-16 offset where the replacement begins."],
                        "end": ["type": "integer", "description": "UTF-16 offset where the replacement ends (start == end inserts)."],
                        "text": ["type": "string", "description": "Replacement text."],
                    ],
                    "required": ["start", "end", "text"],
                ],
                "base_revision": ["type": "integer", "description": "The revision returned by the most recent read_file of this open file."],
            ],
            "required": ["path", "edit", "base_revision"],
        ],
    ],
    [
        "name": "get_selection",
        "description": "Get the current cursor/selection (UTF-16 start and end, plus selected text) for a file open in mdEdit.",
        "inputSchema": [
            "type": "object",
            "properties": ["path": pathProperty],
            "required": ["path"],
        ],
    ],
]

// MARK: - Tool dispatch

/// Transport-level failures are surfaced as MCP tool errors; structured control
/// responses (not_open, stale, not_found) are passed through so the model can
/// self-correct.
let transportErrors: Set<String> = ["app_unavailable", "bad_response", "encode_failed"]

func handleToolCall(id: Any?, name: String, arguments: [String: Any]) {
    var request = arguments
    request["op"] = name
    let appResponse = roundTrip(request)

    let text = String(
        data: (try? JSONSerialization.data(withJSONObject: appResponse)) ?? Data("{}".utf8),
        encoding: .utf8
    ) ?? "{}"

    let isError = (appResponse["error"] as? String).map(transportErrors.contains) ?? false

    respond(id: id, result: [
        "content": [["type": "text", "text": text]],
        "isError": isError,
    ])
}

func initializeResult(params: [String: Any]?) -> [String: Any] {
    let requested = params?["protocolVersion"] as? String
    return [
        "protocolVersion": requested ?? protocolVersion,
        "capabilities": ["tools": [String: Any]()],
        "serverInfo": ["name": "mdedit-mcp", "version": "0.1.0"],
    ]
}

// MARK: - Main loop

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard
        let data = line.data(using: .utf8),
        let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let method = message["method"] as? String
    else { continue }

    let id = message["id"] // NSNumber or String; nil for notifications

    switch method {
    case "initialize":
        respond(id: id, result: initializeResult(params: message["params"] as? [String: Any]))
    case "notifications/initialized", "notifications/cancelled":
        break // notifications get no reply
    case "ping":
        respond(id: id, result: [String: Any]())
    case "tools/list":
        respond(id: id, result: ["tools": toolDefinitions])
    case "tools/call":
        let params = message["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        handleToolCall(id: id, name: name, arguments: arguments)
    default:
        if id != nil {
            respondError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }
}
