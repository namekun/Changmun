import Foundation
import Testing
@testable import Changmun

private let userApp = Notifier.Environment(headless: false, bundleID: Notifier.appBundleID, underTests: false)

/// A centre that asks nobody anything and keeps what it was told.
@MainActor
private final class FakeCentre: NotificationCentre {
    var status: NotifierAuthorization
    let grants: Bool
    private(set) var requests = 0
    private(set) var posted: [(identifier: String, content: Notifier.Content, target: Notifier.Target)] = []
    private(set) var removed: [String] = []

    init(status: NotifierAuthorization, grants: Bool = true) {
        self.status = status
        self.grants = grants
    }

    func authorization() async -> NotifierAuthorization { status }

    func requestAuthorization() async -> Bool {
        requests += 1
        status = grants ? .allowed : .refused
        return grants
    }

    func post(identifier: String, _ content: Notifier.Content, target: Notifier.Target) async {
        posted.append((identifier, content, target))
    }

    func removeDelivered(identifier: String) { removed.append(identifier) }
}

/// Notifications for what happens while the app is in the background.
@MainActor
struct NotifierTests {
    private static let download = Notifier.Event.downloadFinished(name: "report.pdf", isPrivate: false)

    private func notifier(_ centre: FakeCentre, environment: Notifier.Environment = userApp, active: Bool = false, enabled: Bool = true,
                          made: @escaping () -> Void = {}) -> Notifier {
        Notifier(environment: environment, isActive: { active }, isEnabled: { enabled }, centre: { made(); return centre })
    }

    @Test func underTestsNothingIsAskedOrShownAndTheCentreIsNotEvenMade() async {
        #expect(!Notifier.Environment.current.isUserApp)
        let centre = FakeCentre(status: .notAsked)
        var made = false
        let notifier = notifier(centre, environment: .current, made: { made = true })
        #expect(await notifier.deliver(Self.download, target: .downloads(window: 1), identifier: "d") == false)
        #expect(await notifier.deliver(.approvalWaiting, target: .approval(window: 1), identifier: "a") == false)
        notifier.refreshAuthorization()
        await Task.yield()
        #expect(centre.requests == 0)
        #expect(centre.posted.isEmpty)
        #expect(!made)
    }

    @Test func aHeadlessAppOrAnotherBundleDoesNothing() async {
        for environment in [Notifier.Environment(headless: true, bundleID: Notifier.appBundleID, underTests: false),
                            Notifier.Environment(headless: false, bundleID: Headless.userBundleID, underTests: false),
                            Notifier.Environment(headless: false, bundleID: nil, underTests: false),
                            Notifier.Environment(headless: false, bundleID: Notifier.appBundleID, underTests: true)] {
            let centre = FakeCentre(status: .allowed)
            #expect(await notifier(centre, environment: environment).deliver(Self.download, target: .downloads(window: 1), identifier: "d") == false, "\(environment)")
            #expect(centre.requests == 0 && centre.posted.isEmpty)
        }
    }

    @Test func inTheBackgroundADownloadIsNamedAndTheClickGoesToTheDownloads() async {
        let centre = FakeCentre(status: .allowed)
        #expect(await notifier(centre).deliver(Self.download, target: .downloads(window: 7), identifier: "d1"))
        #expect(centre.posted.count == 1)
        #expect(centre.posted[0].content == Notifier.Content(title: String(localized: "Download finished"), body: "report.pdf"))
        #expect(centre.posted[0].target == .downloads(window: 7))
        #expect(centre.requests == 0, "already allowed: nobody is asked")
    }

    @Test func whileTheAppIsInFrontNothingIsShownAndNothingIsAsked() async {
        for event in [Self.download, Notifier.Event.approvalWaiting] {
            let centre = FakeCentre(status: .notAsked)
            var made = false
            #expect(await notifier(centre, active: true, made: { made = true }).deliver(event, target: .downloads(window: 1), identifier: "x") == false)
            #expect(centre.requests == 0 && centre.posted.isEmpty && !made)
        }
    }

    @Test func theSettingOffSilencesEverything() async {
        let centre = FakeCentre(status: .notAsked)
        #expect(await notifier(centre, enabled: false).deliver(.approvalWaiting, target: .approval(window: 1), identifier: "a") == false)
        #expect(centre.requests == 0 && centre.posted.isEmpty)
    }

    @Test func aPrivateWindowsDownloadIsNotNamed() async {
        let content = Notifier.content(for: .downloadFinished(name: "secret.pdf", isPrivate: true), appIsActive: false, enabled: true, environment: userApp)
        #expect(content == Notifier.Content(title: String(localized: "Download finished"), body: nil))
        let centre = FakeCentre(status: .allowed)
        await notifier(centre).deliver(.downloadFinished(name: "secret.pdf", isPrivate: true), target: .downloads(window: 2), identifier: "p")
        #expect(centre.posted.count == 1 && centre.posted[0].content.body == nil)
        #expect(!"\(centre.posted)".contains("secret"))
    }

    @Test func theAIWaitingGivesOneNoticeForTheApprovalsWindow() async {
        let centre = FakeCentre(status: .allowed)
        await notifier(centre).deliver(.approvalWaiting, target: .approval(window: 3), identifier: Notifier.approvalIdentifier)
        #expect(centre.posted.map(\.content.title) == [String(localized: "The AI is waiting for your answer")])
        #expect(centre.posted[0].target == .approval(window: 3))
    }

    @Test func theFirstNoticeAsksOnceAndShowsWhenAllowed() async {
        let centre = FakeCentre(status: .notAsked, grants: true)
        let notifier = notifier(centre)
        #expect(await notifier.deliver(Self.download, target: .downloads(window: 1), identifier: "1"))
        #expect(await notifier.deliver(Self.download, target: .downloads(window: 1), identifier: "2"))
        #expect(centre.requests == 1)
        #expect(centre.posted.count == 2)
        #expect(notifier.authorization == .allowed)
    }

    @Test func aRefusalStaysSilentAndIsNeverAskedAgain() async {
        let centre = FakeCentre(status: .notAsked, grants: false)
        let notifier = notifier(centre)
        #expect(await notifier.deliver(Self.download, target: .downloads(window: 1), identifier: "1") == false)
        #expect(await notifier.deliver(.approvalWaiting, target: .approval(window: 1), identifier: "2") == false)
        #expect(centre.requests == 1)
        #expect(centre.posted.isEmpty)
        #expect(notifier.authorization == .refused, "Settings shows the line from this")
    }

    @Test func aRefusalMadeEarlierIsNotAskedAboutAtAll() async {
        let centre = FakeCentre(status: .refused)
        #expect(await notifier(centre).deliver(Self.download, target: .downloads(window: 1), identifier: "1") == false)
        #expect(centre.requests == 0 && centre.posted.isEmpty)
    }

    @Test func theSettingsLookAsksNothing() async {
        let centre = FakeCentre(status: .refused)
        let notifier = notifier(centre)
        notifier.refreshAuthorization()
        for _ in 0..<5 { await Task.yield() }
        #expect(notifier.authorization == .refused)
        #expect(centre.requests == 0)
    }

    @Test func aClickKnowsItsWindowAndItsPlace() {
        for target in [Notifier.Target.downloads(window: 12), .approval(window: 4), .downloads(window: nil), .approval(window: nil)] {
            #expect(Notifier.Target(userInfo: target.userInfo) == target)
        }
        #expect(Notifier.Target(userInfo: ["target": "elsewhere", "window": 1]) == nil)
        #expect(Notifier.Target(userInfo: [:]) == nil)
    }

    @Test func theDockBadgeCountsRunningDownloadsAndClearsAtZero() {
        #expect(DockBadge.label(running: 0) == nil)
        #expect(DockBadge.label(running: -1) == nil)
        #expect(DockBadge.label(running: 1) == "1")
        #expect(DockBadge.label(running: 12) == "12")
    }

    @Test func aStartTabOrAnythingButAWebPageIsNotShared() {
        let page = URL(string: "https://example.com/a")
        #expect(SharePage.canShare(isStart: false, url: page))
        #expect(!SharePage.canShare(isStart: true, url: page))
        #expect(!SharePage.canShare(isStart: false, url: nil))
        #expect(!SharePage.canShare(isStart: false, url: URL(string: "file:///Users/me/secret.txt")))
        #expect(!SharePage.canShare(isStart: false, url: URL(string: "about:blank")))
    }
}
