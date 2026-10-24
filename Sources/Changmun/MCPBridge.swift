import AppKit

/// `Changmun --mcp`: an MCP server over stdio (newline-delimited JSON-RPC) that forwards tool calls
/// to the running app, starting the app first when it isn't running.
enum MCPBridge {
    static func run() -> Never {
        let session = MCPSession(call: forward) { write($0) }
        while let line = readLine(strippingNewline: true) { session.receive(line) }
        // The client closed its end: the calls under way get a few seconds to answer, not their full 120.
        session.finish(timeout: 10)
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

    static func error(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        // Nobody reads our output any more: nothing left to serve.
        if !write(data, to: .standardOutput) { exit(0) }
    }

    /// Writes without raising: a closed pipe is an error to return (the ObjC `write(_:)` throws an exception that kills the process).
    static func write(_ data: Data, to handle: FileHandle) -> Bool {
        do { try handle.write(contentsOf: data); return true } catch { return false }
    }
}

/// One MCP connection: the lines the client sends, and the replies. A tool call can take minutes, so calls run side by side and
/// every reply carries its request's id, in the order they finish; everything else (ping, initialize, tools/list) is answered
/// at once, even while a call is under way. Replies are written one at a time, so lines never interleave.
final class MCPSession: @unchecked Sendable {
    typealias Call = (String, [String: Any]) -> [String: Any]

    private let call: Call
    private let send: ([String: Any]) -> Void
    private let writes = DispatchQueue(label: "changmun.mcp.write")
    private let calls = DispatchQueue(label: "changmun.mcp.calls", attributes: .concurrent)
    private let running = DispatchGroup()

    init(call: @escaping Call, send: @escaping ([String: Any]) -> Void) {
        self.call = call
        self.send = send
    }

    /// Handles one line of input.
    func receive(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            return reply(MCPBridge.error(NSNull(), -32700, "parse error: not JSON"))
        }
        guard let message = json as? [String: Any] else {
            return reply(MCPBridge.error(NSNull(), -32600, json is [Any] ? "batches are not supported: send one message per line" : "a message is a JSON object"))
        }
        guard let method = message["method"] as? String else {
            // The client's answer to a request of ours (we send none), or no message at all.
            if message["id"] != nil, message["result"] != nil || message["error"] != nil { return }
            return reply(MCPBridge.error(message["id"] ?? NSNull(), -32600, "invalid request: no method"))
        }
        guard method == "tools/call", message["id"] != nil else {
            if let answer = MCPBridge.handle(message, call: call) { reply(answer) }
            return
        }
        running.enter()
        calls.async {
            defer { self.running.leave() }
            if let answer = MCPBridge.handle(message, call: self.call) { self.reply(answer) }
        }
    }

    /// Waits for the calls under way (at most `timeout` seconds) and for their replies to be written.
    func finish(timeout: TimeInterval) {
        _ = running.wait(timeout: .now() + timeout)
        writes.sync {}
    }

    private func reply(_ message: [String: Any]) {
        writes.async { self.send(message) }
    }
}

/// Talks to the running app's control server, for the MCP bridge and the command line.
enum ControlClient {
    /// Carries out one tool call in the running app (starting it first if needed) and returns the tool's result.
    /// With `headless`, in the user's headless Changmun (started first when it isn't running) in place of the browser in use.
    static func call(_ name: String, _ arguments: [String: Any], caller: String, headless: Bool = false) -> [String: Any] {
        let found: ControlEndpoint?
        // Whether the endpoint comes from an app that was already running (its file), and so may be a stale one.
        let fromFile = !headless && ControlEndpoint.read() != nil
        if headless {
            do { found = try UserHeadless.start(from: ownBundle); _ = staleHeadlessNotice } catch let error as UserHeadless.Failure {
                return ToolResult.text("The headless Changmun is not running and could not be started: \(error.message)", error: true).json
            } catch {
                return ToolResult.text("The headless Changmun is not running and could not be started: \(error.localizedDescription)", error: true).json
            }
        } else {
            found = endpoint(caller: caller, read: { ControlEndpoint.read() }, launch: launchApp)
        }
        guard let endpoint = found else {
            return ToolResult.text("Changmun is not running and could not be started.", error: true).json
        }
        var outcome = perform(name, arguments, caller: caller, to: endpoint)
        if fromFile {
            if case .refused = outcome {
                // Nobody listens: the app that wrote the file is gone (a crash leaves it behind). Start it once more.
                try? FileManager.default.removeItem(at: ControlEndpoint.file)
                if let again = Self.endpoint(caller: caller, read: { nil }, launch: launchApp) { outcome = perform(name, arguments, caller: caller, to: again) }
            } else if case .unauthorized = outcome, let again = ControlEndpoint.read(), again.token != endpoint.token {
                // The app was restarted after the file was read.
                outcome = perform(name, arguments, caller: caller, to: again)
            }
        }
        switch outcome {
        case .result(let result): return result
        case .refused(let failure), .failed(let failure): return ToolResult.text("Could not reach Changmun: \(failure)", error: true).json
        case .unauthorized: return ToolResult.text("Could not reach Changmun: \(failure(status: 401, error: nil))", error: true).json
        }
    }

    enum Outcome {
        case result([String: Any])
        /// Nothing listens at the endpoint's port.
        case refused(String)
        /// The app doesn't take the endpoint's token.
        case unauthorized
        case failed(String)
    }

    /// One tool call to the app at `endpoint`.
    static func perform(_ name: String, _ arguments: [String: Any], caller: String, to endpoint: ControlEndpoint) -> Outcome {
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
        // The server answers 413 without reading the body, which the client sees as a dropped connection: say it here.
        if let body = request.httpBody, body.count > HTTPRequest.maxBody { return .failed(failure(status: 413, error: nil)) }
        var outcome = Outcome.failed("no response")
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["content"] != nil {
                outcome = .result(json)
            } else if (error as? URLError)?.code == .cannotConnectToHost {
                outcome = .refused(error?.localizedDescription ?? "connection refused")
            } else if status == 401 {
                outcome = .unauthorized
            } else {
                outcome = .failed(failure(status: status, error: error))
            }
            done.signal()
        }.resume()
        done.wait()
        return outcome
    }

    /// Where the app listens. The chat panel's own bridge never starts the app: it runs for the panel's AI, and if the app is gone
    /// (the user quit it) a tool call that comes late must not bring it back.
    static func endpoint(caller: String, read: () -> ControlEndpoint?, launch: () -> ControlEndpoint?) -> ControlEndpoint? {
        read() ?? (caller == ChatStore.caller ? nil : launch())
    }

    /// Why a call that got no tool result failed: what the control server said (it answers with a status and no result when it
    /// turns a request away), or else what went wrong on the way.
    static func failure(status: Int?, error: Error?) -> String {
        switch status {
        case 401?: return "Changmun didn't accept the access token (HTTP 401): the app was restarted, or this isn't the app that wrote control.json; try again"
        case 413?: return "the request is too large for Changmun (HTTP 413: at most \(HTTPRequest.maxBody / (1 << 20)) MB)"
        case let status? where status != 200: return "Changmun answered HTTP \(status)"
        default: return error?.localizedDescription ?? "bad response"
        }
    }

    /// `--mcp --headless` is served by the copy that is running, which keeps running as it was when the installed app is updated:
    /// said once, on stderr (stdout is the protocol).
    private static let staleHeadlessNotice: Void = {
        guard let hint = UserHeadless.updateHint(installed: ownBundle.flatMap(UserHeadless.info(ofApp:)), installedApp: ownBundle, running: true) else { return }
        FileHandle.standardError.write(Data("changmun: \(hint)\n".utf8))
    }()

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
