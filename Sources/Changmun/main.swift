import AppKit

signal(SIGPIPE, SIG_IGN)

// `Changmun --mcp` is the MCP server an AI agent starts; it forwards tool calls to the running app.
// `Changmun --cli …` (the `changmun` command): one tool call from a shell. Only the first argument says which.
switch CLI.LaunchMode.of(CommandLine.arguments) {
case .mcp: MCPBridge.run()
case .cli: CLI.run(Array(CommandLine.arguments.dropFirst(2)))
case .app: break
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(Headless.isOn ? .prohibited : .regular)
    app.run()
}
