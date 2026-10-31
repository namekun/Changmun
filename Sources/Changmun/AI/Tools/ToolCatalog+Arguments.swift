import AppKit
import WebKit

extension ToolCatalog {
    static let unreachableFrame = ToolResult.text("Error: that part of the page is a frame from another site that Changmun couldn't reach. Use the rest of the page, or tell the user.", error: true)
    static let stopped = ToolResult.text("Stopped: the user stopped it, or it took too long.", error: true)

    static func number(_ value: Any?) -> Double? {
        let number: Double?
        switch value {
        case let v as Int: number = Double(v)
        case let v as Double: number = v
        case let v as String: number = Double(v.trimmingCharacters(in: .whitespaces))
        default: number = nil
        }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    /// A coordinate for display, kept to a sane range.
    static func pixels(_ value: Any?) -> Int {
        Int(min(max(number(value) ?? 0, 0), 1_000_000))
    }

    /// What is wrong with the arguments of the tools that act on the page, before any tab is touched.
    static func validate(_ name: String, _ args: [String: Any]) -> String? {
        func hasElement(_ key: String) -> Bool { args[key] != nil && int(args[key]) != nil }
        func hasPoint(_ prefix: String) -> Bool {
            guard let x = number(args[prefix + "x"]), let y = number(args[prefix + "y"]) else { return false }
            return x >= 0 && y >= 0 && x < 1_000_000 && y < 1_000_000
        }
        switch name {
        case "press_key":
            guard AgentKey.name(args["key"]) != nil else { return "key must be one of: " + AgentKey.names.joined(separator: ", ") + "." }
            guard AgentKey.modifiers(args["modifiers"]) != nil else { return "modifiers must be a list of: " + AgentKey.modifierNames.joined(separator: ", ") + "." }
            if args["element_id"] != nil && !hasElement("element_id") { return "element_id must be a number." }
        case "select_option":
            guard hasElement("element_id"), let option = args["option"] as? String, !option.isEmpty else { return "element_id and option are required." }
        case "hover":
            guard hasElement("element_id") else { return "element_id is required." }
        case "click_at":
            guard hasPoint("") else { return "x and y are required: CSS pixels from the top left of the visible page, as in a screenshot." }
        case "wait_for":
            // Text made only of what the page's own search treats as space (JavaScript's \s: also U+FEFF) is found everywhere.
            if let text = args["text"], (text as? String)?.unicodeScalars.contains(where: { !$0.properties.isWhitespace && $0 != "\u{FEFF}" }) != true { return "text must be a non-empty string." }
            if args["gone"] != nil && args["gone"] as? Bool == nil { return "gone must be true or false." }
            if args["gone"] as? Bool == true && args["text"] == nil { return "gone needs the text to wait for to disappear." }
            if args["timeout"] != nil && number(args["timeout"]).map({ $0 > 0 }) != true { return "timeout must be a number of seconds." }
        case "read_markdown":
            if args["max_chars"] != nil && int(args["max_chars"]) == nil { return "max_chars must be a number." }
        case "sign_in":
            if args["element_id"] != nil && !hasElement("element_id") { return "element_id must be a number." }
        case "screenshot":
            if args["labels"] != nil && args["labels"] as? Bool == nil { return "labels must be true or false." }
        case "drag":
            guard hasElement("from_element_id") != hasPoint("from_"), hasElement("to_element_id") != hasPoint("to_") else {
                return "Give where to drag from and where to drop: from_element_id or from_x and from_y, and to_element_id or to_x and to_y."
            }
        default:
            break
        }
        return nil
    }
}
