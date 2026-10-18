import AppKit

signal(SIGPIPE, SIG_IGN)

// `Changmun --mcp` is the MCP server an AI agent starts; it forwards tool calls to the running app.
if CommandLine.arguments.contains("--mcp") {
    MCPBridge.run()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(Headless.isOn ? .prohibited : .regular)
    app.run()
}
