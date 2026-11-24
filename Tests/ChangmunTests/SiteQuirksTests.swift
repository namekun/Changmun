import AppKit
import Foundation
import Testing
import WebKit
@testable import Changmun

/// The fixes for sites that break in WebKit: each works where it is meant to, and nowhere else changes.
@MainActor @Suite(.serialized)
struct SiteQuirksTests {
    private func page(at base: String) async throws -> (WKWebView, NSWindow) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        SiteQuirks.install(in: config.userContentController)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.loadHTMLString("<p>Hotels</p>", baseURL: URL(string: base))
        // The scripts the tests run are for this page, not for the empty one before it. Waited for generously: at the
        // start of a full run, with hundreds of tests sharing the main thread, a first load has taken twenty seconds.
        let end = Date().addingTimeInterval(60)
        while (view.isLoading || view.url?.absoluteString != base) && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!view.isLoading && view.url?.absoluteString == base, "the page never loaded")
        return (view, window)
    }

    private func value(_ script: String, in view: WKWebView) async throws -> String {
        try #require(try await view.evaluateJavaScript(script) as? String)
    }

    /// What CJ OnStyle's hotel list does to count the nights: split "a ~ b" and read each half as a date.
    private let nights = """
    (() => { const [a, b] = '2026-12-21 ~ 2026-12-22'.split('~'); return String(Math.ceil(Math.abs(new Date(b) - new Date(a)) / 86400000)); })()
    """

    @Test func aDateWithSpacesAroundItIsReadOnTheSitesItIsFixedFor() async throws {
        let (view, window) = try await page(at: "https://otour.cjonstyle.com/pages/overseas/hotel/list")
        defer { window.close() }
        #expect(try await value(nights, in: view) == "1")
        #expect(try await value("String(Date.parse(' 2026-12-21 '))", in: view) != "NaN")
    }

    @Test func everywhereElseWebKitsOwnDateIsLeftAsItIs() async throws {
        let (view, window) = try await page(at: "https://example.com/")
        defer { window.close() }
        #expect(try await value("String(new Date('2026-12-21 ').getTime())", in: view) == "NaN", "WebKit's own reading, untouched")
        #expect(try await value("String(Date.parse === Object.getOwnPropertyDescriptor(window, 'Date').value.parse && /native code/.test(Date.toString()))", in: view) == "true")
    }

    @Test func theFixedDateIsStillTheDateEverythingElseExpects() async throws {
        let (view, window) = try await page(at: "https://otour.cjonstyle.com/")
        defer { window.close() }
        let checks = """
        (() => {
          const d = new Date('2026-12-21');
          class Stay extends Date {}
          const s = new Stay('2026-12-22 ');
          return JSON.stringify([
            d instanceof Date, Object.prototype.toString.call(d), typeof Date(), typeof Date.now(), Date.UTC(2026, 0, 1),
            d.getTime() === new Date(2026, 11, 21).getTime() || d.toISOString() === '2026-12-21T00:00:00.000Z',
            s instanceof Stay, s instanceof Date, !Number.isNaN(s.getTime()), new Date('not a date').getTime()
          ]);
        })()
        """
        #expect(try await value(checks, in: view) == #"[true,"[object Date]","string","number",1767225600000,true,true,true,true,null]"#)
    }

    @Test func aQuirkIsForItsSitesAndTheHostsUnderThem() {
        let quirk = SiteQuirks.trimmedDates
        #expect(quirk.applies(to: "otour.cjonstyle.com") && quirk.applies(to: "m.otour.cjonstyle.com") && quirk.applies(to: "OTOUR.cjonstyle.com"))
        #expect(!quirk.applies(to: "cjonstyle.com") && !quirk.applies(to: "otour.cjonstyle.com.evil.example") && !quirk.applies(to: "xotour.cjonstyle.com"))
    }
}
