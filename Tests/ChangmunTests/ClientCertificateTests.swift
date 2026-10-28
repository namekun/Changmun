import Foundation
import Security
import Testing
@testable import Changmun

/// A distinguished name in DER: one common name per RDN, in the string type asked for (0x0C UTF8String, 0x13 PrintableString).
private func dn(_ common: String..., tag: UInt8 = 0x0C) -> Data {
    func element(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        precondition(content.count < 128)
        return [tag, UInt8(content.count)] + content
    }
    let sets = common.flatMap { element(0x31, element(0x30, element(0x06, [0x55, 0x04, 0x03]) + element(tag, Array($0.utf8)))) }
    return Data(element(0x30, sets))
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400

private func candidate(_ name: String, issuer: String = "Root", above: [String] = [], from: TimeInterval = -30, to: TimeInterval = 30, id: String? = nil) -> ClientCertificates.Candidate {
    ClientCertificates.Candidate(id: id ?? name, name: name, issuers: Set(([issuer] + above).map { ClientCertificates.key(ofName: dn($0)) }),
                                 notBefore: now + from * day, notAfter: now + to * day, identity: nil)
}

struct ClientCertificateTests {
    private func plan(_ candidates: [ClientCertificates.Candidate], preferred: ClientCertificates.Candidate? = nil, remembered: ClientCertificates.Candidate? = nil,
                      issuers: [String] = [], headless: Bool = false, agent: Bool = false) -> ClientCertificates.Plan {
        ClientCertificates.plan(candidates: candidates, preferred: preferred, remembered: remembered, acceptedIssuers: issuers.map { dn($0) }, now: now,
                                situation: .init(isHeadless: headless, agentDriven: agent))
    }

    // MARK: Which identities a site accepts

    @Test func aSiteThatNamesIssuersGetsOnlyIdentitiesFromThem() {
        let list = ClientCertificates.usable([candidate("A", issuer: "One"), candidate("B", issuer: "Two"), candidate("C", issuer: "Three")],
                                             acceptedIssuers: [dn("Two"), dn("Three")], now: now)
        #expect(list.map(\.name) == ["B", "C"])
    }

    @Test func aSiteThatNamesNoIssuerAcceptsAnyIdentity() {
        let list = ClientCertificates.usable([candidate("A", issuer: "One"), candidate("B", issuer: "Two")], acceptedIssuers: [], now: now)
        #expect(list.map(\.name) == ["A", "B"])
    }

    @Test func anIdentityIssuedBelowANamedAuthorityIsAccepted() {
        let below = candidate("Staff", issuer: "Intermediate", above: ["Root"])
        #expect(ClientCertificates.usable([below], acceptedIssuers: [dn("Root")], now: now).count == 1)
        #expect(ClientCertificates.usable([below], acceptedIssuers: [dn("Other")], now: now).isEmpty)
    }

    @Test func twoSpellingsOfOneIssuerNameMatch() {
        let spelled = candidate("A", issuer: "Example  CA")
        // Another letter case, another string type, and a run of spaces: still the issuer the site named.
        #expect(ClientCertificates.usable([spelled], acceptedIssuers: [dn("example ca", tag: 0x13)], now: now).count == 1)
        #expect(ClientCertificates.usable([spelled], acceptedIssuers: [dn("example ca 2")], now: now).isEmpty)
    }

    @Test func aNameThatCannotBeReadIsComparedByItsBytes() {
        let junk = Data([0x01, 0x02, 0x03])
        #expect(ClientCertificates.key(ofName: junk) == ClientCertificates.key(ofName: junk))
        #expect(ClientCertificates.key(ofName: junk) != ClientCertificates.key(ofName: Data([0x01, 0x02, 0x04])))
    }

    // MARK: Which are still valid

    @Test func identitiesThatExpiredOrAreNotYetValidAreLeftOut() {
        let list = ClientCertificates.usable([candidate("Expired", from: -60, to: -1), candidate("Future", from: 1, to: 60), candidate("Fine")], acceptedIssuers: [], now: now)
        #expect(list.map(\.name) == ["Fine"])
    }

    @Test func theFirstAndLastMomentOfValidityCount() {
        let edge = ClientCertificates.Candidate(id: "e", name: "Edge", issuers: [], notBefore: now, notAfter: now, identity: nil)
        #expect(ClientCertificates.usable([edge], acceptedIssuers: [], now: now).count == 1)
        #expect(ClientCertificates.usable([edge], acceptedIssuers: [], now: now + 1).isEmpty)
        #expect(ClientCertificates.usable([edge], acceptedIssuers: [], now: now - 1).isEmpty)
    }

    // MARK: In which order

    @Test func theListIsByNameThenNewerFirstWithEachIdentityOnce() {
        let list = ClientCertificates.usable([candidate("b person"), candidate("Carol"), candidate("Alice", from: -10, id: "old"), candidate("Alice", from: -5, id: "new"),
                                              candidate("Alice", from: -5, id: "new")], acceptedIssuers: [], now: now)
        #expect(list.map(\.id) == ["new", "old", "b person", "Carol"])
    }

    // MARK: The system's preference first

    @Test func aPreferredIdentityIsUsedWithoutAsking() {
        let mine = candidate("Mine")
        #expect(plan([candidate("Other"), mine], preferred: mine) == .use(mine))
    }

    @Test func aPreferenceThatIsExpiredOrNotAcceptedIsNotUsed() {
        let old = candidate("Old", from: -60, to: -1), other = candidate("Other", issuer: "Elsewhere")
        #expect(plan([candidate("Fine")], preferred: old) == .ask([candidate("Fine")]))
        #expect(plan([candidate("Fine")], preferred: other, issuers: ["Root"]) == .ask([candidate("Fine")]))
    }

    @Test func aPageTheAIDrivesAsksEvenWithAPreference() {
        let mine = candidate("Mine"), other = candidate("Other")
        #expect(plan([mine, other], preferred: mine, agent: true) == .ask([mine, other]))
        #expect(plan([mine, other], preferred: mine, remembered: other, agent: true) == .ask([mine, other]))
    }

    // MARK: Nothing is chosen for the user

    @Test func aSingleIdentityIsStillAskedAbout() {
        #expect(plan([candidate("Only")]) == .ask([candidate("Only")]))
    }

    @Test func noIdentityMeansNoPanel() {
        #expect(plan([]) == .continueWithout)
        #expect(plan([candidate("Expired", to: -1)]) == .continueWithout)
        // A list the site sends that matches nothing is a guess that may be wrong: the valid identities are offered all the same (see ClientCertificateOfferTests).
        #expect(plan([candidate("Other", issuer: "Elsewhere")], issuers: ["Root"]) == .ask([candidate("Other", issuer: "Elsewhere")]))
    }

    @Test func theUsersEarlierChoiceInTheWindowIsReusedButNotForTheAI() {
        let chosen = candidate("Chosen")
        #expect(plan([chosen, candidate("Other")], remembered: chosen) == .use(chosen))
        #expect(plan([chosen, candidate("Other")], remembered: chosen, agent: true) == .ask([candidate("Chosen"), candidate("Other")]))
    }

    @Test func thePreferenceBeatsTheEarlierChoice() {
        let preferred = candidate("Preferred"), chosen = candidate("Chosen")
        #expect(plan([preferred, chosen], preferred: preferred, remembered: chosen) == .use(preferred))
    }

    @Test func anEarlierChoiceThatExpiredIsAskedAgain() {
        let stale = candidate("Stale", to: -1)
        #expect(plan([candidate("Fine")], remembered: stale) == .ask([candidate("Fine")]))
    }

    // MARK: Headless, the user's keychain and the panel

    private final class Calls {
        var identities = 0, preferred = 0, asked = 0
    }

    private func environment(_ calls: Calls, identities: [ClientCertificates.Candidate], preferred: ClientCertificates.Candidate? = nil,
                             remembered: ClientCertificates.Candidate? = nil, exists: @escaping (ClientCertificates.Candidate) -> Bool = { _ in true },
                             answer: ClientCertificates.Candidate? = nil, situation: ClientCertificates.Situation = .init()) -> ClientCertificates.Environment {
        ClientCertificates.Environment(situation: situation, now: { now }, identities: { calls.identities += 1; return identities },
                                       preferred: { _, _ in calls.preferred += 1; return preferred }, remembered: remembered, exists: exists,
                                       ask: { _ in calls.asked += 1; return answer })
    }

    @Test func aHeadlessChangmunNeitherAsksNorTouchesTheKeychain() async {
        let calls = Calls()
        let chosen = await ClientCertificates.resolve(host: "mtls.example", port: 443, acceptedIssuers: [],
                                                      environment: environment(calls, identities: [candidate("A")], preferred: candidate("A"), answer: candidate("A"), situation: .init(isHeadless: true)))
        #expect(chosen == nil)
        #expect(calls.identities == 0 && calls.preferred == 0 && calls.asked == 0)
    }

    @Test func thePanelIsNotShownForAPreferenceOrWhenThereIsNothingToChoose() async {
        let calls = Calls()
        let mine = candidate("Mine")
        let used = await ClientCertificates.resolve(host: "mtls.example", port: 443, acceptedIssuers: [], environment: environment(calls, identities: [mine, candidate("Other")], preferred: mine))
        #expect(used == mine && calls.asked == 0)
        let none = await ClientCertificates.resolve(host: "mtls.example", port: 443, acceptedIssuers: [], environment: environment(calls, identities: []))
        #expect(none == nil && calls.asked == 0)
    }

    @Test func theUsersAnswerIsWhatIsUsedAndCancelMeansNone() async {
        let calls = Calls()
        let list = [candidate("A"), candidate("B")]
        let picked = await ClientCertificates.resolve(host: "mtls.example", port: 443, acceptedIssuers: [], environment: environment(calls, identities: list, answer: list[1]))
        #expect(picked == list[1] && calls.asked == 1)
        let cancelled = await ClientCertificates.resolve(host: "mtls.example", port: 443, acceptedIssuers: [], environment: environment(calls, identities: list, answer: nil))
        #expect(cancelled == nil && calls.asked == 2)
    }

    @Test func theAIDoesNotGetAnIdentityChosenForIt() async {
        let calls = Calls()
        let only = candidate("Only")
        let chosen = await ClientCertificates.resolve(host: "mtls.example", port: 443, acceptedIssuers: [],
                                                      environment: environment(calls, identities: [only], answer: nil, situation: .init(agentDriven: true)))
        #expect(chosen == nil && calls.asked == 1, "the user was asked, and said no")
    }

    // MARK: Only what is still there, and only what is needed

    @Test func anIdentityThatIsGoneIsNotUsedAgainAndTheUserIsAsked() async {
        let calls = Calls()
        let gone = candidate("Card"), other = candidate("Other")
        let viaChoice = await ClientCertificates.resolve(host: "mtls.example", port: 443, acceptedIssuers: [],
                                                         environment: environment(calls, identities: [other], remembered: gone, exists: { $0 != gone }, answer: other))
        #expect(viaChoice == other && calls.asked == 1, "the smart card was taken out since it was chosen")
        let viaPreference = await ClientCertificates.resolve(host: "mtls.example", port: 443, acceptedIssuers: [],
                                                             environment: environment(calls, identities: [other], preferred: gone, exists: { $0 != gone }, answer: other))
        #expect(viaPreference == other && calls.asked == 2)
        let there = await ClientCertificates.resolve(host: "mtls.example", port: 443, acceptedIssuers: [],
                                                     environment: environment(calls, identities: [other], remembered: gone))
        #expect(there == gone && calls.asked == 2, "one that is there is used as before")
    }

    @Test func theIdentitiesAreNotListedWhenAPreferenceOrAnEarlierChoiceSettlesIt() async {
        let calls = Calls()
        let mine = candidate("Mine")
        _ = await ClientCertificates.resolve(host: "mtls.example", port: 443, acceptedIssuers: [], environment: environment(calls, identities: [mine, candidate("Other")], preferred: mine))
        _ = await ClientCertificates.resolve(host: "mtls.example", port: 443, acceptedIssuers: [], environment: environment(calls, identities: [mine], remembered: mine))
        #expect(calls.identities == 0)
        _ = await ClientCertificates.resolve(host: "mtls.example", port: 443, acceptedIssuers: [], environment: environment(calls, identities: [mine]))
        #expect(calls.identities == 1, "and they are when nothing settles it")
        // A page the AI drives doesn't even look at the preference.
        let before = calls.preferred
        _ = await ClientCertificates.resolve(host: "mtls.example", port: 443, acceptedIssuers: [], environment: environment(calls, identities: [mine], preferred: mine, situation: .init(agentDriven: true)))
        #expect(calls.preferred == before)
    }

    // MARK: Profile spaces

    @Test func aProfileSpaceDoesNotUseTheSystemsPreferenceButKeepsItsOwnChoice() {
        let preferred = candidate("Preferred"), chosen = candidate("Chosen")
        func plan(preferred: ClientCertificates.Candidate?, remembered: ClientCertificates.Candidate?) -> ClientCertificates.Plan {
            ClientCertificates.plan(candidates: [preferred, remembered].compactMap { $0 }, preferred: preferred, remembered: remembered, acceptedIssuers: [], now: now,
                                    situation: .init(isProfile: true))
        }
        #expect(plan(preferred: preferred, remembered: nil) == .ask([preferred]), "the preference was made in another space or for the Mac")
        #expect(plan(preferred: preferred, remembered: chosen) == .use(chosen), "what the user chose in this profile is theirs")
    }

    @Test func aProfileSpaceWritesNoPreferenceToTheKeychain() {
        #expect(ClientCertificates.domainToRemember(host: "mtls.example", port: 443, isPrivate: false, agentDriven: false, isProfile: true) == nil)
        #expect(ClientCertificates.domainToRemember(host: "mtls.example", port: 443, isPrivate: false, agentDriven: false, isProfile: false) == "https://mtls.example")
    }

    @Test func eachDataStoreHasItsOwnChoiceAndItsOwnPanel() {
        let work = UUID(), home = UUID()
        let shared = ClientCertificates.requestKey(host: "mtls.example", port: 443, acceptedIssuers: [])
        let inWork = ClientCertificates.requestKey(host: "mtls.example", port: 443, acceptedIssuers: [], store: work)
        let inHome = ClientCertificates.requestKey(host: "mtls.example", port: 443, acceptedIssuers: [], store: home)
        #expect(Set([shared, inWork, inHome]).count == 3)
        #expect(inWork == ClientCertificates.requestKey(host: "MTLS.example", port: 443, acceptedIssuers: [], store: work))
        #expect(ClientCertificates.queueKey(site: inWork, agentDriven: false, tab: 1) != ClientCertificates.queueKey(site: inHome, agentDriven: false, tab: 2),
                "tabs of two profiles are not asked once for both")
        var choices = RememberedChoices()
        choices.remember(candidate("Work"), forSite: inWork, agentDriven: false)
        #expect(choices.choice(forSite: inWork, agentDriven: false) == candidate("Work"))
        #expect(choices.choice(forSite: inHome, agentDriven: false) == nil)
        #expect(choices.choice(forSite: shared, agentDriven: false) == nil)
    }

    // MARK: Names a preference is looked up under, and what challenges share

    @Test func preferencesAreLookedUpByAddressThenHost() {
        #expect(ClientCertificates.preferenceNames(host: "mtls.example", port: 443) == ["https://mtls.example", "mtls.example"])
        #expect(ClientCertificates.preferenceNames(host: "mtls.example", port: 8443) == ["https://mtls.example:8443", "mtls.example"])
    }

    @Test func challengesForOneSiteShareAKeyRegardlessOfOrderAndCase() {
        let a = ClientCertificates.requestKey(host: "MTLS.example", port: 443, acceptedIssuers: [dn("One"), dn("Two")])
        #expect(a == ClientCertificates.requestKey(host: "mtls.example", port: 443, acceptedIssuers: [dn("Two"), dn("One")]))
        #expect(a != ClientCertificates.requestKey(host: "mtls.example", port: 8443, acceptedIssuers: [dn("One"), dn("Two")]))
        #expect(a != ClientCertificates.requestKey(host: "other.example", port: 443, acceptedIssuers: [dn("One"), dn("Two")]))
    }

    // MARK: What is remembered, and for whom

    @Test func theChoiceIsFiledUnderTheSiteOnlyInOrdinaryWindowsForPagesTheUserDrives() {
        #expect(ClientCertificates.domainToRemember(host: "mtls.example", port: 443, isPrivate: false, agentDriven: false) == "https://mtls.example")
        #expect(ClientCertificates.domainToRemember(host: "mtls.example", port: 8443, isPrivate: false, agentDriven: false) == "https://mtls.example:8443")
        #expect(ClientCertificates.domainToRemember(host: "mtls.example", port: 443, isPrivate: true, agentDriven: false) == nil, "a private window keeps nothing")
        #expect(ClientCertificates.domainToRemember(host: "mtls.example", port: 443, isPrivate: false, agentDriven: true) == nil, "nor does a page the AI drives")
        #expect(ClientCertificates.domainToRemember(host: "mtls.example", port: 443, isPrivate: true, agentDriven: true) == nil)
    }

    @Test func theNameTheChoiceIsFiledUnderIsOneThePreferenceIsLookedUpBy() {
        let name = ClientCertificates.domainToRemember(host: "mtls.example", port: 443, isPrivate: false, agentDriven: false)
        #expect(name.map { ClientCertificates.preferenceNames(host: "mtls.example", port: 443).contains($0) } == true)
    }

    @Test func challengesFromTheUserAndFromTheAIForOneSiteDoNotShareAnAnswer() {
        let site = ClientCertificates.requestKey(host: "mtls.example", port: 443, acceptedIssuers: [])
        let user = ClientCertificates.queueKey(site: site, agentDriven: false, tab: 1)
        #expect(user == ClientCertificates.queueKey(site: site, agentDriven: false, tab: 2), "the user's tabs share the panel")
        let ai = ClientCertificates.queueKey(site: site, agentDriven: true, tab: 1)
        #expect(ai != user, "the AI's tab does not join the user's panel")
        #expect(ai == ClientCertificates.queueKey(site: site, agentDriven: true, tab: 1), "the same tab's own challenges share")
        #expect(ai != ClientCertificates.queueKey(site: site, agentDriven: true, tab: 2), "another tab of the AI's gets its own")

        var queue = CertificatePromptQueue<String, Int>()
        queue.add(key: user, tab: 1, info: 0, waiter: "user")
        queue.add(key: ai, tab: 1, info: 0, waiter: "ai")
        queue.add(key: user, tab: 3, info: 0, waiter: "user too")
        queue.start(user)
        #expect(queue.finish(user) == ["user", "user too"], "the AI's tab does not get the user's choice")
        #expect(queue.entries.map(\.key) == [ai])
        queue.add(key: user, tab: 4, info: 0, waiter: "user later")
        queue.start(ai)
        #expect(queue.finish(ai) == ["ai"], "and the user's tab does not get one made on the AI's prompt")
    }

    @Test func aChoiceTheUserMadeIsNotGivenToTheAI() {
        var choices = RememberedChoices()
        choices.remember(candidate("Mine"), forSite: "site", agentDriven: false)
        #expect(choices.choice(forSite: "site", agentDriven: false) == candidate("Mine"))
        #expect(choices.choice(forSite: "site", agentDriven: true) == nil)
        #expect(choices.choice(forSite: "other", agentDriven: false) == nil)
    }

    @Test func aChoiceMadeOnThePromptOfTheAIIsNotKeptForTheUser() {
        var choices = RememberedChoices()
        choices.remember(candidate("Chosen"), forSite: "site", agentDriven: true)
        #expect(choices.choice(forSite: "site", agentDriven: false) == nil)
        #expect(choices.choice(forSite: "site", agentDriven: true) == nil)
        choices.remember(candidate("Mine"), forSite: "site", agentDriven: false)
        choices.remember(candidate("Chosen"), forSite: "site", agentDriven: true)
        #expect(choices.choice(forSite: "site", agentDriven: false) == candidate("Mine"), "it doesn't replace theirs either")
    }

    // MARK: Challenges waiting for the sheet

    @Test func aChallengeThatComesWhileTheSheetIsClosingIsAskedInANewOne() {
        var queue = CertificatePromptQueue<String, Int>()
        queue.add(key: "a", tab: 1, info: 0, waiter: "old")
        queue.start("a")
        let dropped = queue.drop(tab: 1)
        #expect(dropped.released == ["old"] && dropped.emptiedActive)
        // The sheet is on its way out (cancel) and another tab asks the same site.
        queue.add(key: "a", tab: 2, info: 1, waiter: "new")
        #expect(queue.next(isShown: { _ in true })?.key == "a", "waits for a sheet of its own")
        #expect(queue.next(isShown: { _ in true })?.info == 1)
        #expect(queue.isWaiting(tab: 2) && !queue.isWaiting(tab: 1))
        queue.start("a")
        #expect(queue.finish("a") == ["new"], "answered by the user, not by the cancel of the old sheet")
    }

    @Test func challengesForTheSameSiteWaitForOneAnswer() {
        var queue = CertificatePromptQueue<String, Int>()
        queue.add(key: "a", tab: 1, info: 0, waiter: "first")
        queue.add(key: "a", tab: 1, info: 9, waiter: "second")
        queue.add(key: "a", tab: 2, info: 9, waiter: "third")
        #expect(queue.entries.count == 1)
        #expect(queue.entries[0].info == 0, "the sheet is made for the first")
        queue.start("a")
        #expect(queue.finish("a") == ["first", "second", "third"])
        #expect(queue.entries.isEmpty && queue.activeKey == nil)
    }

    @Test func onlyOneSheetIsUpAtATimeAndTheNextFollowsTheAnswer() {
        var queue = CertificatePromptQueue<String, Int>()
        queue.add(key: "a", tab: 1, info: 0, waiter: "A")
        queue.add(key: "b", tab: 1, info: 0, waiter: "B")
        #expect(queue.next(isShown: { _ in true })?.key == "a")
        queue.start("a")
        #expect(queue.next(isShown: { _ in true }) == nil, "none while one is up, also for another site")
        queue.add(key: "a", tab: 1, info: 0, waiter: "A2")
        #expect(queue.finish("a") == ["A", "A2"])
        #expect(queue.next(isShown: { _ in true })?.key == "b")
    }

    @Test func aTabNobodyIsLookingAtWaitsUntilItIsShown() {
        var queue = CertificatePromptQueue<String, Int>()
        queue.add(key: "background", tab: 7, info: 0, waiter: "B")
        queue.add(key: "front", tab: 1, info: 0, waiter: "F")
        #expect(queue.next(isShown: { $0 == 1 })?.key == "front", "the one in front is asked first")
        queue.start("front")
        _ = queue.finish("front")
        #expect(queue.next(isShown: { $0 == 1 }) == nil, "the background one keeps waiting")
        #expect(queue.next(isShown: { $0 == 7 })?.key == "background", "and is asked once it is shown")
    }

    @Test func aSiteIsAskedOnceAnyOfItsTabsIsShown() {
        var queue = CertificatePromptQueue<String, Int>()
        queue.add(key: "a", tab: 7, info: 0, waiter: "back")
        queue.add(key: "a", tab: 1, info: 0, waiter: "front")
        #expect(queue.next(isShown: { $0 == 1 })?.key == "a")
    }

    @Test func aTabThatGoesAwayIsAnsweredAndItsEntryDropped() {
        var queue = CertificatePromptQueue<String, Int>()
        queue.add(key: "a", tab: 1, info: 0, waiter: "A1")
        queue.add(key: "b", tab: 2, info: 0, waiter: "B2")
        queue.add(key: "b", tab: 1, info: 0, waiter: "B1")
        let dropped = queue.drop(tab: 1)
        #expect(Set(dropped.released) == ["A1", "B1"] && !dropped.emptiedActive)
        #expect(queue.entries.map(\.key) == ["b"])
        #expect(queue.entries[0].waiters.map(\.waiter) == ["B2"])
    }

    @Test func theSheetOnScreenIsToldWhenNoOneIsLeftToAnswer() {
        var queue = CertificatePromptQueue<String, Int>()
        queue.add(key: "a", tab: 1, info: 0, waiter: "A1")
        queue.add(key: "a", tab: 2, info: 0, waiter: "A2")
        queue.start("a")
        #expect(!queue.drop(tab: 1).emptiedActive)
        let last = queue.drop(tab: 2)
        #expect(last.released == ["A2"] && last.emptiedActive)
        #expect(queue.finish("a").isEmpty && queue.activeKey == nil)
    }
}

struct ClientCertificateOfferTests {
    private func candidate(_ name: String, issuer: String = "Root", from: TimeInterval = -30, to: TimeInterval = 30, clientAuth: Bool = true) -> ClientCertificates.Candidate {
        var made = ClientCertificates.Candidate(id: name, name: name, issuers: [ClientCertificates.key(ofName: dn(issuer))], notBefore: now + from * day, notAfter: now + to * day, identity: nil)
        made.allowsClientAuthentication = clientAuth
        return made
    }

    /// The list a site sends is a guess at who can sign in: when it matches nothing the user is still offered every valid identity, not left with a feature that does nothing.
    @Test func aSiteWhoseListMatchesNothingIsOfferedEveryValidIdentity() {
        let all = [candidate("A", issuer: "One"), candidate("B", issuer: "Two"), candidate("Old", issuer: "One", to: -1)]
        let plan = ClientCertificates.plan(candidates: all, preferred: nil, remembered: nil, acceptedIssuers: [dn("Elsewhere")], now: now, situation: .init())
        #expect(plan == .ask([all[0], all[1]]), "the expired one is not offered")
        #expect(ClientCertificates.offered(all, acceptedIssuers: [dn("One")], now: now).map(\.name) == ["A"], "what matches is offered alone")
    }

    @Test func nothingValidMeansTheSiteIsVisitedWithoutOne() {
        let plan = ClientCertificates.plan(candidates: [candidate("Old", to: -1), candidate("Soon", from: 2, to: 30)], preferred: nil, remembered: nil,
                                           acceptedIssuers: [dn("Elsewhere")], now: now, situation: .init())
        #expect(plan == .continueWithout)
    }

    @Test func anIdentityThatIsOnlyForOtherUsesIsNotOffered() {
        let list = ClientCertificates.offered([candidate("Server", clientAuth: false), candidate("Person")], acceptedIssuers: [], now: now)
        #expect(list.map(\.name) == ["Person"])
        #expect(ClientCertificates.offered([candidate("Server", clientAuth: false)], acceptedIssuers: [dn("Root")], now: now).isEmpty)
    }

    @Test func aLoadThatBeginsKeepsTheChallengeOfItsOwnSiteAndDropsTheRest() {
        var queue = CertificatePromptQueue<String, String>()
        queue.add(key: "a", tab: 1, info: "a.test", waiter: "A")
        queue.add(key: "b", tab: 1, info: "b.test", waiter: "B")
        let dropped = queue.drop(tab: 1, keeping: { $0 == "a.test" })
        #expect(dropped.released == ["B"], "the old page's challenge goes, the one for the page now loading stays")
        #expect(queue.isWaiting(tab: 1) && queue.entries.map(\.key) == ["a"])
    }
}

// MARK: Against a real keychain

/// The calls that make a keychain file: deprecated, and the only way to keep a throwaway keychain out of the search list. They are looked up
/// by name so that the tests build without a warning.
private enum KeychainFile {
    typealias Create = @convention(c) (UnsafePointer<CChar>, UInt32, UnsafeRawPointer?, Bool, SecAccess?, UnsafeMutablePointer<SecKeychain?>) -> OSStatus
    typealias Delete = @convention(c) (SecKeychain) -> OSStatus

    static func create(at path: String, password: String) -> SecKeychain? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainCreate") else { return nil }
        var keychain: SecKeychain?
        let status = password.withCString { unsafeBitCast(symbol, to: Create.self)(path, UInt32(password.utf8.count), $0, false, nil, &keychain) }
        return status == errSecSuccess ? keychain : nil
    }

    static func delete(_ keychain: SecKeychain) {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecKeychainDelete") else { return }
        _ = unsafeBitCast(symbol, to: Delete.self)(keychain)
    }
}

private func openssl(_ arguments: [String], in folder: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = arguments
    process.currentDirectoryURL = folder
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

struct ClientCertificateKeychainTests {
    /// A throwaway authority and a client certificate it issued, in a keychain file of their own that is only ever named by reference:
    /// never in the search list, never the user's keychain.
    @Test func theQueryFindsAnIdentityAndFiltersItByIssuer() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("changmun-crt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #require(openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "30", "-subj", "/CN=Changmun Test CA/O=Test"], in: folder))
        try #require(openssl(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "client.key", "-out", "client.csr", "-subj", "/CN=Test Client/O=Test"], in: folder))
        try #require(openssl(["x509", "-req", "-in", "client.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "client.pem", "-days", "10"], in: folder))
        try #require(openssl(["pkcs12", "-export", "-inkey", "client.key", "-in", "client.pem", "-out", "client.p12", "-passout", "pass:test"], in: folder))

        let keychain = try #require(KeychainFile.create(at: folder.appendingPathComponent("test.keychain-db").path, password: "test"))
        defer { KeychainFile.delete(keychain) }
        var imported: CFArray?
        let options = [kSecImportExportPassphrase as String: "test", kSecImportExportKeychain as String: keychain] as CFDictionary
        let p12 = try Data(contentsOf: folder.appendingPathComponent("client.p12"))
        try #require(SecPKCS12Import(p12 as CFData, options, &imported) == errSecSuccess)

        let found = ClientCertificates.keychainIdentities(searchList: [keychain] as CFArray)
        let identity = try #require(found.first)
        #expect(ClientCertificates.identityExists(identity, searchList: [keychain] as CFArray), "it is held")
        #expect(found.count == 1 && identity.name == "Test Client" && identity.identity != nil)
        let now = Date()
        #expect(identity.notBefore <= now && now <= identity.notAfter)
        #expect(abs(identity.notAfter.timeIntervalSince(now) - 10 * day) < 2 * day, "the ten days it was issued for")

        // The CA's own certificate names the CA as its issuer too: that is the name a site would send.
        let caPEM = try String(contentsOf: folder.appendingPathComponent("ca.pem"), encoding: .utf8)
        let body = caPEM.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let caDER = try #require(Data(base64Encoded: body))
        let caName = try #require(ClientCertificates.fields(ofCertificate: caDER))
        #expect(ClientCertificates.usable(found, acceptedIssuers: [caName.issuer], now: now) == found)
        #expect(ClientCertificates.usable(found, acceptedIssuers: [dn("Some Other CA")], now: now).isEmpty)
        #expect(ClientCertificates.usable(found, acceptedIssuers: [caName.issuer], now: now + 40 * day).isEmpty, "after it ran out")

        // Taken away (as a smart card is), it is no longer held.
        KeychainFile.delete(keychain)
        #expect(!ClientCertificates.identityExists(identity, searchList: [keychain] as CFArray))
        #expect(!ClientCertificates.identityExists(identity))
    }

    /// A certificate issued by an intermediate, which a site that names the root accepts only if the chain is known: the intermediate kept beside the identity
    /// ties it to the root, and is what the site is sent with it. Without it the identity is below nothing the site named.
    @Test func anIdentityBelowAnIntermediateIsTiedToTheRootAndBringsTheIntermediate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("changmun-crt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #require(openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "root.key", "-out", "root.pem", "-days", "30", "-subj", "/CN=Test Root"], in: folder))
        try #require(openssl(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "inter.key", "-out", "inter.csr", "-subj", "/CN=Test Intermediate"], in: folder))
        try "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n".write(to: folder.appendingPathComponent("ca.ext"), atomically: true, encoding: .utf8)
        try #require(openssl(["x509", "-req", "-in", "inter.csr", "-CA", "root.pem", "-CAkey", "root.key", "-CAcreateserial", "-out", "inter.pem", "-days", "20", "-extfile", "ca.ext"], in: folder))
        try #require(openssl(["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "client.key", "-out", "client.csr", "-subj", "/CN=Staff Member"], in: folder))
        try #require(openssl(["x509", "-req", "-in", "client.csr", "-CA", "inter.pem", "-CAkey", "inter.key", "-CAcreateserial", "-out", "client.pem", "-days", "10"], in: folder))
        // One file with the intermediate, one without.
        try #require(openssl(["pkcs12", "-export", "-inkey", "client.key", "-in", "client.pem", "-certfile", "inter.pem", "-out", "with.p12", "-passout", "pass:test"], in: folder))
        try #require(openssl(["pkcs12", "-export", "-inkey", "client.key", "-in", "client.pem", "-out", "without.p12", "-passout", "pass:test"], in: folder))
        let rootName = try #require(ClientCertificates.fields(ofCertificate: try der(of: "root.pem", in: folder))).issuer

        func identity(from p12: String) throws -> (found: ClientCertificates.Candidate, release: () -> Void) {
            let keychain = try #require(KeychainFile.create(at: folder.appendingPathComponent("\(p12).keychain-db").path, password: "test"))
            var imported: CFArray?
            let options = [kSecImportExportPassphrase as String: "test", kSecImportExportKeychain as String: keychain] as CFDictionary
            try #require(SecPKCS12Import(try Data(contentsOf: folder.appendingPathComponent(p12)) as CFData, options, &imported) == errSecSuccess)
            let found = try #require(ClientCertificates.keychainIdentities(searchList: [keychain] as CFArray).first)
            return (found, { KeychainFile.delete(keychain) })
        }
        let with = try identity(from: "with.p12")
        defer { with.release() }
        #expect(ClientCertificates.usable([with.found], acceptedIssuers: [rootName], now: Date()).count == 1, "tied to the root through the intermediate beside it")
        #expect(with.found.intermediates.count == 1, "and the intermediate is what the site is sent")
        #expect(with.found.allowsClientAuthentication, "no extended key usage says any")

        let without = try identity(from: "without.p12")
        defer { without.release() }
        #expect(ClientCertificates.usable([without.found], acceptedIssuers: [rootName], now: Date()).isEmpty, "nothing ties it to the root")
        #expect(without.found.intermediates.isEmpty)
        // The list that matches nothing still offers it (the site has the last word).
        #expect(ClientCertificates.offered([without.found], acceptedIssuers: [rootName], now: Date()).count == 1)
    }

    @Test func theExtendedKeyUsagesOfACertificateAreReadFromIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("changmun-crt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func make(_ name: String, _ usage: String?) throws -> Data {
            var arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "\(name).key", "-out", "\(name).pem", "-days", "5", "-subj", "/CN=\(name)"]
            if let usage { arguments += ["-addext", "extendedKeyUsage=\(usage)"] }
            try #require(openssl(arguments, in: folder))
            return try der(of: "\(name).pem", in: folder)
        }
        #expect(ClientCertificates.extendedKeyUsages(ofCertificate: try make("none", nil)) == nil, "none listed means any")
        #expect(ClientCertificates.extendedKeyUsages(ofCertificate: try make("client", "clientAuth")) == [ClientCertificates.clientAuthentication])
        let server = try #require(ClientCertificates.extendedKeyUsages(ofCertificate: try make("server", "serverAuth")))
        #expect(!server.isEmpty && !server.contains(ClientCertificates.clientAuthentication), "a server certificate is not for clients")
        let both = try #require(ClientCertificates.extendedKeyUsages(ofCertificate: try make("both", "serverAuth,clientAuth,codeSigning")))
        #expect(both.count == 3 && both.contains(ClientCertificates.clientAuthentication))
        #expect(ClientCertificates.extendedKeyUsages(ofCertificate: try make("any", "anyExtendedKeyUsage")) == [ClientCertificates.anyExtendedKeyUsage])
    }

    private func der(of file: String, in folder: URL) throws -> Data {
        let pem = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
        return try #require(Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()))
    }
}
