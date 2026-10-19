import AppKit
import Foundation
import Network

/// Where the running app's control server listens, written for `Changmun --mcp` to find.
struct ControlEndpoint: Codable {
    var port: UInt16
    var token: String
    var pid: Int32

    static var file: URL { Library.folder.appendingPathComponent("control.json") }

    static func read() -> ControlEndpoint? {
        guard let data = try? Data(contentsOf: file), let endpoint = try? JSONDecoder().decode(ControlEndpoint.self, from: data),
              kill(endpoint.pid, 0) == 0 else { return nil }
        return endpoint
    }
}

/// A small HTTP server on 127.0.0.1 that runs browser tools: `POST /call {"name", "arguments"}` with the token as a bearer.
final class ControlServer {
    static let shared = ControlServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "changmun.control")
    private let token = UUID().uuidString + UUID().uuidString

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self, let port = listener.port?.rawValue else { return }
            let endpoint = ControlEndpoint(port: port, token: self.token, pid: getpid())
            if let data = try? JSONEncoder().encode(endpoint) {
                FileManager.default.createFile(atPath: ControlEndpoint.file.path, contents: data, attributes: [.posixPermissions: 0o600])
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        if ControlEndpoint.read()?.pid == getpid() { try? FileManager.default.removeItem(at: ControlEndpoint.file) }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        // No request, tool call included, takes this long; a client that stalls is dropped.
        queue.asyncAfter(deadline: .now() + 150) { connection.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer, token: self.token) {
            case .complete(let request):
                self.handle(request, on: connection)
            case .rejected(let status):
                self.respond(connection, status: status, body: ["error": status])
            case .incomplete:
                if complete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer) }
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        if request.method == "POST", request.path == "/window-image" {
            Task { @MainActor in
                guard let window = Browser.current?.window, let png = await WindowImage.png(of: window) else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no window"])
                }
                self.respond(connection, status: "200 OK", body: ["png": png.base64EncodedString()])
            }
            return
        }
        // Tests only: a mouse event at a point in the window (from its top left), handed to the app as if it came
        // from the window server, so the headless app can be clicked without touching the real pointer.
        if Headless.isOn, request.method == "POST", request.path == "/window-event",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
           let kind = body["type"] as? String, let x = body["x"] as? Double, let y = body["y"] as? Double {
            Task { @MainActor in
                let types: [String: NSEvent.EventType] = ["down": .leftMouseDown, "drag": .leftMouseDragged, "up": .leftMouseUp, "right": .rightMouseDown]
                guard let window = Browser.current?.window, let content = window.contentView, let type = types[kind],
                      let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: content.bounds.height - y), modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no window or unknown type"])
                }
                NSApp.sendEvent(event)
                self.respond(connection, status: "200 OK", body: [:])
            }
            return
        }
        // Tests only: the active tab as a PDF or a full-page picture, written to a path without the save panel.
        if Headless.isOn, request.method == "POST", request.path == "/save-page",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
           let kind = body["format"] as? String, let path = body["path"] as? String {
            Task { @MainActor in
                guard let webView = Browser.current?.active?.webView,
                      let data = await SavePage.data(of: webView, as: kind == "pdf" ? .pdf : .image), (try? data.write(to: URL(fileURLWithPath: path))) != nil else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "nothing saved"])
                }
                self.respond(connection, status: "200 OK", body: ["bytes": data.count])
            }
            return
        }
        // Tests only: open the settings window on a page, far off screen, and answer with its picture.
        if Headless.isOn, request.method == "POST", request.path == "/settings-image",
           let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
            Task { @MainActor in
                UserDefaults.standard.set(body["page"] as? String ?? SettingsPage.general.rawValue, forKey: "settingsPage")
                if let name = body["appearance"] as? String, let appearance = AppAppearance(rawValue: name) { Preferences.shared.appearance = appearance }
                (NSApp.delegate as? AppDelegate)?.showSettings(nil)
                guard let window = Panels.window("settings") else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no settings window"])
                }
                window.setFrameOrigin(Headless.origin)
                try? await Task.sleep(for: .milliseconds(600))
                guard let png = await WindowImage.png(of: window) else {
                    return self.respond(connection, status: "404 Not Found", body: ["error": "no picture"])
                }
                self.respond(connection, status: "200 OK", body: ["png": png.base64EncodedString()])
            }
            return
        }
        guard request.method == "POST", request.path == "/call",
              let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let name = body["name"] as? String else {
            return respond(connection, status: "404 Not Found", body: ["error": "use POST /call"])
        }
        let arguments = body["arguments"] as? [String: Any] ?? [:]
        Task { @MainActor in
            let result = await ToolCatalog.call(name, arguments, caller: request.headers["x-changmun-caller"] ?? "unknown")
            self.respond(connection, status: "200 OK", body: result.json)
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: [String: Any]) {
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
