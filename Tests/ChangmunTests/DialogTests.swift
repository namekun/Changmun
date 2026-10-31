import Foundation
import Testing
import WebKit
@testable import Changmun

/// The one dialog: which button Return and Esc press, how each button is drawn, and that what the dialogs say of a site, an app or an
/// extension is cleaned and cut. The sheet itself is looked at end to end by scripts/test-dialogs.sh.
@MainActor
struct DialogTests {
    private let cancel = DialogButton(title: "Cancel", role: .cancel)
    private let normal = DialogButton(title: "OK")
    private let destructive = DialogButton(title: "Delete", role: .destructive)

    private func spec(_ buttons: [DialogButton]) -> DialogSpec { DialogSpec(title: "T", buttons: buttons) }

    @Test func returnPressesTheSafeChoiceAndEscTheCancel() {
        let ask = spec([DialogButton(title: "Cancel", role: .cancel, isDefault: true), normal])
        #expect(ask.button(for: .return) == 0)
        #expect(ask.button(for: .escape) == 0)
        let signIn = spec([cancel, DialogButton(title: "Sign In", isDefault: true)])
        #expect(signIn.button(for: .return) == 1)
        #expect(signIn.button(for: .escape) == 0)
    }

    @Test func aDestructiveButtonIsNeverWhatReturnPresses() {
        let marked = spec([cancel, DialogButton(title: "Delete", role: .destructive, isDefault: true)])
        #expect(marked.button(for: .return) == 0, "marking a destructive button as the default does not make it one")
        let unmarked = spec([cancel, destructive])
        #expect(unmarked.button(for: .return) == 0)
        #expect(unmarked.button(for: .escape) == 0)
        #expect(spec([destructive, cancel]).button(for: .return) == 1)
    }

    @Test func withNoneMarkedReturnPressesTheLastButtonThatIsNotACancel() {
        #expect(spec([cancel, normal]).button(for: .return) == 1)
        #expect(spec([normal, cancel]).button(for: .return) == 0)
        #expect(spec([cancel]).button(for: .return) == 0)
        #expect(spec([]).button(for: .return) == nil)
    }

    @Test func aNoticeWithOneButtonIsClosedByEscAndReturn() {
        let close = spec([normal])
        #expect(close.button(for: .escape) == 0)
        #expect(close.button(for: .return) == 0)
        #expect(spec([normal, DialogButton(title: "Other")]).button(for: .escape) == nil, "two answers and no cancel: Esc does not choose one")
    }

    @Test func theFilledButtonIsAlwaysTheOneReturnPressesAndDeletingIsRed() {
        let delete = DialogSpec.confirmDelete("Delete?", "It goes.")
        #expect(delete.buttons.map(\.role) == [.cancel, .destructive])
        #expect(delete.style(of: 0) == .primary)
        #expect(delete.style(of: 1) == .danger)
        let three = spec([DialogButton(title: "Deny", role: .cancel, isDefault: true), normal, DialogButton(title: "Site")])
        #expect((0..<3).map(three.style(of:)) == [.primary, .secondary, .secondary])
        #expect(three.style(of: 7) == .secondary)
    }

    @Test func deleteDialogsAsktheSafeQuestionFirst() {
        let delete = DialogSpec.confirmDelete("Delete the folder “Work”?", "Its 3 bookmarks go with it.")
        #expect(delete.button(for: .return) == 0)
        #expect(delete.buttons[0].title == String(localized: "Cancel"))
        #expect(delete.buttons[1].title == String(localized: "Delete"))
    }

    @Test func theAppLinkAsksWithCancelAsTheDefaultAndTheAddressInTheBox() {
        let url = URL(string: "claude://login/callback?code=1")!
        let ask = AppLinks.spec(site: "claude.ai", app: "Claude", url: url)
        #expect(ask.title == String(localized: "Open Claude?"))
        #expect(ask.message == String(localized: "claude.ai wants to open the app."))
        #expect(ask.detail == .text("claude://login/callback?code=1"))
        #expect(ask.button(for: .return) == 0 && ask.buttons[0].role == .cancel)
        #expect(ask.style(of: 0) == .primary && ask.style(of: 1) == .secondary)
    }

    @Test func theCameraAsksBlockAsTheDefaultAndRemembersOnlyOutsidePrivateWindows() {
        let ask = SitePermissions.spec(host: "meet.example", type: .camera, remember: true)
        #expect(ask.buttons.map(\.title) == [String(localized: "Block"), String(localized: "Allow")])
        #expect(ask.button(for: .return) == 0)
        #expect(ask.button(for: .escape) == 0)
        #expect(ask.remember == String(localized: "Remember for this site"))
        #expect(SitePermissions.spec(host: "meet.example", type: .camera, remember: false).remember == nil, "a private window never offers to keep the answer")
        #expect(SitePermissions.spec(host: "a.example", type: .microphone, remember: true).title != SitePermissions.spec(host: "a.example", type: .camera, remember: true).title)
    }

    @Test func theLoginKeepsItsPasswordSecretAndReturnSignsIn() {
        let ask = Tab.signInSpec(host: "intranet.example", failed: false, user: "namkun")
        #expect(ask.fields.map(\.isSecure) == [false, true])
        #expect(ask.fields.map(\.text) == ["namkun", ""])
        #expect(ask.button(for: .return) == 1)
        #expect(ask.button(for: .escape) == 0)
        #expect(Tab.signInSpec(host: "h", failed: true, user: "").message == String(localized: "The user name or password is incorrect."))
        #expect(!String(describing: ask).contains("password-value"), "nothing typed is in the spec")
    }

    @Test func aNameFromOutsideIsCleanedAndCut() {
        #expect(DialogSpec.name("meet.example") == "meet.example")
        let hidden = DialogSpec.name("evil\u{202E}moc.example")
        #expect(!hidden.unicodeScalars.contains("\u{202E}"), "a right-to-left override does not reorder the name")
        let long = DialogSpec.name(String(repeating: "a", count: 500))
        #expect(long.count <= 61 && long.hasSuffix("…"))
        let spec = AppLinks.spec(site: String(repeating: "s", count: 400), app: String(repeating: "x\u{202E}", count: 200), url: URL(string: "https://example.com/?" + String(repeating: "q", count: 900))!)
        #expect(spec.title.count < 120 && !spec.title.unicodeScalars.contains("\u{202E}"))
        #expect(spec.message.map { $0.count < 120 } == true)
    }

    @Test func aLongAddressIsShownWholeOrSaysHowMuchIsLeftOut() {
        let middle = "SECRET-IN-THE-MIDDLE"
        let url = URL(string: "claude://x/?" + String(repeating: "a", count: 300) + middle + String(repeating: "b", count: 300))!
        guard case .text(let shown)? = AppLinks.spec(site: "claude.ai", app: "Claude", url: url).detail else { Issue.record("the address is in the wrapped, scrollable box"); return }
        #expect(shown.contains(middle), "the middle of the address is not cut out")
        let huge = URL(string: "claude://x/?" + String(repeating: "a", count: 3000))!
        guard case .text(let note)? = AppLinks.spec(site: "claude.ai", app: "Claude", url: huge).detail else { Issue.record("a text"); return }
        #expect(note.count < 1100 && note.contains("2"), "what is left out is counted: \(note.suffix(60))")
    }

    @Test func aHostIsCutFromTheLeftSoTheRealDomainStaysInSight() {
        #expect(DialogSpec.host("meet.example") == "meet.example")
        let disguised = "accounts.bank.example." + String(repeating: "a", count: 120) + ".evil.example"
        let shown = DialogSpec.host(disguised)
        #expect(shown.hasPrefix("…") && shown.hasSuffix(".evil.example"), Comment(rawValue: shown))
        #expect(!shown.contains("bank"))
        #expect(shown.count <= 49)
        #expect(!DialogSpec.host("evil\u{202E}moc.example").unicodeScalars.contains("\u{202E}"))
        #expect(DialogSpec.host(String(repeating: "x.", count: 400) + "evil.example").hasSuffix("x.evil.example"))
        // Every dialog that names a site names it this way.
        #expect(SitePermissions.spec(host: disguised, type: .camera, remember: true).title.contains(".evil.example"))
        #expect(Tab.signInSpec(host: disguised, failed: false, user: "").title.hasSuffix(".evil.example"))
        #expect(AppLinks.spec(site: disguised, app: "Claude", url: URL(string: "claude://x")!).message?.contains(".evil.example wants") == true)
    }

    // MARK: Questions that others start

    @Test func aQuestionAPageOrTheAIStartsIsGuardedAndOneTheUserStartedIsNot() {
        #expect(SitePermissions.spec(host: "a.example", type: .camera, remember: true).guarded)
        #expect(AppLinks.spec(site: "a.example", app: "App", url: URL(string: "app://x")!).guarded)
        #expect(Tab.signInSpec(host: "a.example", failed: false, user: "").guarded)
        #expect(ExtensionPrompt.askSpec("t", items: ["https://a.example/*"]).guarded)
        #expect(ExtensionPrompt.permissionsSpec(name: "X", hosts: [], permissions: ["tabs"], updating: true).guarded)
        #expect(ChatLinks.confirmSpec(URL(string: "https://a.example/x")!).guarded)
        #expect(!DialogSpec.confirmDelete("Delete?", "It goes.").guarded, "the user's own deleting waits for nothing")
        #expect(!ExtensionPrompt.permissionsSpec(name: "X", hosts: [], permissions: ["tabs"], updating: false).guarded, "turning an extension on is the user's own doing")
    }

    @Test func theSafeButtonIsAlwaysLiveAndTheOthersWaitForTheDelay() {
        let shown = Date(timeIntervalSince1970: 1000)
        func may(_ safe: Bool, guarded: Bool = true, down: Double? = nil, up: Double? = nil, key: (Double, Bool)? = nil, now: Double) -> Bool {
            DialogGate.mayPress(guarded: guarded, safe: safe, shownAt: shown, mouseDownAt: down.map { shown + $0 }, mouseUpAt: up.map { shown + $0 },
                                keyDown: key.map { (shown + $0.0, $0.1) }, now: shown + now)
        }
        #expect(may(true, now: 0.01), "the safe choice is live at once")
        #expect(may(false, guarded: false, now: 0.01), "nothing guarded, nothing to wait for")
        #expect(!may(false, down: 0.1, up: 0.15, now: 0.2), "a click before the delay is not an answer")
        #expect(!may(false, down: 0.3, up: 0.6, now: 0.62), "a press that began before the delay ended, though it came up after it, is not one either")
        #expect(may(false, down: 0.7, up: 0.78, now: 0.8), "a click that began after the delay is")
        #expect(!may(false, key: (0.2, false), now: 0.2), "Return or Space within the delay is not")
        #expect(may(false, key: (0.9, false), now: 0.9))
        #expect(!may(false, key: (0.9, true), now: 0.9), "a key held down does not answer again and again")
        #expect(!DialogGate.mayPress(guarded: true, safe: false, shownAt: nil, mouseDownAt: nil, mouseUpAt: nil, keyDown: nil, now: Date()), "not on screen yet")
    }

    @Test func theCancelIsTheSafeButtonAndNothingElseIs() {
        let camera = SitePermissions.spec(host: "a.example", type: .camera, remember: true)
        #expect(camera.isSafe(0) && !camera.isSafe(1) && !camera.isSafe(5))
        let login = Tab.signInSpec(host: "a.example", failed: false, user: "")
        #expect(login.isSafe(0) && !login.isSafe(1), "Sign In is not safe though Return presses it")
    }

    @Test func aPageWithNoHostIsCalledThisPage() {
        #expect(DialogSpec.host("") == String(localized: "This page"))
        #expect(SitePermissions.spec(host: "", type: .camera, remember: true).title.hasPrefix(String(localized: "This page")))
        #expect(Tab.signInSpec(host: "", failed: false, user: "").title == String(localized: "Sign in to this page"))
        #expect(!Tab.signInSpec(host: "", failed: false, user: "").title.hasPrefix(" "))
    }

    @Test func aQuestionFromATabInTheBackgroundSaysSo() {
        #expect(SitePermissions.spec(host: "a.example", type: .camera, remember: true, background: true).note == String(localized: "From a tab in the background"))
        #expect(SitePermissions.spec(host: "a.example", type: .camera, remember: true).note == nil)
        #expect(Tab.signInSpec(host: "a.example", failed: false, user: "", background: true).note == String(localized: "From a tab in the background"))
        #expect(Tab.signInSpec(host: "a.example", failed: false, user: "").note == nil)
    }

    @Test func aLinkOfTheChatThatIsTooLongSaysItWasCut() {
        let long = URL(string: "https://a.example/?" + String(repeating: "q", count: 3000))!
        guard case .text(let shown)? = ChatLinks.confirmSpec(long).detail else { Issue.record("the address is in the box"); return }
        #expect(shown.count < 1100 && shown != String(shown.prefix(1000)), "a note says how much was left out")
    }

    @Test func permissionsComeBeforeALongListOfSites() {
        let hosts = (0..<200).map { "https://site\($0).example/*" }
        let spec = ExtensionPrompt.permissionsSpec(name: "X", hosts: hosts, permissions: ["tabs", "cookies"], updating: false)
        guard case .text(let text)? = spec.detail else { Issue.record("a box"); return }
        #expect(text.hasPrefix(String(localized: "Permissions: cookies, tabs")), "first in the box, above the fold")
        #expect(text.contains("https://site199.example/*"))
    }

    @Test func theSiteButtonOfAnApprovalCarriesTheEndOfALongHost() {
        let long = "accounts.bank.example." + String(repeating: "a", count: 200) + ".evil.example"
        let title = String(localized: "Allow on \(DialogSpec.host(long)) for This Chat")
        #expect(title.hasSuffix("for This Chat") && title.contains(".evil.example") && title.count < 120)
    }


    @Test func onlyTheUsersOwnNoIsRememberedForTheRestOfThePageLoad() async {
        func answer(_ result: DialogResult?) async -> SitePermissions.Answer {
            await SitePermissions.shared.decide(host: "never-seen.example", type: .camera, remember: false) { _, _ in result }
        }
        let block = await answer(DialogResult(button: 0, fields: [], remembered: false, picked: 0))
        #expect(block.decision == .deny && block.blockedByUser)
        let allow = await answer(DialogResult(button: 1, fields: [], remembered: false, picked: 0))
        #expect(allow.decision == .grant && !allow.blockedByUser)
        let refused = await answer(nil)
        #expect(refused.decision == .deny && !refused.blockedByUser, "a question that was refused or taken back is no reason to stop asking")
        #expect(SitePermissions.key(host: "a.example", type: .camera) != SitePermissions.key(host: "a.example", type: .microphone))
        #expect(SitePermissions.key(host: "a.example", type: .camera).group == SitePermissions.key(host: "a.example", type: .microphone).group)
    }
}
