import Foundation
import Testing
@testable import Changmun

struct CommandLineOperandTests {
    /// Words a command has no use for are a mistake (`reload 3` reloaded the tab in front, not tab 3), not something to skip.
    @Test func wordsACommandHasNoUseForAreRefused() {
        let lines: [[String]] = [
            ["reload", "3"], ["back", "3"], ["forward", "3"], ["read", "5"], ["tabs", "x"], ["tools", "x"], ["screenshot", "out.jpg"],
            ["click", "100", "200"], ["hover", "3", "4"], ["show", "1", "2"], ["close", "1", "2"], ["scroll", "down", "3"],
            ["click-at", "1", "2", "3"], ["drag", "1", "2", "3"], ["press", "Enter", "Tab"], ["show", "1", "--tab", "2"],
        ]
        for line in lines {
            #expect(throws: CLI.UsageError.self, "\(line)") { try CLI.parse(line) }
        }
    }

    @Test func theRefusalSaysWhatToDoInstead() throws {
        func message(_ line: [String]) -> String {
            do { _ = try CLI.parse(line) } catch let error as CLI.UsageError { return error.message } catch {}
            return ""
        }
        #expect(message(["reload", "3"]).contains("--tab"))
        #expect(message(["read", "5"]).contains("--tab") && message(["read", "5"]).contains("--max"))
        #expect(message(["click", "100", "200"]).contains("click-at"))
        #expect(message(["scroll", "down", "3"]).contains("scroll"))
        #expect(message(["hover", "3", "4"]).contains("hover"))
    }

    @Test func commandsWithTheirOperandsStillParse() throws {
        #expect(try CLI.parse(["reload", "--tab", "3"]) == .call("reload", ["tab_id": 3], output: nil))
        #expect(try CLI.parse(["read", "--tab", "5", "--max", "100"]) == .call("read_page", ["tab_id": 5, "max_chars": 100], output: nil))
        #expect(try CLI.parse(["click", "7"]) == .call("click", ["element_id": 7], output: nil))
        #expect(try CLI.parse(["click-at", "10", "20"]) == .call("click_at", ["x": 10.0, "y": 20.0], output: nil))
        #expect(try CLI.parse(["scroll", "down", "--tab", "2"]) == .call("scroll", ["direction": "down", "tab_id": 2], output: nil))
        #expect(try CLI.parse(["hover", "3"]) == .call("hover", ["element_id": 3], output: nil))
        #expect(try CLI.parse(["show", "4"]) == .call("switch_tab", ["tab_id": 4], output: nil))
        #expect(try CLI.parse(["show", "--tab", "4"]) == .call("switch_tab", ["tab_id": 4], output: nil))
        #expect(try CLI.parse(["wait", "some", "words"]) == .call("wait_for", ["text": "some words"], output: nil))
        #expect(try CLI.parse(["call", "list_tabs", "{}"]) == .call("list_tabs", [:], output: nil))
    }
}

struct ControlEndpointProcessTests {
    private func write(_ endpoint: ControlEndpoint) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("endpoint-\(UUID().uuidString).json")
        try JSONEncoder().encode(endpoint).write(to: file)
        return file
    }

    /// After a crash the process ID may belong to anything: a live process that isn't Changmun is no app to talk to.
    @Test func aLiveProcessThatIsNotChangmunIsNotTheApp() throws {
        let other = Process()
        other.executableURL = URL(fileURLWithPath: "/bin/sleep")
        other.arguments = ["30"]
        try other.run()
        defer { other.terminate() }
        let file = try write(ControlEndpoint(port: 4321, token: "abc", pid: other.processIdentifier))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(kill(other.processIdentifier, 0) == 0, "alive, as a reused process ID would be")
        #expect(ControlEndpoint.read(file: file) == nil)
    }

    @Test func aProcessLikeTheCallerPassesAndADeadOneDoesNot() throws {
        let alive = try write(ControlEndpoint(port: 1, token: "t", pid: getpid()))
        defer { try? FileManager.default.removeItem(at: alive) }
        #expect(ControlEndpoint.read(file: alive) != nil)
        let dead = try write(ControlEndpoint(port: 1, token: "t", pid: 99_999_999))
        defer { try? FileManager.default.removeItem(at: dead) }
        #expect(ControlEndpoint.read(file: dead) == nil)
    }

    @Test func aRefusedConnectionDeletesTheFileOnlyIfItStillHoldsTheEndpointThatWasRead() throws {
        let read = ControlEndpoint(port: 1, token: "old", pid: 99_999_999)
        let same = try write(read)
        ControlEndpoint.remove(ifHolding: read, file: same)
        #expect(!FileManager.default.fileExists(atPath: same.path), "the stale file goes")
        let rewritten = try write(ControlEndpoint(port: 2, token: "new", pid: getpid()))
        defer { try? FileManager.default.removeItem(at: rewritten) }
        ControlEndpoint.remove(ifHolding: read, file: rewritten)
        #expect(FileManager.default.fileExists(atPath: rewritten.path), "a file the restarted app just wrote stays")
    }
}

struct LaunchModeTests {
    @Test func onlyTheFirstArgumentPicksTheMode() {
        func mode(_ words: String...) -> CLI.LaunchMode { CLI.LaunchMode.of(["/Applications/Changmun.app/Contents/MacOS/Changmun"] + words) }
        #expect(mode() == .app)
        #expect(mode("--mcp") == .mcp)
        #expect(mode("--mcp", "--headless") == .mcp)
        #expect(mode("--mcp", "--caller", "panel") == .mcp)
        #expect(mode("--cli", "tabs") == .cli)
        // A word of a command that happens to be a mode flag is the command's, not a mode.
        #expect(mode("--cli", "type", "3", "--mcp") == .cli)
        #expect(mode("--cli", "--mcp") == .cli)
        #expect(mode("tabs", "--mcp") == .app)
        #expect(mode("-NSDocumentRevisionsDebugMode", "YES", "--mcp") == .app)
        #expect(CLI.LaunchMode.of([]) == .app)
    }
}

struct ScreenshotNameTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000.123)

    @Test func theDefaultNameHasMillisecondsAndNeverTakesAFileThatIsThere() {
        #expect(CLI.imagePath(output: nil, ext: "jpg", index: 0, now: now, exists: { _ in false }) == "changmun-1700000000123.jpg")
        let taken: Set<String> = ["changmun-1700000000123.jpg", "changmun-1700000000123-2.jpg"]
        #expect(CLI.imagePath(output: nil, ext: "jpg", index: 0, now: now, exists: { taken.contains($0) }) == "changmun-1700000000123-3.jpg")
        // Several images in one reply: each its own file.
        #expect(CLI.imagePath(output: nil, ext: "png", index: 1, now: now, exists: { _ in false }) == "changmun-1700000000123-2.png")
    }

    @Test func aNameGivenWithOIsUsedAsItIsForTheFirstImageAndNumberedForTheOthers() {
        #expect(CLI.imagePath(output: "shot.jpg", ext: "jpg", index: 0, now: now, exists: { _ in true }) == "shot.jpg")
        #expect(CLI.imagePath(output: "shot.jpg", ext: "jpg", index: 1, now: now, exists: { _ in true }) == "shot-2.jpg")
        #expect(CLI.imagePath(output: "/tmp/a.b/shot", ext: "png", index: 2, now: now, exists: { _ in true }) == "/tmp/a.b/shot-3.png")
    }

    @Test func twoImagesOfOneReplyAreTwoFilesOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let previous = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(folder.path)
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }
        let image = ["type": "image", "mimeType": "image/jpeg", "data": Data("x".utf8).base64EncodedString()]
        #expect(CLI.show(["content": [image, image]], saveImageTo: nil) == 0)
        #expect(CLI.show(["content": [image]], saveImageTo: nil) == 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.count == 3, "\(files)")
    }
}

struct MCPSessionTests {
    /// Collects what a session sends, and lets a test wait for it.
    final class Sink: @unchecked Sendable {
        private let lock = NSCondition()
        private var messages: [[String: Any]] = []
        func add(_ message: [String: Any]) { lock.lock(); messages.append(message); lock.broadcast(); lock.unlock() }
        var all: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return messages }
        func wait(for count: Int, seconds: Double = 5) -> [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            let limit = Date(timeIntervalSinceNow: seconds)
            while messages.count < count, lock.wait(until: limit) {}
            return messages
        }
    }

    private func code(_ message: [String: Any]?) -> Int? { (message?["error"] as? [String: Any])?["code"] as? Int }

    @Test func aLineThatIsNotJSONIsAParseErrorWithANullID() {
        let sink = Sink()
        let session = MCPSession(call: { _, _ in [:] }, send: sink.add)
        session.receive("this is not json")
        session.receive("{\"jsonrpc\": \"2.0\", \"id\": 1,")
        let replies = sink.wait(for: 2)
        #expect(replies.count == 2)
        #expect(replies.allSatisfy { code($0) == -32700 && $0["id"] is NSNull })
    }

    @Test func batchesAndBareValuesAreInvalidRequestsNotSilence() {
        let sink = Sink()
        let session = MCPSession(call: { _, _ in [:] }, send: sink.add)
        session.receive(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        session.receive("5")
        let replies = sink.wait(for: 2)
        #expect(replies.count == 2 && replies.allSatisfy { code($0) == -32600 && $0["id"] is NSNull })
    }

    @Test func blankLinesAndTheClientsOwnResponsesGetNoReply() {
        let sink = Sink()
        let session = MCPSession(call: { _, _ in [:] }, send: sink.add)
        session.receive("")
        session.receive("   ")
        session.receive(#"{"jsonrpc":"2.0","id":7,"result":{}}"#)
        session.receive(#"{"jsonrpc":"2.0","id":8,"error":{"code":-1,"message":"no"}}"#)
        session.finish(timeout: 2)
        #expect(sink.all.isEmpty)
    }

    @Test func aMessageWithNoMethodIsAnInvalidRequestAnsweredUnderItsID() {
        let sink = Sink()
        let session = MCPSession(call: { _, _ in [:] }, send: sink.add)
        session.receive(#"{"jsonrpc":"2.0","id":9}"#)
        let replies = sink.wait(for: 1)
        #expect(code(replies.first) == -32600 && replies.first?["id"] as? Int == 9)
    }

    @Test func aPingIsAnsweredWhileAToolCallIsStillUnderWay() {
        let sink = Sink()
        let release = DispatchSemaphore(value: 0)
        let session = MCPSession(call: { _, _ in release.wait(); return ToolResult.text("done").json }, send: sink.add)
        session.receive(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_page","arguments":{}}}"#)
        session.receive(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        let first = sink.wait(for: 1)
        #expect(first.count == 1 && first[0]["id"] as? Int == 2, "the ping first: \(first)")
        release.signal()
        let both = sink.wait(for: 2)
        #expect(both.count == 2 && both[1]["id"] as? Int == 1)
        session.finish(timeout: 2)
    }

    @Test func toolCallsRunOneAfterAnotherInTheOrderTheyCameAndEachReplyCarriesItsID() {
        let sink = Sink()
        let order = Sink()
        let session = MCPSession(call: { name, _ in
            if name == "slow" { Thread.sleep(forTimeInterval: 0.3) }
            order.add(["name": name])
            return ToolResult.text(name).json
        }, send: sink.add)
        session.receive(#"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"slow"}}"#)
        session.receive(#"{"jsonrpc":"2.0","id":"b","method":"tools/call","params":{"name":"fast"}}"#)
        let both = sink.wait(for: 2)
        #expect(both.map { $0["id"] as? String } == ["a", "b"])
        #expect(order.all.map { $0["name"] as? String } == ["slow", "fast"])
        session.finish(timeout: 2)
    }

    @Test func aCallCancelledBeforeItStartsGetsNoReplyAndTheOthersStillDo() {
        let sink = Sink()
        let release = DispatchSemaphore(value: 0)
        let session = MCPSession(call: { name, _ in
            if name == "first" { release.wait() }
            return ToolResult.text(name).json
        }, send: sink.add)
        session.receive(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"first"}}"#)
        session.receive(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"second"}}"#)
        session.receive(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"third"}}"#)
        session.receive(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#)
        session.receive(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":99}}"#)
        release.signal()
        session.finish(timeout: 5)
        #expect(sink.all.map { $0["id"] as? Int } == [1, 3])
    }

    @Test func finishWaitsForCallsUnderWayButNotForever() {
        let sink = Sink()
        let session = MCPSession(call: { _, _ in Thread.sleep(forTimeInterval: 0.2); return ToolResult.text("late").json }, send: sink.add)
        session.receive(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x"}}"#)
        session.finish(timeout: 5)
        #expect(sink.all.count == 1)
        let stuck = DispatchSemaphore(value: 0)
        let hung = MCPSession(call: { _, _ in stuck.wait(); return [:] }, send: { _ in })
        hung.receive(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x"}}"#)
        let started = Date()
        hung.finish(timeout: 0.3)
        #expect(Date().timeIntervalSince(started) < 3)
        stuck.signal()
    }

    @Test func writingToAClosedPipeFailsInsteadOfRaising() throws {
        signal(SIGPIPE, SIG_IGN)
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        #expect(!MCPBridge.write(Data("{}\n".utf8), to: pipe.fileHandleForWriting))
        let open = Pipe()
        #expect(MCPBridge.write(Data("{}\n".utf8), to: open.fileHandleForWriting))
    }
}

/// A server on 127.0.0.1 that answers every request with the same bytes.
final class FakeControlServer: @unchecked Sendable {
    let port: UInt16
    private let socketFD: Int32

    init(response: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 4)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) } }
        socketFD = fd
        port = UInt16(bigEndian: bound.sin_port)
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                FakeControlServer.readRequest(client)
                _ = Array(response.utf8).withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                close(client)
            }
        }
    }

    deinit { close(socketFD) }

    /// Reads a whole request, head and body, so the answer never comes while the client is still sending.
    private static func readRequest(_ client: Int32) {
        var received = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(client, &chunk, chunk.count)
            if count <= 0 { return }
            received.append(contentsOf: chunk[0..<count])
            guard let head = received.firstRange(of: Array("\r\n\r\n".utf8)) else { continue }
            let headText = String(decoding: received[..<head.lowerBound], as: UTF8.self).lowercased()
            let length = headText.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            if received.count - head.upperBound >= length { return }
        }
    }

    /// A port nothing listens on and no server of a test can be given: the system hands out ports from 49152 up (the ephemeral range)
    /// when asked for any, so this one, tcpmux's, is never taken by another test. Freeing a port that was bound a moment before let
    /// another test's server have the number, and a socket that is bound and kept is not refused but ignored, which times out.
    static func closedPort() -> UInt16 { 1 }

    static func http(_ status: String, _ body: String) -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }
}

@Suite(.serialized) struct ControlClientTests {
    private func perform(_ port: UInt16, arguments: [String: Any] = [:]) -> ControlClient.Outcome {
        ControlClient.perform("list_tabs", arguments, caller: "test", to: ControlEndpoint(port: port, token: "t", pid: getpid()))
    }

    @Test func aToolResultComesBack() {
        let server = FakeControlServer(response: FakeControlServer.http("200 OK", #"{"content":[{"type":"text","text":"hi"}]}"#))
        defer { withExtendedLifetime(server) {} }
        guard case .result(let result) = perform(server.port) else { Issue.record("no result"); return }
        #expect(result["content"] != nil)
    }

    @Test func nobodyListeningIsRefusedSoTheCallerCanStartTheAppAgain() {
        guard case .refused = perform(FakeControlServer.closedPort()) else { Issue.record("not refused"); return }
    }

    @Test func aTokenTheAppDoesNotTakeIsUnauthorized() {
        let server = FakeControlServer(response: FakeControlServer.http("401 Unauthorized", #"{"error":"401 Unauthorized"}"#))
        defer { withExtendedLifetime(server) {} }
        guard case .unauthorized = perform(server.port) else { Issue.record("not unauthorized"); return }
        #expect(ControlClient.failure(status: 401, error: nil).contains("401") && ControlClient.failure(status: 401, error: nil).contains("token"))
    }

    @Test func otherRefusalsSaySoInsteadOfBadResponse() {
        let server = FakeControlServer(response: FakeControlServer.http("413 Content Too Large", #"{"error":"413 Content Too Large"}"#))
        defer { withExtendedLifetime(server) {} }
        guard case .failed(let message) = perform(server.port) else { Issue.record("not failed"); return }
        #expect(message.contains("413") && message.contains("too large") && !message.contains("bad response"))
        #expect(ControlClient.failure(status: 500, error: nil) == "Changmun answered HTTP 500")
        #expect(ControlClient.failure(status: nil, error: nil) == "bad response")
    }

    @Test func aRequestOverTheServersLimitIsRefusedHereWithoutSendingIt() {
        let server = FakeControlServer(response: FakeControlServer.http("200 OK", #"{"content":[]}"#))
        defer { withExtendedLifetime(server) {} }
        let big = String(repeating: "x", count: HTTPRequest.maxBody + 1)
        guard case .failed(let message) = perform(server.port, arguments: ["text": big]) else { Issue.record("not failed"); return }
        #expect(message.contains("413") && message.contains("too large"))
    }
}

struct HeadlessCopyBuildTests {
    /// A 64-bit little endian Mach-O header with a segment command and then an LC_UUID, as the linker writes them.
    static func machO(uuid: UUID, fat: Bool = false) -> Data {
        func le(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }
        func be(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian) { Array($0) } }
        var body: [UInt8] = le(0xFEED_FACF) + le(0x0100_000C) + le(0) + le(2) + le(2) + le(48 + 24) + le(0) + le(0)
        body += le(0x19) + le(48) + [UInt8](repeating: 0, count: 40)
        body += le(0x1B) + le(24) + withUnsafeBytes(of: uuid.uuid) { Array($0) }
        guard fat else { return Data(body) }
        let header = be(0xCAFE_BABE) + be(1) + be(0x0100_000C) + be(0) + be(16384) + be(UInt32(body.count)) + be(14)
        return Data(header + [UInt8](repeating: 0, count: 16384 - header.count) + body)
    }

    @Test func theBuildIsTheMachOsUUID() {
        let id = UUID()
        #expect(UserHeadless.machOUUID(in: Self.machO(uuid: id)) == id.uuidString)
        #expect(UserHeadless.machOUUID(in: Self.machO(uuid: id, fat: true)) == id.uuidString)
        #expect(UserHeadless.machOUUID(in: Data("binary".utf8)) == nil)
        #expect(UserHeadless.machOUUID(in: Data()) == nil)
        // A real linker's output: this test program's own executable.
        let own = try? FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[0])).read(upToCount: 256 * 1024)
        #expect(own.flatMap(UserHeadless.machOUUID(in:)).flatMap(UUID.init(uuidString:)) != nil)
        #expect(UserHeadless.machOUUID(in: Self.machO(uuid: id).prefix(60)) == nil, "cut short")
    }

    private let info: [String: Any] = [
        "CFBundleIdentifier": Headless.userBundleID, "CFBundleShortVersionString": "0.7.4", "CFBundleVersion": "30", "CFBundleExecutable": "Changmun",
    ]

    @Test func anotherBuildOfTheSameReleaseNeedsANewCopy() {
        var source = info
        source["CFBundleIdentifier"] = "io.github.namekun.Changmun"
        #expect(!UserHeadless.needsCopy(copy: info, source: source))
        #expect(!UserHeadless.needsCopy(copy: info, source: source, copyBuild: "A", sourceBuild: "A"))
        #expect(UserHeadless.needsCopy(copy: info, source: source, copyBuild: "A", sourceBuild: "B"))
        #expect(!UserHeadless.needsCopy(copy: info, source: source, copyBuild: nil, sourceBuild: "B"), "unknown builds don't count")
    }

    private func fakeApp(in root: URL, name: String, bundleID: String, uuid: UUID) throws -> URL {
        let app = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        var plist = info
        plist["CFBundleIdentifier"] = bundleID
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Self.machO(uuid: uuid).write(to: app.appendingPathComponent("Contents/MacOS/Changmun"))
        return app
    }

    private func copyingRunner() -> UserHeadless.Runner {
        { program, arguments in
            if program == "/usr/bin/ditto" { try FileManager.default.copyItem(atPath: arguments[0], toPath: arguments[1]) }
        }
    }

    @Test func aRebuildOfTheSameVersionRefreshesTheCopyAndSaysSoWhileItRuns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("headless-build-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try fakeApp(in: root.appendingPathComponent("a"), name: "Changmun.app", bundleID: "io.github.namekun.Changmun", uuid: UUID())
        let rebuilt = try fakeApp(in: root.appendingPathComponent("b"), name: "Changmun.app", bundleID: "io.github.namekun.Changmun", uuid: UUID())
        let profile = root.appendingPathComponent("Changmun Agent", isDirectory: true)
        #expect(try UserHeadless.prepare(from: first, in: profile, run: copyingRunner(), isRunning: { _ in false }))
        #expect(try !UserHeadless.prepare(from: first, in: profile, run: copyingRunner(), isRunning: { _ in false }), "the same build: nothing to do")
        let installed = UserHeadless.info(ofApp: rebuilt)
        #expect(UserHeadless.updateHint(installed: installed, installedApp: first, running: true, in: profile) == nil)
        let hint = try #require(UserHeadless.updateHint(installed: installed, installedApp: rebuilt, running: true, in: profile))
        #expect(hint.contains("another build of 0.7.4") && hint.contains("headless stop") && hint.contains("headless start"))
        #expect(UserHeadless.status(installed: installed, installedApp: rebuilt, in: profile).text.contains("another build"))
        #expect(try UserHeadless.prepare(from: rebuilt, in: profile, run: copyingRunner(), isRunning: { _ in false }), "a new build is copied")
        #expect(UserHeadless.updateHint(installed: installed, installedApp: rebuilt, running: true, in: profile) == nil)
    }

    @Test func aCopyThatIsRunningIsNeverReplacedUnderItself() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("headless-running-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try fakeApp(in: root.appendingPathComponent("a"), name: "Changmun.app", bundleID: "io.github.namekun.Changmun", uuid: UUID())
        let rebuilt = try fakeApp(in: root.appendingPathComponent("b"), name: "Changmun.app", bundleID: "io.github.namekun.Changmun", uuid: UUID())
        let profile = root.appendingPathComponent("Changmun Agent", isDirectory: true)
        try UserHeadless.prepare(from: old, in: profile, run: copyingRunner(), isRunning: { _ in false })
        let before = UserHeadless.buildID(ofApp: UserHeadless.app(in: profile))
        #expect(throws: UserHeadless.Failure.self) { try UserHeadless.prepare(from: rebuilt, in: profile, run: copyingRunner(), isRunning: { _ in true }) }
        #expect(UserHeadless.buildID(ofApp: UserHeadless.app(in: profile)) == before, "the running copy's files are as they were")
        #expect(UserHeadless.processes(runningFrom: UserHeadless.app(in: profile)).isEmpty, "nothing runs from a folder that was only written")
        let mine = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        #expect(UserHeadless.processes(runningFrom: mine).contains(getpid()), "a process is found by where its program is")
    }
}
