import AppKit
import Foundation
import Testing
import WebKit
@testable import Changmun

/// Filling a saved password asks the device owner first. Every test gives its own way of asking and its own way of reading
/// the password, so none touches the keychain or shows a prompt.
@MainActor
struct FillAuthorizationTests {
    /// Answers the question as told and counts how often it was asked; its clock is moved by hand.
    @MainActor final class Fixture {
        var asked = 0
        var answer = true
        var required = true
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var reads = 0

        lazy var authorization = FillAuthorization(required: { self.required }, confirm: { _ in self.asked += 1; return self.answer }, now: { self.clock })

        func fill() async -> String? {
            await authorization.read { self.reads += 1; return "secret" }
        }
    }

    @Test func thePasswordIsReadOnlyAfterTheDeviceOwnerConfirms() async {
        let f = Fixture()
        #expect(await f.fill() == "secret")
        #expect(f.asked == 1 && f.reads == 1)
    }

    @Test func cancellingFillsNothingAndReadsNothing() async {
        let f = Fixture()
        f.answer = false
        #expect(await f.fill() == nil)
        #expect(f.asked == 1 && f.reads == 0)
        // A cancel starts no grace period: the next fill asks again.
        f.answer = true
        #expect(await f.fill() == "secret")
        #expect(f.asked == 2)
    }

    @Test func fillingTwiceInARowAsksOnceButNotAfterTheGracePeriod() async {
        let f = Fixture()
        _ = await f.fill()
        f.clock.addTimeInterval(FillAuthorization.grace - 1)
        #expect(await f.fill() == "secret")
        #expect(f.asked == 1)
        f.clock.addTimeInterval(2)
        #expect(await f.fill() == "secret")
        #expect(f.asked == 2)
    }

    @Test func theGracePeriodIsSixtySeconds() {
        #expect(FillAuthorization.grace == 60)
    }

    @Test func withTheSettingOffNothingIsAsked() async {
        let f = Fixture()
        f.required = false
        f.answer = false
        #expect(await f.fill() == "secret")
        #expect(f.asked == 0)
    }

    @Test func aSecondFillWhileTheQuestionIsOpenDoesNotAskAgain() async {
        let f = Fixture()
        var release: CheckedContinuation<Bool, Never>?
        let slow = FillAuthorization(required: { true }, confirm: { _ in f.asked += 1; return await withCheckedContinuation { release = $0 } }, now: { f.clock })
        let first = Task { await slow.read { "secret" } }
        _ = await waitUntil { release != nil }
        #expect(await slow.read { "secret" } == nil)
        release?.resume(returning: true)
        #expect(await first.value == "secret")
        #expect(f.asked == 1)
    }

    @Test func aPageIsFilledOnlyOnceTheDeviceOwnerHasConfirmed() async throws {
        let b = Browser()
        b.focused()
        defer { b.windowClosed() }
        let tab = b.openTab(url: nil)
        let view = tab.wake()
        let window = OffscreenWindow(view)
        defer { window.close() }
        view.loadHTMLString("<form><input type=text name=u><input type=password name=p></form>", baseURL: URL(string: "https://login.test/"))
        try #require(await committed("https://login.test/", in: tab), "the page never loaded")

        let f = Fixture()
        f.answer = false
        var read = 0
        tab.fillLogin(username: "me", authorization: f.authorization) { _, _ in read += 1; return "secret" }
        #expect(await waitUntil(30) { f.asked == 1 }, "the device owner was never asked")
        #expect(read == 0)
        #expect(await passwordField(of: view) == "")

        f.answer = true
        tab.fillLogin(username: "me", authorization: f.authorization) { host, name in read += 1; return host == "login.test" && name == "me" ? "secret" : nil }
        #expect(await waitUntil(30) { read == 1 }, "the password was never read after the owner confirmed")
        #expect(await fieldBecomes("secret", in: view), "the password never reached the page")
        #expect(read == 1, "and the first, cancelled fill read nothing")
    }

    /// The password field's value, "" while it has none.
    private func passwordField(of view: WKWebView) async -> String {
        (try? await view.evaluateJavaScript("document.querySelector('[name=p]').value")) as? String ?? ""
    }

    /// Polls until the password field holds `value`, which the page gets a moment after the script is sent.
    private func fieldBecomes(_ value: String, in view: WKWebView, timeout: Double = 30) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await passwordField(of: view) == value { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await passwordField(of: view) == value
    }

    /// Whether `address` becomes the tab's committed document with no navigation under way, which is what a fill goes by. Waited for
    /// generously: at the start of a full run, with hundreds of tests sharing the main thread, a first load has taken twenty seconds.
    private func committed(_ address: String, in tab: Changmun.Tab) async -> Bool {
        await waitUntil(60) { !tab.isLoadingProvisionally && tab.committedURL?.absoluteString == address }
    }

    /// Polls until `authorization` gives a password without asking: it says nil while its question is open, and once it was confirmed
    /// it asks nothing for the minute of grace.
    private func answersWithoutAsking(_ authorization: FillAuthorization) async -> Bool {
        let end = Date().addingTimeInterval(30)
        while Date() < end {
            if await authorization.read({ "probe" }) != nil { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test(arguments: ["http://login.test/", "https://login.test:8443/", "https://other.test/"])
    func aPageThatMovedOnWhileTheQuestionWasOpenIsNotFilled(newBase: String) async throws {
        let b = Browser()
        b.focused()
        defer { b.windowClosed() }
        let tab = b.openTab(url: nil)
        let view = tab.wake()
        let window = OffscreenWindow(view)
        defer { window.close() }
        let form = "<form><input type=text name=u><input type=password name=p></form>"
        view.loadHTMLString(form, baseURL: URL(string: "https://login.test/"))
        try #require(await committed("https://login.test/", in: tab), "the page never loaded")

        var release: CheckedContinuation<Bool, Never>?
        let slow = FillAuthorization(required: { true }, confirm: { _ in await withCheckedContinuation { release = $0 } }, now: Date.init)
        var read = 0
        tab.fillLogin(username: "me", authorization: slow) { _, _ in read += 1; return "secret" }
        try #require(await waitUntil(30) { release != nil }, "the device owner was never asked")

        view.loadHTMLString(form, baseURL: URL(string: newBase))
        try #require(await committed(newBase, in: tab), "the page never moved on")
        release?.resume(returning: true)
        // The fill decides in the same turn as the owner's answer, which begins the minute of grace: once the authorization answers
        // a read of its own without asking, the fill has decided, and a round trip to the page then comes after anything sent to it.
        #expect(await answersWithoutAsking(slow), "the owner's answer never came back")
        #expect(read == 0, "the password is not even read for a page that moved on")
        for _ in 0..<3 { _ = await passwordField(of: view) }
        #expect(try await view.evaluateJavaScript("document.querySelector('[name=p]').value") as? String == "")
        #expect(try await view.evaluateJavaScript("document.querySelector('[name=u]').value") as? String == "")
    }
}
