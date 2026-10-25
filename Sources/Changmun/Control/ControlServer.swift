import AppKit
import Foundation
import Network

/// Where the running app's control server listens, written for `Changmun --mcp` to find.
struct ControlEndpoint: Codable {
    var port: UInt16
    var token: String
    var pid: Int32

    static var file: URL { Library.folder.appendingPathComponent("control.json") }

    static func read(file: URL = file) -> ControlEndpoint? {
        guard let data = try? Data(contentsOf: file), let endpoint = try? JSONDecoder().decode(ControlEndpoint.self, from: data),
              isChangmun(pid: endpoint.pid) else { return nil }
        return endpoint
    }

    /// Deletes the file if it still holds `endpoint`'s token and port: an app that restarts rewrites it within a second, and
    /// that new file must not go with the old one.
    static func remove(ifHolding endpoint: ControlEndpoint, file: URL = file) {
        guard let data = try? Data(contentsOf: file), let current = try? JSONDecoder().decode(ControlEndpoint.self, from: data),
              current.token == endpoint.token, current.port == endpoint.port else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Whether the process is alive and a program of the name this one has (Changmun, the app or a copy of it). A crash leaves
    /// `control.json` behind, and its process ID may be another program's by the time it is read.
    static func isChangmun(pid: Int32) -> Bool {
        func name(_ pid: Int32) -> String? {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            return proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? URL(fileURLWithPath: String(cString: path)).lastPathComponent : nil
        }
        guard kill(pid, 0) == 0, let theirs = name(pid), let ours = name(getpid()) else { return false }
        return theirs == ours
    }
}

/// A small HTTP server on 127.0.0.1 that runs browser tools: `POST /call {"name", "arguments"}` with the token as a bearer.
final class ControlServer {
    static let shared = ControlServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "changmun.control")
    private let token = UUID().uuidString + UUID().uuidString
    private let file: URL
    /// How long a connection has to send the head of its request (the part with the token) before it is dropped.
    private let headDeadline: TimeInterval
    private var stopped = false

    init(file: URL = ControlEndpoint.file, headDeadline: TimeInterval = 10) {
        self.file = file
        self.headDeadline = headDeadline
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return listenFailed("couldn't create the listener") }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                guard let port = listener.port?.rawValue else { return }
                let endpoint = ControlEndpoint(port: port, token: self.token, pid: getpid())
                guard let data = try? JSONEncoder().encode(endpoint),
                      FileManager.default.createFile(atPath: self.file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                    return self.listenFailed("couldn't write control.json")
                }
            case .failed:
                // A listener that failed (the network stack was reset, say) accepts nothing anymore: it is replaced, and the new port
                // is written to the file the bridges read.
                listener.cancel()
                self.queue.asyncAfter(deadline: .now() + 1) {
                    guard !self.stopped, self.listener === listener else { return }
                    self.listener = nil
                    self.start()
                }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// A headless copy has no window, and its control server is the only way to it: without one it would run on, unseen and out of
    /// reach, and `changmun headless start` could not tell. So it quits.
    private func listenFailed(_ reason: String) {
        FileHandle.standardError.write(Data("changmun: the control server isn't up: \(reason)\n".utf8))
        if Headless.isOn { DispatchQueue.main.async { NSApp.terminate(nil) } }
    }

    func stop() {
        queue.sync {
            stopped = true
            listener?.cancel()
        }
        if ControlEndpoint.read(file: file)?.pid == getpid() { try? FileManager.default.removeItem(at: file) }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        // No request, tool call included, takes this long; a client that stalls is dropped.
        queue.asyncAfter(deadline: .now() + 150) { connection.cancel() }
        // The head of a request, with the token, comes at once. A connection that hasn't sent it holds nothing useful: it is dropped.
        let head = Head()
        queue.asyncAfter(deadline: .now() + headDeadline) { if !head.received { connection.cancel() } }
        receive(connection, buffer: Data(), head: head)
    }

    /// Whether a connection has sent the end of its request's head.
    private final class Head { var received = false }

    private func receive(_ connection: NWConnection, buffer: Data, head: Head) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { head.received = true }
            switch HTTPRequest.parse(buffer, token: self.token) {
            case .complete(let request):
                self.handle(request, on: connection)
            case .rejected(let status):
                self.respond(connection, status: status, body: ["error": status])
            case .incomplete:
                if complete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer, head: head) }
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        if Headless.isTestCopy, handleTestRequest(request, on: connection) { return }
        guard request.method == "POST", request.path == "/call",
              let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let name = body["name"] as? String else {
            return respond(connection, status: "404 Not Found", body: ["error": "use POST /call"])
        }
        let arguments = body["arguments"] as? [String: Any] ?? [:]
        Task { @MainActor in
            // A call from a run of the panel that was stopped or replaced is not carried out, however late it comes.
            guard let caller = Self.caller(request.headers) else {
                return self.respond(connection, status: "200 OK", body: ToolResult.text("This run of the AI was stopped, so its calls are no longer accepted.", error: true).json)
            }
            let result = await ToolCatalog.call(name, arguments, caller: caller)
            self.respond(connection, status: "200 OK", body: result.json)
        }
    }

    /// The caller a request names, except that the panel's name counts only with the panel's secret: without it the
    /// request is an ordinary outside client that happens to use that name. With the secret, it counts only with the token of the
    /// run under way; nil for a request that has the secret and not that token (a run that was stopped).
    @MainActor
    static func caller(_ headers: [String: String]) -> String? {
        let name = headers["x-changmun-caller"] ?? "unknown"
        guard name == ChatStore.caller else { return name }
        guard sameSecret(headers["x-changmun-panel-secret"] ?? "", ChatStore.panelSecret) else { return "unverified-" + name }
        guard let token = ChatStore.shared.runToken, sameSecret(headers["x-changmun-run-token"] ?? "", token) else { return nil }
        return name
    }

    /// Compares without stopping at the first difference, so how long it takes says nothing about the secret.
    static func sameSecret(_ given: String, _ secret: String) -> Bool {
        let a = Array(given.utf8), b = Array(secret.utf8)
        var difference = a.count ^ b.count
        for i in 0..<b.count { difference |= Int((i < a.count ? a[i] : 0) ^ b[i]) }
        return difference == 0
    }

    func respond(_ connection: NWConnection, status: String, body: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var data = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        data.append(json)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// An HTTP/1.1 request to the control server.
struct HTTPRequest {
    static let maxHead = 16 * 1024
    static let maxBody = 1 << 20

    enum Parse {
        case incomplete
        case complete(HTTPRequest)
        /// Answer with this status and close; the body of a request without the token is never read.
        case rejected(String)
    }

    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    static func parse(_ data: Data, token: String) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHead ? .rejected("431 Request Header Fields Too Large") : .incomplete
        }
        guard end.lowerBound - data.startIndex <= maxHead, let head = String(data: data[..<end.lowerBound], encoding: .utf8) else {
            return .rejected("400 Bad Request")
        }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return .rejected("400 Bad Request") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["authorization"] == "Bearer \(token)" else { return .rejected("401 Unauthorized") }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= maxBody else {
            return .rejected("413 Content Too Large")
        }
        let bodyStart = end.upperBound
        guard data.endIndex - bodyStart >= length else { return .incomplete }
        return .complete(HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers,
                                     body: data.subdata(in: bodyStart..<(bodyStart + length))))
    }
}
