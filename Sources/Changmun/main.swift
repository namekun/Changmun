import AppKit

signal(SIGPIPE, SIG_IGN)

// `Changmun --mcp` is the MCP server an AI agent starts; it forwards tool calls to the running app.
if CommandLine.arguments.contains("--mcp") {
    MCPBridge.run()
}
// `Changmun --cli …` (the `changmun` command): one tool call from a shell.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--cli" {
    CLI.run(Array(CommandLine.arguments.dropFirst(2)))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(Headless.isOn ? .prohibited : .regular)
    app.run()
}
