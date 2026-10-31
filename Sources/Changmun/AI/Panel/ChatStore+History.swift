import AppKit
import SwiftUI

extension ChatStore {
    // MARK: History and retry

    /// Keeps the conversation as it stands for the History list, unless the user has turned that off or a private window was in front.
    func persist() {
        guard Preferences.shared.aiKeepHistory, !privateChat else { return }
        history.record(id: recordID, started: recordStarted, items: items)
    }

    /// Sends the user's last message again after a failure, in the same chat: the failed row goes, the message is not shown twice.
    /// The session of a failed run can't be resumed, so the AI is told that this is a new conversation when the chat had earlier messages. The pictures the message went with go again.
    func retryLast() {
        guard !isRunning, let error = items.lastIndex(where: { $0.kind == .error }),
              let asked = items[..<error].last(where: { $0.kind == .user }) else { return }
        let message = asked.text
        let earlier = items.filter { $0.kind == .user }.count > 1
        items.remove(at: error)
        let lost = sessionID == nil && earlier ? " Earlier messages of this chat are not available to you; use list_tabs and read_page to see the browser as it is." : ""
        send(message, resumeNote: "[Note: the previous attempt at this message failed, so the user is asking again.\(lost)]", images: asked.images, noting: false)
    }

    /// The turn (the count of the user's messages so far) a step belongs to.
    private var turn: Int { items.filter { $0.kind == .user }.count }

    /// A tab the AI just closed went to the browser's closed tabs; remembered so the turn can offer to bring it back.
    func noteClosed(_ id: UUID, in browser: Browser) {
        closedByAI[turn, default: []].append(ClosedByAI(browser: browser, id: id))
    }

    func canReopen(turn: Int) -> Bool {
        closedByAI[turn]?.contains { closed in closed.browser?.closedTabs.contains { $0.id == closed.id } == true } ?? false
    }

    /// Brings back the tabs the AI closed in a turn that are still among the closed tabs, the last closed first so they return in place.
    func reopenClosed(turn: Int) {
        for closed in (closedByAI.removeValue(forKey: turn) ?? []).reversed() { closed.browser?.reopenClosedTab(id: closed.id) }
    }

    /// Tests only: puts a conversation into the panel as it would be after a run.
    func load(_ items: [ChatItem]) {
        self.items = items
    }

    static func symbol(tool: String) -> String {
        switch tool {
        case "read_page": "doc.text"
        case "read_tabs": "doc.on.doc"
        case "read_structured": "curlybraces"
        case "read_markdown": "doc.richtext"
        case "list_tabs", "switch_tab": "square.on.square"
        case "open_tab", "navigate": "arrow.up.right"
        case "close_tab": "xmark"
        case "click": "cursorarrow.click"
        case "type_text": "keyboard"
        case "click_at": "scope"
        case "press_key": "command"
        case "select_option": "list.bullet"
        case "hover": "cursorarrow.motionlines"
        case "drag": "arrow.up.and.down.and.arrow.left.and.right"
        case "sign_in": "key"
        case "wait_for": "hourglass"
        case "scroll": "arrow.down"
        case "screenshot": "camera.viewfinder"
        case "go_back": "chevron.left"
        case "go_forward": "chevron.right"
        case "reload": "arrow.clockwise"
        default: "wrench.and.screwdriver"
        }
    }

    static func describe(tool: String, input: [String: Any]) -> String {
        let element = (input["element_id"] as? Int).map { " [\($0)]" } ?? ""
        switch tool {
        case "read_page": return String(localized: "Read page")
        case "read_tabs": return String(localized: "Read tabs")
        case "read_structured": return String(localized: "Read page data")
        case "read_markdown": return String(localized: "Read page as Markdown")
        case "list_tabs": return String(localized: "Check tab list")
        case "open_tab": return String(localized: "Open new tab · \(input["url"] as? String ?? "")")
        case "navigate": return String(localized: "Go to · \(input["url"] as? String ?? "")")
        case "switch_tab": return String(localized: "Switch tab")
        case "close_tab": return String(localized: "Close tab")
        case "click": return String(localized: "Click") + element
        case "type_text": return String(localized: "Type") + element + " · " + (input["text"] as? String ?? "")
        case "click_at": return String(localized: "Click at \(ToolCatalog.pixels(input["x"])), \(ToolCatalog.pixels(input["y"]))")
        case "press_key": return String(localized: "Press \(input["key"] as? String ?? "")")
        case "select_option": return String(localized: "Choose") + element + " · " + (input["option"] as? String ?? "")
        case "hover": return String(localized: "Hover") + element
        case "drag": return String(localized: "Drag") + " " + [input["from_element_id"], input["to_element_id"]].map { ($0 as? Int).map { "[\($0)]" } ?? "…" }.joined(separator: " → ")
        case "sign_in": return String(localized: "Sign in with saved login")
        case "wait_for": return String(localized: "Wait") + ((input["text"] as? String).map { " · " + $0 } ?? "")
        case "scroll": return String(localized: "Scroll · \(input["direction"] as? String ?? "")")
        case "screenshot": return String(localized: "View screen")
        case "go_back": return String(localized: "Back")
        case "go_forward": return String(localized: "Forward")
        case "reload": return String(localized: "Reload")
        default: return tool
        }
    }
}
