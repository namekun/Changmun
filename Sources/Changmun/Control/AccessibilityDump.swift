import AppKit
import ApplicationServices
import Foundation
import Network

/// The accessibility tree of a window as VoiceOver would meet it, read in the app's own process (no accessibility permission is needed to ask
/// one's own objects): the test copy's `POST /accessibility` answers with it, and scripts/audit-accessibility.sh checks it.
///
/// SwiftUI builds its tree lazily, when something asks for it. Asking an element for `accessibilityChildren` is enough, so the walk
/// asks every level; a node's attributes are read the way an accessibility client reads them, through `accessibilityAttributeValue:`.
@MainActor
enum AccessibilityDump {
    /// Pages draw in a process of their own and are the website's, not the app's: the walk stops at a web view.
    private static let stop: [String] = ["WKWebView", "WKFlippedView", "WKWebViewContentView"]
    static let maxNodes = 4000

    private static var awake = false

    /// SwiftUI draws up its accessibility elements only once an accessibility client has asked the app for them, and it keeps them after. The app
    /// asks itself, as a client does: this needs no permission (the app's own process is not another's), and must not run on the main thread,
    /// which answers the question.
    static func wake(_ window: NSWindow) async {
        if !awake {
            awake = true
            _ = await Task.detached {
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXChildrenAttribute as CFString, &value)
            }.value
        }
        // The elements are drawn up on the next turns of the main loop: a walk asks for them, and the walk that follows a moment later reads them.
        _ = tree(of: window)
        try? await Task.sleep(for: .milliseconds(300))
    }

    static func tree(of window: NSWindow) -> [String: Any] {
        var budget = maxNodes
        let root = window.contentView.map { node(for: $0, depth: 0, budget: &budget) } ?? [:]
        return ["window": window.title, "root": root, "nodes": maxNodes - budget]
    }

    /// The popovers and sheets over a window are windows of their own.
    static func attached(to window: NSWindow) -> [[String: Any]] {
        let sheets = window.sheets
        let popovers = NSApp.windows.filter { $0 !== window && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        return (sheets + popovers).map { tree(of: $0) }
    }

    /// What an element says for an attribute, asked as AppKit's accessibility server asks: the method of the NSAccessibility protocol
    /// first (SwiftUI's elements and its hosting view answer there), then the older attribute call (some AppKit controls only answer there).
    private static func ask(_ object: NSObject, method: String, attribute: String) -> Any? {
        let selector = NSSelectorFromString(method)
        if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() { return value }
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard object.responds(to: legacy) else { return nil }
        return object.perform(legacy, with: attribute)?.takeUnretainedValue()
    }

    /// A yes-or-no attribute: `getter` is the method (isAccessibilityEnabled), `key` the property it reads (accessibilityEnabled).
    private static func flag(_ object: NSObject, getter: String, key: String) -> Bool? {
        guard object.responds(to: NSSelectorFromString(getter)) else { return nil }
        return (object.value(forKey: key) as? NSNumber)?.boolValue
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        case let attributed as NSAttributedString: attributed.string
        default: nil
        }
    }

    private static func node(for object: Any, depth: Int, budget: inout Int) -> [String: Any] {
        budget -= 1
        guard let object = object as? NSObject else { return ["role": "?"] }
        var node: [String: Any] = ["class": String(describing: type(of: object))]
        func put(_ key: String, _ method: String, _ attribute: String) {
            if let text = string(ask(object, method: method, attribute: attribute)), !text.isEmpty { node[key] = text }
        }
        put("role", "accessibilityRole", "AXRole")
        put("subrole", "accessibilitySubrole", "AXSubrole")
        put("label", "accessibilityLabel", "AXDescription")
        put("title", "accessibilityTitle", "AXTitle")
        put("value", "accessibilityValue", "AXValue")
        if node["value"] == nil { put("value", "accessibilityValueDescription", "AXValueDescription") }
        // A control that another element (the text beside it) names: VoiceOver reads that element's words as the control's name.
        if node["label"] == nil, node["title"] == nil, let owner = ask(object, method: "accessibilityTitleUIElement", attribute: "AXTitleUIElement") as? NSObject {
            for (method, attribute) in [("accessibilityValue", "AXValue"), ("accessibilityLabel", "AXDescription"), ("accessibilityTitle", "AXTitle")] {
                if let text = string(ask(owner, method: method, attribute: attribute)), !text.isEmpty { node["titleElement"] = text; break }
            }
        }
        put("help", "accessibilityHelp", "AXHelp")
        put("placeholder", "accessibilityPlaceholderValue", "AXPlaceholderValue")
        put("identifier", "accessibilityIdentifier", "AXIdentifier")
        if let enabled = flag(object, getter: "isAccessibilityEnabled", key: "accessibilityEnabled") { node["enabled"] = enabled }
        if let selected = flag(object, getter: "isAccessibilitySelected", key: "accessibilitySelected") { node["selected"] = selected }
        // A rectangle isn't an object: it can only be read through key-value coding, which boxes it.
        if object.responds(to: NSSelectorFromString("accessibilityFrame")), let frame = object.value(forKey: "accessibilityFrame") as? NSValue {
            let rect = frame.rectValue
            node["frame"] = [Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height)]
        }
        let actionNames = NSSelectorFromString("accessibilityActionNames")
        if object.responds(to: actionNames), let actions = object.perform(actionNames)?.takeUnretainedValue() as? [String], !actions.isEmpty {
            node["actions"] = actions
        }
        if object.responds(to: NSSelectorFromString("accessibilityPerformPress")) { node["canPress"] = true }
        // What the element does besides pressing: the actions VoiceOver lists in its actions rotor, by name.
        let custom = NSSelectorFromString("accessibilityCustomActions")
        if object.responds(to: custom), let actions = object.perform(custom)?.takeUnretainedValue() as? [NSAccessibilityCustomAction], !actions.isEmpty {
            node["customActions"] = actions.map(\.name)
        }
        let name = String(describing: type(of: object))
        guard depth < 60, budget > 0, !stop.contains(where: { name.contains($0) }) else { return node }
        var children = ask(object, method: "accessibilityChildren", attribute: "AXChildren") as? [Any] ?? []
        if children.isEmpty, let older = object.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: "AXChildren")?.takeUnretainedValue() as? [Any] { children = older }
        guard !children.isEmpty else { return node }
        var kids: [[String: Any]] = []
        for child in children where budget > 0 { kids.append(Self.node(for: child, depth: depth + 1, budget: &budget)) }
        node["children"] = kids
        return node
    }
}

extension ControlServer {
    /// Tests only: the accessibility tree of the front window ("window": "front", the default) or the settings window ("settings"), with the
    /// popovers and sheets that are over it. The answer is {"trees": [...]}, the window's first, the announcements made so far ("announcements",
    /// the last few) and the class of what has the keyboard ("firstResponder"). "flash" shows a status message in the front window, "undo" one that
    /// offers to be taken back, as the browser's own do; "approval" puts a question of the AI on a card in its panel (true) or takes it away (false).
    func handleAccessibilityRequest(_ request: HTTPRequest, on connection: NWConnection) -> Bool {
        guard Headless.isTestCopy, request.method == "POST", request.path == "/accessibility" else { return false }
        let body = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
        Task { @MainActor in
            let window = body["window"] as? String == "settings" ? Panels.window("settings") : Browser.current?.window
            guard let window else { return self.respond(connection, status: "404 Not Found", body: ["error": "no window"]) }
            // "approval": puts a question of the AI on a card in the front window's panel (true) or takes it away (false), answered by nobody.
            if let on = body["approval"] as? Bool {
                if on, let browser = Browser.current {
                    let id = UUID()
                    let prompt = Approvals.Prompt(message: "Let the AI type into this page?", detail: "hello world", choices: [.deny, .once, .site])
                    let buttons: [(Approvals.Choice, String)] = [(.deny, String(localized: "Don’t Allow")), (.once, String(localized: "Allow Once")), (.site, String(localized: "Allow on \("example.com") for This Chat"))]
                    ApprovalCards.shared.add(ApprovalCards.Card(id: id, prompt: prompt, buttons: buttons, browser: browser, answer: { _ in ApprovalCards.shared.remove(id) }, moveToSheet: {}))
                } else {
                    for card in ApprovalCards.shared.cards { ApprovalCards.shared.remove(card.id) }
                }
            }
            if let text = body["flash"] as? String { Browser.current?.flashStatus(text) }
            if let text = body["undo"] as? String { Browser.current?.offerUndo(text) {} }
            await AccessibilityDump.wake(window)
            self.respond(connection, status: "200 OK", body: ["trees": [AccessibilityDump.tree(of: window)] + AccessibilityDump.attached(to: window),
                                                              "announcements": Announcer.recent, "firstResponder": String(describing: window.firstResponder.map { type(of: $0) })])
        }
        return true
    }
}
