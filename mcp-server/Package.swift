// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mdedit-mcp",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // The stdio ↔ Unix-socket bridge that Claude Desktop launches. It owns
        // no document state; it forwards MCP tool calls to the running mdEdit app.
        .executableTarget(
            name: "mdedit-mcp"
        )
    ]
)
