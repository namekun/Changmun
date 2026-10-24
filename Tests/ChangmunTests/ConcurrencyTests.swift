import Foundation
import Network
import Testing
@testable import Changmun

struct ProcessOutputTests {
    @Test func aProgramThatDoesNotEndIsEndedAfterTheTimeout() {
        let start = Date()
        #expect(ProcessOutput.run("/bin/sleep", ["30"], timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func outputLargerThanAPipeHoldsIsReadInFull() {
        let output = ProcessOutput.run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' a"], timeout: 10)
        #expect(output?.count == 300_000)
    }

    @Test func aProgramThatCannotBeStartedGivesNothing() {
        #expect(ProcessOutput.run("/nonexistent/program", [], timeout: 1) == nil)
    }

    @Test func installedExtensionsAreFoundWithoutWaitingForAPluginkitThatHangs() throws {
        guard #available(macOS 15.4, *) else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluginkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func script(_ name: String, _ body: String) throws -> String {
            let file = folder.appendingPathComponent(name)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return file.path
        }
        let start = Date()
        #expect(ExtensionHost.installedSafariExtensions(executable: try script("hangs", "exec /bin/sleep 30"), timeout: 0.3).isEmpty)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(ExtensionHost.installedSafariExtensions(executable: try script("lists", "echo '   Path = /Applications/X.app/Contents/PlugIns/X.appex'"), timeout: 5)
                == ["/Applications/X.app/Contents/PlugIns/X.appex"])
    }
}

@MainActor
struct BridgeEndpointTests {
    private let endpoint = ControlEndpoint(port: 1, token: "t", pid: 1)

    @Test func thePanelsOwnBridgeNeverStartsTheApp() {
        var launched = 0
        let found = ControlClient.endpoint(caller: ChatStore.caller, read: { nil }, launch: { launched += 1; return endpoint })
        #expect(found == nil && launched == 0, "the app was quit: a late tool call does not bring it back")
    }

    @Test func otherCallersStillStartTheAppAndAllUseARunningOne() {
        var launched = 0
        #expect(ControlClient.endpoint(caller: "mcp-1-x", read: { nil }, launch: { launched += 1; return endpoint })?.port == 1 && launched == 1)
        #expect(ControlClient.endpoint(caller: ChatStore.caller, read: { endpoint }, launch: { launched += 1; return nil })?.port == 1 && launched == 1)
    }
}

extension SharedAgentState {
@MainActor @Suite
struct EndedCallerTests {
    private func endedPID() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    @Test func theNameOfAnMCPClientTellsItsProcess() {
        #expect(Approvals.bridgePID(of: "mcp-123-AB-CD") == 123)
        #expect(Approvals.bridgePID(of: "panel") == nil && Approvals.bridgePID(of: "cli") == nil)
        #expect(Approvals.bridgePID(of: "mcp-42") == nil && Approvals.bridgePID(of: "mcp-close-2") == nil)
    }

    @Test func whatIsKeptForAnMCPClientWhoseProcessEndedGoesWhenANewCallerAppears() throws {
        let gone = "mcp-\(try endedPID())-\(UUID().uuidString)"
        let alive = "mcp-\(getpid())-\(UUID().uuidString)"
        let fresh = "mcp-\(getpid())-\(UUID().uuidString)"
        let panel = ChatStore.caller
        for caller in [gone, alive, panel] {
            Approvals.noteRead(sites: ["a.example"], caller: caller)
            SignIn.noteDeclined(host: "a.example", caller: caller)
            AgentActivity.shared.cancel(caller: caller)
        }
        defer {
            for caller in [gone, alive, fresh, panel] { Approvals.forgetReads(caller: caller) }
            Approvals.forgetEndedCallers { _ in false }
        }
        #expect(Approvals.remembers(caller: gone), "kept until a caller not heard from before comes")
        Approvals.noteCaller(fresh)
        #expect(!Approvals.remembers(caller: gone), "its bridge process ended")
        #expect(Approvals.remembers(caller: alive) && Approvals.remembers(caller: panel), "a live bridge and the panel keep theirs")
    }
}
}

struct ControlServerTests {
    @Test func aConnectionThatSendsNoRequestHeadIsDroppedSoon() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("control-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let server = ControlServer(file: file, headDeadline: 0.4)
        server.start()
        defer { server.stop() }
        var endpoint: ControlEndpoint?
        for _ in 0..<100 where endpoint == nil {
            endpoint = ControlEndpoint.read(file: file)
            if endpoint == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let port = try #require(endpoint).port
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let closed = Closed()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, complete, error in
                    if complete || error != nil { closed.set() }
                }
            case .failed, .cancelled: closed.set()
            default: break
            }
        }
        connection.start(queue: .global())
        defer { connection.cancel() }
        let start = Date()
        while !closed.isSet && Date().timeIntervalSince(start) < 5 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(closed.isSet && Date().timeIntervalSince(start) < 3, "an idle connection is not held for minutes")
    }

    private final class Closed: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}

@MainActor
struct DownloadShelfTests {
    @Test func aHoveredRowThatLeavesTheShelfIsNotWaitedForForever() async throws {
        let saved = Downloads.shelfTime
        Downloads.shelfTime = .milliseconds(50)
        defer { Downloads.shelfTime = saved }
        weak var watched: Downloads?
        do {
            let downloads = Downloads()
            watched = downloads
            let item = DownloadItem(filename: "a.zip", progress: Progress(totalUnitCount: 1), isPrivate: false)
            downloads.add(item)
            item.state = .finished
            item.isHovered = true
            downloads.settle(item)
            try await Task.sleep(for: .milliseconds(200))
            #expect(downloads.shelf.contains { $0 === item }, "it stays while the pointer is on it")
            // The row disappears under the pointer: no "left" ever comes.
            downloads.dismiss(item)
        }
        for _ in 0..<60 where watched != nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(watched == nil, "the task that waits for the pointer to leave a row ended with the row")
    }
}

struct PixelClampTests {
    @Test func hugeOrOddCoordinatesStayInRange() {
        #expect(ToolCatalog.pixels(1e300) == 1_000_000)
        #expect(ToolCatalog.pixels(-1e300) == 0)
        #expect(ToolCatalog.pixels(Double.greatestFiniteMagnitude) == 1_000_000)
        #expect(ToolCatalog.pixels(12.7) == 12)
    }
}
