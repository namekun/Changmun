import AppKit

/// `Changmun --mcp`: an MCP server over stdio (newline-delimited JSON-RPC) that forwards tool calls
/// to the running app, starting the app first when it isn't running.
enum MCPBridge {
    static func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let reply = handle(message, call: forward) { write(reply) }
        }
        exit(0)
    }

    /// The reply to one message, or nil for notifications. `call` carries out tools/call.
    static func handle(_ message: [String: Any], call: (String, [String: Any]) -> [String: Any]) -> [String: Any]? {
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch message["method"] as? String {
        case "initialize":
            return reply(id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "changmun", "version": "0.1.0"],
                "instructions": headless
                    ? "Tools to see and operate Changmun's headless browser: invisible, with a profile of its own (none of the user's cookies or logins). Anything that looks like paying, ordering, sending, posting or deleting is refused; tell the user instead."
                    : "Tools to see and operate the Changmun web browser the user is using.",
            ])
        case "ping":
            return reply(id, [:])
        case "tools/list":
            return reply(id, ["tools": ToolCatalog.definitions])
        case "tools/call":
            guard let name = params["name"] as? String else { return error(id, -32602, "missing tool name") }
            return reply(id, call(name, params["arguments"] as? [String: Any] ?? [:]))
        default:
            return error(id, -32601, "method not found")
        }
    }

    /// The chat panel names itself; any other client is its own caller for as long as this process runs, under a name no other process
    /// will ever have (a process ID alone comes round again), so what the user allowed it for its chat can't reach a later one.
    static let caller: String = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--caller"), i + 1 < args.count { return args[i + 1] }
        return "mcp-\(getpid())-\(UUID().uuidString)"
    }()

    /// `Changmun --mcp --headless`: the tools of the user's headless Changmun (`changmun headless`), not of the browser in use.
    static let headless = CommandLine.arguments.contains("--headless")

    private static func forward(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        ControlClient.call(name, arguments, caller: caller, headless: headless)
    }

    private static func reply(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

/// Talks to the running app's control server, for the MCP bridge and the command line.
enum ControlClient {
    /// Carries out one tool call in the running app (starting it first if needed) and returns the tool's result.
    /// With `headless`, in the user's headless Changmun (started first when it isn't running) in place of the browser in use.
    static func call(_ name: String, _ arguments: [String: Any], caller: String, headless: Bool = false) -> [String: Any] {
        let found: ControlEndpoint?
        if headless {
            do { found = try UserHeadless.start(from: ownBundle) } catch let error as UserHeadless.Failure {
                return ToolResult.text("The headless Changmun is not running and could not be started: \(error.message)", error: true).json
            } catch {
                return ToolResult.text("The headless Changmun is not running and could not be started: \(error.localizedDescription)", error: true).json
            }
        } else {
            found = ControlEndpoint.read() ?? launchApp()
        }
        guard let endpoint = found else {
            return ToolResult.text("Changmun is not running and could not be started.", error: true).json
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(endpoint.port)/call")!, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue(caller, forHTTPHeaderField: "X-Changmun-Caller")
        if let secret = ProcessInfo.processInfo.environment[ChatStore.panelSecretVariable] {
            request.setValue(secret, forHTTPHeaderField: "X-Changmun-Panel-Secret")
        }
        if let token = ProcessInfo.processInfo.environment[ChatStore.runTokenVariable] {
            request.setValue(token, forHTTPHeaderField: "X-Changmun-Run-Token")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "arguments": arguments])
        var result: [String: Any]?
        var failure = "no response"
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["content"] != nil {
                result = json
            } else {
                failure = error?.localizedDescription ?? "bad response"
            }
            done.signal()
        }.resume()
        done.wait()
        return result ?? ToolResult.text("Could not reach Changmun: \(failure)", error: true).json
    }

    /// The app this binary is in; nil for a bare binary.
    static var ownBundle: URL? {
        let bundle = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return bundle.pathExtension == "app" ? bundle : nil
    }

    private static func launchApp() -> ControlEndpoint? {
        guard let bundle = ownBundle else { return nil }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = Headless.isOn ? ["-g", bundle.path] : [bundle.path]
        try? open.run()
        open.waitUntilExit()
        for _ in 0..<100 {
            if let endpoint = ControlEndpoint.read() { return endpoint }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return nil
    }
}
