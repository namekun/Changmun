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

    @Test func deletingIsRedACancelIsGreyAndThereIsOneStrongButton() {
        let delete = DialogSpec.confirmDelete("Delete?", "It goes.")
        #expect(delete.buttons.map(\.role) == [.cancel, .destructive])
        #expect(delete.style(of: 0) == .secondary)
        #expect(delete.style(of: 1) == .danger)
        let three = spec([DialogButton(title: "Deny", role: .cancel, isDefault: true), normal, DialogButton(title: "Site")])
        #expect((0..<3).map(three.style(of:)) == [.secondary, .primary, .secondary])
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
        #expect(ask.detail == .address("claude://login/callback?code=1"))
        #expect(ask.button(for: .return) == 0 && ask.buttons[0].role == .cancel)
        #expect(ask.style(of: 1) == .primary)
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
        if case .address(let address) = spec.detail { #expect(address.count <= 301) } else { Issue.record("the address is shown as an address") }
    }
}
