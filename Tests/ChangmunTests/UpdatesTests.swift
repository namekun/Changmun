import Foundation
import Testing
@testable import Changmun

struct UpdatesTests {
    private var info: [String: Any] {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Info.plist").standardized
        return NSDictionary(contentsOf: plist) as? [String: Any] ?? [:]
    }

    @Test func theAppAsksTheSignedFeedOnPagesAndNeverSendsASystemProfile() throws {
        #expect(info["SUFeedURL"] as? String == "https://namekun.github.io/Changmun/appcast.xml")
        let key = try #require(info["SUPublicEDKey"] as? String)
        #expect(Data(base64Encoded: key)?.count == 32)
        #expect(info["SURequireSignedFeed"] as? Bool == true)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(info["SUEnableSystemProfiling"] as? Bool == false)
        // On, so the first launch doesn't ask: Sparkle's question would come before anyone has seen the browser.
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
    }

    @Test func theFeedInTheRepositoryIsAFeedSparkleCanRead() throws {
        let feed = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/appcast.xml").standardized
        let parser = XMLParser(contentsOf: feed)
        let delegate = FeedReader()
        parser?.delegate = delegate
        #expect(parser?.parse() == true)
        #expect(delegate.channels == 1)
        #expect(delegate.items <= 10)
    }

    @MainActor @Test func nothingUpdatesWhereThereIsNoFeed() {
        // A test run's Info.plist has no SUFeedURL, like a bare binary: the updater stays off.
        #expect(!Updates.shared.isAvailable)
        #expect(!Updates.shared.canCheck)
        #expect(!Updates.shared.automaticallyChecks)
    }
}

private final class FeedReader: NSObject, XMLParserDelegate {
    var channels = 0
    var items = 0

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "channel" { channels += 1 }
        if name == "item" { items += 1 }
    }
}
