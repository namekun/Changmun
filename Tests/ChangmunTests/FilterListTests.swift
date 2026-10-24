import Foundation
import Testing
@testable import Changmun

@MainActor
@Suite(.serialized)
struct FilterListUpdateTests {
    final class Calls: @unchecked Sendable {
        var fetched: [URL] = []
        var compiled: [String] = []
        var status = 200
        var body = Data(("! Title: a list\n" + String(repeating: "||ads.example^\n", count: 20)).utf8)
        var delay: Duration = .zero
        var failCompile = false
    }

    struct Rig {
        let blocker: AdBlocker
        let calls: Calls
        let folder: URL
        let defaults: UserDefaults
        let restore: () -> Void
    }

    /// An ad blocker with a folder, settings, names, downloads and builds of its own, and only the built-in lists switched on.
    private func rig(_ configure: (Calls) -> Void = { _ in }) throws -> Rig {
        let folder = try persistenceScratchFolder()
        let defaults = UserDefaults(suiteName: "filters-\(UUID().uuidString)")!
        let calls = Calls()
        configure(calls)
        let prefs = Preferences.shared
        let saved = (prefs.disabledFilterLists, prefs.customFilterLists, prefs.adBlockAllowlist)
        prefs.disabledFilterLists = []
        prefs.customFilterLists = []
        prefs.adBlockAllowlist = []
        let blocker = AdBlocker(folder: folder, defaults: defaults, identifier: "test-\(UUID().uuidString)", fetch: { url in
            calls.fetched.append(url)
            if calls.delay > .zero { try await Task.sleep(for: calls.delay) }
            return (calls.body, HTTPURLResponse(url: url, statusCode: calls.status, httpVersion: nil, headerFields: nil)!)
        }, compile: { id, _ in
            calls.compiled.append(id)
            if calls.failCompile { throw URLError(.cannotParseResponse) }
            return nil
        })
        return Rig(blocker: blocker, calls: calls, folder: folder, defaults: defaults, restore: {
            (prefs.disabledFilterLists, prefs.customFilterLists, prefs.adBlockAllowlist) = saved
            try? FileManager.default.removeItem(at: folder)
        })
    }

    @Test func aRequestMadeWhileTheListsAreBeingBuiltRunsAfterwards() async throws {
        let rig = try rig { $0.delay = .milliseconds(150) }
        defer { rig.restore() }
        let first = Task { await rig.blocker.update() }
        while !rig.blocker.working { await Task.yield() }
        let enabledBefore = rig.calls.fetched.count
        await rig.blocker.update()
        await first.value
        #expect(!rig.blocker.working)
        #expect(rig.calls.fetched.count >= 2 * AdBlocker.builtIn.count && enabledBefore <= AdBlocker.builtIn.count,
                "the second request was not dropped: the lists were fetched again")
    }

    @Test func aRebuildDoesNotLowerTheFlagOfADownloadInProgress() async throws {
        let rig = try rig { $0.delay = .milliseconds(150) }
        defer { rig.restore() }
        let download = Task { await rig.blocker.update() }
        while !rig.blocker.working { await Task.yield() }
        await rig.blocker.recompile()
        #expect(rig.blocker.working, "the download is still running")
        await download.value
        #expect(!rig.blocker.working)
    }

    @Test func theCompiledRulesAreNamedByTheConverterVersion() async throws {
        let rig = try rig()
        defer { rig.restore() }
        try Data("##.banner\n".utf8).write(to: rig.folder.appendingPathComponent("easylist.txt"))
        await rig.blocker.recompile()
        #expect(rig.calls.compiled.count == 2)
        #expect(rig.calls.compiled.allSatisfy { $0.hasSuffix("-v\(FilterConverter.version)") })
    }

    @Test func failedDownloadsDoNotCountAsAnUpdate() async throws {
        let rig = try rig { $0.status = 503 }
        defer { rig.restore() }
        await rig.blocker.update()
        #expect(rig.blocker.lastUpdated == nil && rig.defaults.object(forKey: "filtersUpdated") == nil)
        rig.calls.status = 200
        await rig.blocker.update()
        #expect(rig.blocker.lastUpdated != nil && rig.defaults.object(forKey: "filtersUpdated") != nil)
    }

    @Test func aPageOfHTMLIsNotTakenForAList() async throws {
        let html = Data(("<!DOCTYPE html><html><body>" + String(repeating: "Please sign in. ", count: 20) + "</body></html>").utf8)
        let rig = try rig { $0.body = html }
        defer { rig.restore() }
        await rig.blocker.update()
        let saved = try FileManager.default.contentsOfDirectory(atPath: rig.folder.path).filter { $0.hasSuffix(".txt") }
        #expect(saved.isEmpty && rig.blocker.lastUpdated == nil)
        #expect(!FilterConverter.looksLikeList(Data("  \n<html lang=en>".utf8) + html))
        #expect(FilterConverter.looksLikeList(Data(("! ok\n" + String(repeating: "||a.example^\n", count: 20)).utf8)))
    }

    @Test func aListIsWrittenWholeOrNotAtAll() async throws {
        let rig = try rig()
        defer { rig.restore() }
        let old = rig.folder.appendingPathComponent("easylist.txt")
        try Data("old list".utf8).write(to: old)
        rig.calls.status = 500
        await rig.blocker.update()
        #expect(try String(contentsOf: old, encoding: .utf8) == "old list", "a failed download leaves the copy that was there")
        rig.calls.status = 200
        await rig.blocker.update()
        #expect(try Data(contentsOf: old) == rig.calls.body)
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.folder.path).allSatisfy { $0.hasSuffix(".txt") }, "no temporary file is left")
    }

    @Test func aFailedBuildKeepsTheRulesThatWork() async throws {
        let rig = try rig()
        defer { rig.restore() }
        await rig.blocker.recompile()
        let count = rig.blocker.ruleCount
        #expect(count > 0 && !rig.blocker.status.hasPrefix("[ERROR]"))
        rig.calls.failCompile = true
        await rig.blocker.recompile()
        #expect(rig.blocker.status.hasPrefix("[ERROR]"))
        #expect(rig.blocker.ruleCount == count, "what is in use is still what was built before")
    }
}

