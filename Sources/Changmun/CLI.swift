import Foundation

/// `changmun …` (the script in the app's Resources, linked onto the PATH by Homebrew): the browser tools from a
/// shell, for people and for AI agents that can run commands. Each command is one tool call to the running app,
/// the same ones MCP offers, under the same approvals.
enum CLI {
    static let usage = """
    changmun: use the Changmun browser from the command line.

      changmun tabs                          list the open tabs (* is the one shown)
      changmun open <url or words>           open a new tab and wait for it to load
      changmun show <tab>                    show a tab
      changmun close <tab>                   close a tab
      changmun go <url or words> [--tab N]   load a page in a tab
      changmun back | forward | reload [--tab N]
      changmun read [--tab N] [--max N]      the page's text and its numbered elements
      changmun read-tabs <tab>… [--max N]    several tabs' text in one call
      changmun click <element> [--tab N]     click an element numbered by `read`
      changmun click-at <x> <y> [--tab N]    click a point of the visible page (CSS pixels, as in `screenshot`)
      changmun type <element> <text> [--submit] [--tab N]
      changmun press <key> [--element N] [--shift] [--alt] [--ctrl] [--meta] [--tab N]
                                             Enter, Escape, Tab, Backspace, Delete, Space, arrows, Home, End, PageUp, PageDown
      changmun select <element> <option>     choose an option of a select list
      changmun hover <element> [--tab N]
      changmun drag <from> <to> [--tab N]    each an element number or x,y
      changmun wait [text] [--gone] [--timeout N] [--tab N]   until the text shows (or goes), else until the page has loaded
      changmun scroll down|up|top|bottom [--tab N]
      changmun screenshot [--tab N] [-o file.jpg]
      changmun call <tool> [json]            any tool by name, with JSON arguments
      changmun tools                         the tools and their arguments, as JSON

    Without --tab, a command acts on the tab the user is looking at. Changmun starts if it isn't running.
    Asking for something new (another site, typing after reading other sites) may ask the user first.
    """

    static func run(_ arguments: [String]) -> Never {
        do {
            let command = try parse(arguments)
            switch command {
            case .help:
                print(usage)
                exit(0)
            case .tools:
                let data = try JSONSerialization.data(withJSONObject: ToolCatalog.definitions, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                exit(0)
            case .call(let name, let args, let output):
                // One caller for every command: what one command read still counts when the next one types.
                exit(show(ControlClient.call(name, args.mapValues(\.base), caller: "cli"), saveImageTo: output))
            }
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("changmun: \(error.message)\n\nRun `changmun help` for the commands.\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("changmun: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    struct UsageError: Error { let message: String }

    enum Command: Equatable {
        case help, tools
        case call(String, [String: AnyHashable], output: String?)
    }

    /// The commands each flag is for.
    private static let appliesTo: [String: Set<String>] = {
        let onATab: Set<String> = ["show", "close", "go", "back", "forward", "reload", "read", "click", "click-at", "type", "press", "select", "hover", "drag", "wait", "scroll", "screenshot", "call"]
        var table: [String: Set<String>] = ["--tab": onATab, "--max": ["read", "read-tabs"], "-o": ["screenshot", "call"], "--output": ["screenshot", "call"],
                                            "--submit": ["type"], "--gone": ["wait"], "--timeout": ["wait"], "--element": ["press"]]
        for modifier in AgentKey.modifierNames { table["--" + modifier] = ["press"] }
        return table
    }()

    /// The command line as a tool call. Flags may come anywhere after the command.
    static func parse(_ arguments: [String]) throws -> Command {
        var words: [String] = []
        var tab: Int?, max: Int?, output: String?, submit = false, gone = false, element: Int?, timeout: Double?
        var modifiers: [String] = []
        var flags: [String] = []
        var rest = arguments.makeIterator()
        while let word = rest.next() {
            if word.hasPrefix("-"), word.count > 1, appliesTo[word] != nil { flags.append(word) }
            switch word {
            case "--tab":
                guard let value = rest.next(), let id = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) else { throw UsageError(message: "--tab needs a tab number") }
                tab = id
            case "--max":
                guard let value = rest.next(), let number = Int(value), number > 0 else { throw UsageError(message: "--max needs a number") }
                max = number
            case "-o", "--output":
                guard let value = rest.next() else { throw UsageError(message: "-o needs a file name") }
                output = value
            case "--submit":
                submit = true
            case "--gone":
                gone = true
            case "--shift", "--alt", "--ctrl", "--meta":
                modifiers.append(String(word.dropFirst(2)))
            case "--element":
                guard let value = rest.next(), let id = Int(value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) else { throw UsageError(message: "--element needs an element number") }
                element = id
            case "--timeout":
                guard let value = rest.next(), let seconds = Double(value), seconds > 0, seconds.isFinite else { throw UsageError(message: "--timeout needs a number of seconds") }
                timeout = seconds
            default:
                words.append(word)
            }
        }
        guard let name = words.first else { return .help }
        // A flag a command has no use for is a mistake (a --submit that did nothing is a form not sent), not something to skip.
        for flag in flags where appliesTo[flag]?.contains(name) == false {
            throw UsageError(message: "\(flag) doesn't apply to \(name)")
        }
        let operands = Array(words.dropFirst())
        var args: [String: AnyHashable] = [:]
        if let tab { args["tab_id"] = tab }

        func number(_ index: Int, _ what: String) throws -> Int {
            guard operands.indices.contains(index), let value = Int(operands[index].trimmingCharacters(in: CharacterSet(charactersIn: "#"))) else {
                throw UsageError(message: "\(name) needs \(what)")
            }
            return value
        }
        func text(from index: Int, _ what: String) throws -> String {
            let joined = operands.dropFirst(index).joined(separator: " ")
            guard !joined.isEmpty else { throw UsageError(message: "\(name) needs \(what)") }
            return joined
        }

        switch name {
        case "help", "-h", "--help": return .help
        case "tools": return .tools
        case "tabs": return .call("list_tabs", [:], output: nil)
        case "open": return .call("open_tab", ["url": try text(from: 0, "a URL or search words")], output: nil)
        case "show": return .call("switch_tab", ["tab_id": try tab ?? number(0, "a tab number")], output: nil)
        case "close": return .call("close_tab", ["tab_id": try tab ?? number(0, "a tab number")], output: nil)
        case "go":
            args["url"] = try text(from: 0, "a URL or search words")
            return .call("navigate", args, output: nil)
        case "back": return .call("go_back", args, output: nil)
        case "forward": return .call("go_forward", args, output: nil)
        case "reload": return .call("reload", args, output: nil)
        case "read":
            if let max { args["max_chars"] = max }
            return .call("read_page", args, output: nil)
        case "read-tabs":
            if operands.isEmpty { throw UsageError(message: "read-tabs needs tab numbers") }
            args["tab_ids"] = try operands.indices.map { try number($0, "tab numbers") }
            args["tab_id"] = nil
            if let max { args["max_chars"] = max }
            return .call("read_tabs", args, output: nil)
        case "click":
            args["element_id"] = try number(0, "an element number from `changmun read`")
            return .call("click", args, output: nil)
        case "type":
            args["element_id"] = try number(0, "an element number and the text")
            args["text"] = try text(from: 1, "the text to type")
            if submit { args["submit"] = true }
            return .call("type_text", args, output: nil)
        case "click-at":
            guard operands.count == 2, let x = Double(operands[0]), let y = Double(operands[1]), x >= 0, y >= 0, x.isFinite, y.isFinite else {
                throw UsageError(message: "click-at needs x and y, in CSS pixels from the top left of the visible page")
            }
            args["x"] = x
            args["y"] = y
            return .call("click_at", args, output: nil)
        case "press":
            guard operands.count == 1, let key = AgentKey.name(operands[0]) else {
                throw UsageError(message: "press needs one key: " + AgentKey.names.joined(separator: ", "))
            }
            args["key"] = key
            if !modifiers.isEmpty { args["modifiers"] = modifiers }
            if let element { args["element_id"] = element }
            return .call("press_key", args, output: nil)
        case "select":
            args["element_id"] = try number(0, "an element number and an option")
            args["option"] = try text(from: 1, "the option's text or value")
            return .call("select_option", args, output: nil)
        case "hover":
            args["element_id"] = try number(0, "an element number from `changmun read`")
            return .call("hover", args, output: nil)
        case "drag":
            guard operands.count == 2 else { throw UsageError(message: "drag needs where from and where to: an element number or x,y for each") }
            for (prefix, operand) in zip(["from_", "to_"], operands) {
                let parts = operand.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
                if parts.count == 2, let x = parts[0], let y = parts[1], x >= 0, y >= 0, x.isFinite, y.isFinite {
                    args[prefix + "x"] = x
                    args[prefix + "y"] = y
                } else if parts.count == 1, let id = Int(operand.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) {
                    args[prefix + "element_id"] = id
                } else {
                    throw UsageError(message: "drag needs an element number or x,y, not “\(operand)”")
                }
            }
            return .call("drag", args, output: nil)
        case "wait":
            if !operands.isEmpty { args["text"] = operands.joined(separator: " ") }
            if gone {
                guard args["text"] != nil else { throw UsageError(message: "--gone needs the text to wait for to disappear") }
                args["gone"] = true
            }
            if let timeout { args["timeout"] = timeout }
            return .call("wait_for", args, output: nil)
        case "scroll":
            guard let direction = operands.first, ["down", "up", "top", "bottom"].contains(direction) else {
                throw UsageError(message: "scroll needs down, up, top or bottom")
            }
            args["direction"] = direction
            return .call("scroll", args, output: nil)
        case "screenshot": return .call("screenshot", args, output: output)
        case "call":
            guard let tool = operands.first else { throw UsageError(message: "call needs a tool name (see `changmun tools`)") }
            var given = args
            if operands.count > 1 {
                guard let data = operands.dropFirst().joined(separator: " ").data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw UsageError(message: "call's arguments must be a JSON object")
                }
                for (key, value) in json { if let value = value as? AnyHashable { given[key] = value } }
            }
            return .call(tool, given, output: output)
        default:
            throw UsageError(message: "unknown command “\(name)”")
        }
    }

    /// Prints the tool's text; an image is saved to a file whose path is printed. Returns the exit status.
    static func show(_ result: [String: Any], saveImageTo output: String?) -> Int32 {
        let failed = result["isError"] as? Bool ?? false
        for item in result["content"] as? [[String: Any]] ?? [] {
            if let text = item["text"] as? String {
                if failed { FileHandle.standardError.write(Data((text + "\n").utf8)) } else { print(text) }
            } else if item["type"] as? String == "image", let base64 = item["data"] as? String, let data = Data(base64Encoded: base64) {
                let ext = (item["mimeType"] as? String) == "image/png" ? "png" : "jpg"
                let path = output ?? "changmun-\(Int(Date().timeIntervalSince1970)).\(ext)"
                do {
                    try data.write(to: URL(fileURLWithPath: path))
                    print(path)
                } catch {
                    FileHandle.standardError.write(Data("changmun: couldn't save \(path): \(error.localizedDescription)\n".utf8))
                    return 1
                }
            }
        }
        return failed ? 1 : 0
    }
}
