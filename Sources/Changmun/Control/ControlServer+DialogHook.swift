import AppKit
import Foundation
import Network
import WebKit

/// What the test copy's dialogs have answered, newest last: "name: button N" or "name: none".
@MainActor
enum DialogTestState {
    static var answers: [String] = []
}

extension ControlServer {
    /// Tests only: shows one of the app's dialogs on the front window, as the code that asks it builds it. "resize" sets the window's content size ([width, height], for looking at the page when it is narrow). "show" is delete-folder, delete-source, delete-space, app-link,
    /// camera, microphone, camera-microphone, sign-in, sign-in-failed, extension-turn-on, extension-update, extension-ask, chat-link, hostile (names a page chose, to see
    /// them cut), approval-card (the panel opens and the question is a card there), approval-sheet or approval-accounts (a sheet; questions are held until released
    /// through `/approvals`). "key" presses a key in the sheet ({"chars": "\r", "keyCode": 36}), "type" types into what has the keyboard, "end" ends the sheet as a
    /// click on its default button would not (the asker takes it back), "shot": true answers with a picture of the sheet (or the window, with no sheet) as "png".
    /// The answer says whether a sheet is up, its title, buttons and the default button, and the answers so far.
    func handleDialogTestRequest(_ request: HTTPRequest, on connection: NWConnection) -> Bool {
        guard Headless.isTestCopy, request.method == "POST", request.path == "/dialog",
              let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { return false }
        Task { @MainActor in
            guard let browser = Browser.current, let window = browser.window else {
                return self.respond(connection, status: "404 Not Found", body: ["error": "no window"])
            }
            if body["clear"] as? Bool == true { DialogTestState.answers = [] }
            if let size = body["resize"] as? [Double], size.count == 2 { window.setContentSize(NSSize(width: size[0], height: size[1])) }
            if let name = body["show"] as? String {
                guard DialogTestHook.show(name, on: browser) else { return self.respond(connection, status: "400 Bad Request", body: ["error": "unknown dialog"]) }
                try? await Task.sleep(for: .milliseconds(body["wait"] as? Int ?? 400))
            }
            if let key = body["key"] as? [String: Any], let chars = key["chars"] as? String {
                let target = window.attachedSheet ?? window
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: target.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                                       isARepeat: false, keyCode: UInt16(key["keyCode"] as? Int ?? 0)) else { continue }
                    NSApp.sendEvent(event)
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            if let text = body["type"] as? String, let target = window.attachedSheet {
                for character in text {
                    let chars = String(character)
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                           windowNumber: target.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                                           isARepeat: false, keyCode: 0) else { continue }
                        NSApp.sendEvent(event)
                    }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            if body["end"] as? Bool == true, let sheet = window.attachedSheet {
                window.endSheet(sheet)
                try? await Task.sleep(for: .milliseconds(300))
            }
            var answer: [String: Any] = ["sheet": window.attachedSheet != nil, "sheetTitle": window.attachedSheet?.title ?? "", "answers": DialogTestState.answers]
            if let spec = DialogTestHook.current {
                answer["title"] = spec.title
                answer["message"] = spec.message ?? ""
                answer["buttons"] = spec.buttons.map(\.title)
                answer["default"] = spec.defaultIndex ?? -1
                answer["cancel"] = spec.cancelIndex ?? -1
            }
            if body["shot"] as? Bool == true {
                let target = window.attachedSheet ?? window
                if let png = await WindowImage.png(of: target) { answer["png"] = png.base64EncodedString() }
            }
            self.respond(connection, status: "200 OK", body: answer)
        }
        return true
    }
}

/// Builds the dialogs the way their askers do, for the test copy.
@MainActor
enum DialogTestHook {
    /// The spec of the dialog last shown through the hook.
    static var current: DialogSpec?

    static func show(_ name: String, on browser: Browser) -> Bool {
        guard let window = browser.window else { return false }
        let url = URL(string: "claude://login/callback?code=0123456789abcdef&state=fedcba9876543210&redirect=https%3A%2F%2Fclaude.ai%2Fapp%2Fhome%3Fsession%3Dabcdef0123456789")!
        let hostile = "evil\u{202E}moc.example" + String(repeating: ".very-long-label", count: 12)
        var spec: DialogSpec
        var whenBusy = Dialog.WhenBusy.wait
        switch name {
        case "delete-folder": spec = .confirmDelete(String(localized: "Delete the folder “\(DialogSpec.name("Work"))”?"), String(localized: "Its \(12) bookmarks go with it. This can't be undone."))
        case "delete-source": spec = .confirmDelete(String(localized: "Delete all bookmarks imported from \(DialogSpec.name("Chrome"))?"), String(localized: "They all go, and this can't be undone."))
        case "delete-space": spec = .confirmDelete(String(localized: "Delete the space “\(DialogSpec.name("Study"))”?"), String(localized: "Its tabs are closed. Its favorites move to “\(DialogSpec.name("Personal"))”. Bookmarks stay in the library."))
        case "app-link": spec = AppLinks.spec(site: "claude.ai", app: "Claude", url: url); whenBusy = .refuse
        case "camera": spec = SitePermissions.spec(host: "meet.example", type: .camera, remember: true); whenBusy = .refuse
        case "microphone": spec = SitePermissions.spec(host: "meet.example", type: .microphone, remember: true); whenBusy = .refuse
        case "camera-microphone": spec = SitePermissions.spec(host: "meet.example", type: .cameraAndMicrophone, remember: true); whenBusy = .refuse
        case "sign-in": spec = Tab.signInSpec(host: "intranet.example", failed: false, user: ""); whenBusy = .refuse
        case "sign-in-failed": spec = Tab.signInSpec(host: "intranet.example", failed: true, user: "namkun"); whenBusy = .refuse
        case "hostile":
            spec = AppLinks.spec(site: hostile, app: hostile, url: URL(string: "https://example.com/?" + String(repeating: "a", count: 600))!); whenBusy = .refuse
        case "chat-link":
            spec = DialogSpec(title: String(localized: "Open a link to \(DialogSpec.host("example.com"))?"),
                              message: String(localized: "This chat has read other sites, and a page could have slipped this link in to send what the AI read there."),
                              detail: .text(url.absoluteString),
                              buttons: [DialogButton(title: String(localized: "Cancel"), role: .cancel, isDefault: true), DialogButton(title: String(localized: "Open"))])
        case "extension-turn-on", "extension-update", "extension-ask":
            switch name {
            case "extension-turn-on": spec = ExtensionPrompt.permissionsSpec(name: "Dark Reader", hosts: ["<all_urls>"], permissions: ["activeTab", "storage", "tabs"], updating: false)
            case "extension-update": spec = ExtensionPrompt.permissionsSpec(name: "Dark Reader", hosts: ["https://example.com/*", "https://www.example.com/*"], permissions: ["cookies"], updating: true)
            default: spec = ExtensionPrompt.askSpec(String(localized: "'\(DialogSpec.name("Dark Reader"))' wants to access this site"), items: ["https://example.com/*", "https://www.example.com/*", "*://*.com/*"])
            }
        case "approval-card", "approval-sheet", "approval-accounts":
            guard let tab = browser.active else { return false }
            Approvals.headless.holds = true
            if name == "approval-card" { browser.showChat = true } else { browser.showChat = false }
            Task { @MainActor in
                switch name {
                case "approval-card": _ = await Approvals.allowAction(.low, "Accept all cookies", on: tab, caller: ChatStore.caller)
                case "approval-sheet": _ = await Approvals.allowAction(.high, "Pay now", on: tab, caller: ChatStore.caller)
                default: _ = await Approvals.allowSignIn(host: "github.com", accounts: ["namkun@example.com", "work@example.com", ""], page: nil, caller: ChatStore.caller)
                }
            }
            current = nil
            return true
        default: return false
        }
        current = spec
        Task {
            let answer = await Dialog.present(in: window, spec, whenBusy: whenBusy)
            DialogTestState.answers.append("\(name): " + (answer.map { "button \($0.button)" + ($0.remembered ? " remembered" : "") + ($0.fields.isEmpty ? "" : " fields \($0.fields.count)") } ?? "none"))
        }
        return true
    }
}
