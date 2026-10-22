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
        _ = await waitUntil(5) { !view.isLoading && view.url != nil }

        let f = Fixture()
        f.answer = false
        var read = 0
        tab.fillLogin(username: "me", authorization: f.authorization) { _, _ in read += 1; return "secret" }
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.asked == 1 && read == 0)
        #expect(try await view.evaluateJavaScript("document.querySelector('[name=p]').value") as? String == "")

        f.answer = true
        tab.fillLogin(username: "me", authorization: f.authorization) { host, name in read += 1; return host == "login.test" && name == "me" ? "secret" : nil }
        #expect(await waitUntil { read == 1 })
        var value = ""
        for _ in 0..<100 where value.isEmpty {
            value = (try? await view.evaluateJavaScript("document.querySelector('[name=p]').value")) as? String ?? ""
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(value == "secret")
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
        _ = await waitUntil(5) { !view.isLoading && view.url?.absoluteString == "https://login.test/" }

        var release: CheckedContinuation<Bool, Never>?
        let slow = FillAuthorization(required: { true }, confirm: { _ in await withCheckedContinuation { release = $0 } }, now: Date.init)
        var read = 0
        tab.fillLogin(username: "me", authorization: slow) { _, _ in read += 1; return "secret" }
        _ = await waitUntil { release != nil }

        view.loadHTMLString(form, baseURL: URL(string: newBase))
        _ = await waitUntil(5) { !view.isLoading && view.url?.absoluteString == newBase }
        #expect(view.url?.absoluteString == newBase)
        release?.resume(returning: true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await view.evaluateJavaScript("document.querySelector('[name=p]').value") as? String == "")
        #expect(try await view.evaluateJavaScript("document.querySelector('[name=u]').value") as? String == "")
    }
}
