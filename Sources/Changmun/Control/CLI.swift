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
      changmun screenshot [--labels] [--tab N] [-o file.jpg]
                                             --labels draws each element's number over it, as `read` numbers them
      changmun call <tool> [json]            any tool by name, with JSON arguments
      changmun tools                         the tools and their arguments, as JSON
      changmun headless start|stop|status    a second, invisible Changmun with a profile of its own (below)
      changmun --headless <command>          any command above, in that headless Changmun (`changmun --mcp --headless` for MCP)

    Without --tab, a command acts on the tab the user is looking at. Changmun starts if it isn't running.
    Asking for something new (another site, typing after reading other sites) may ask the user first.

    The headless Changmun has no window, takes no focus and makes no sound. Its profile is separate (none of your cookies, history
    or passwords), it asks nothing and allows everything, except what looks like paying, ordering, sending, posting or deleting,
    which it refuses because it needs a person. `--headless` commands start it if it isn't running; `headless status` exits 1 if not.
    """

    /// What `Changmun` was started to do: a mode flag counts only as the first argument, so a `--mcp` further along (a word to type,
    /// say) can't turn a `--cli` run into the MCP server.
    enum LaunchMode: Equatable {
        case app, cli, mcp

        static func of(_ arguments: [String]) -> LaunchMode {
            switch arguments.count > 1 ? arguments[1] : nil {
            case "--cli": return .cli
            case "--mcp": return .mcp
            default: return .app
            }
        }
    }

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
            case .headlessCall(let name, let args, let output):
                exit(show(ControlClient.call(name, args.mapValues(\.base), caller: "cli", headless: true), saveImageTo: output))
            case .headless(let verb):
                exit(runHeadless(verb))
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
        /// The same, in the user's headless Changmun (`--headless`).
        case headlessCall(String, [String: AnyHashable], output: String?)
        case headless(HeadlessVerb)
    }

    enum HeadlessVerb: String, Equatable {
        case start, stop, status
    }

    /// `changmun headless start | stop | status`. Returns the exit status.
    static func runHeadless(_ verb: HeadlessVerb) -> Int32 {
        switch verb {
        case .start:
            do {
                let wasRunning = UserHeadless.endpoint() != nil
                let endpoint = try UserHeadless.start(from: ControlClient.ownBundle)
                print((wasRunning ? "already running" : "started") + " (pid \(endpoint.pid)); profile: \(UserHeadless.folder.path)")
                if wasRunning, let hint = UserHeadless.updateHint(installed: ControlClient.ownBundle.flatMap(UserHeadless.info(ofApp:)), installedApp: ControlClient.ownBundle, running: true) { print(hint) }
                return 0
            } catch {
                let message = (error as? UserHeadless.Failure)?.message ?? error.localizedDescription
                FileHandle.standardError.write(Data("changmun: couldn't start the headless Changmun: \(message)\n".utf8))
                return 1
            }
        case .stop:
            switch UserHeadless.stop() {
            case .notRunning: print("not running")
            case .stopped: print("stopped")
            case .stillRunning(let pid):
                FileHandle.standardError.write(Data("changmun: the headless Changmun (pid \(pid)) is still running\n".utf8))
                return 1
            }
            return 0
        case .status:
            let installed = ControlClient.ownBundle.flatMap(UserHeadless.info(ofApp:))
            let status = UserHeadless.status(installed: installed, installedApp: ControlClient.ownBundle)
            print(status.text)
            return status.running ? 0 : 1
        }
    }

    /// The commands each flag is for.
    private static let appliesTo: [String: Set<String>] = {
        let onATab: Set<String> = ["show", "close", "go", "back", "forward", "reload", "read", "click", "click-at", "type", "press", "select", "hover", "drag", "wait", "scroll", "screenshot", "call"]
        var table: [String: Set<String>] = ["--tab": onATab, "--max": ["read", "read-tabs"], "-o": ["screenshot", "call"], "--output": ["screenshot", "call"],
                                            "--submit": ["type"], "--labels": ["screenshot"], "--gone": ["wait"], "--timeout": ["wait"], "--element": ["press"]]
        for modifier in AgentKey.modifierNames { table["--" + modifier] = ["press"] }
        return table
    }()

    /// How many words each command takes, and what to say when there are more: a word that did nothing (`reload 3` reloads the tab
    /// in front, not tab 3) is a mistake, not something to skip. The commands left out take free text or as many as they are given.
    private static let operandLimits: [String: (count: Int, hint: String)] = {
        let tab = "it acts on the tab in front; --tab N picks another"
        return [
            "tabs": (0, "it lists every tab"), "tools": (0, "it lists every tool"),
            "back": (0, tab), "forward": (0, tab), "reload": (0, tab),
            "read": (0, "\(tab); --max N limits the text"),
            "screenshot": (0, "\(tab); -o file.jpg names the file"),
            "show": (1, "it takes one tab number"), "close": (1, "it takes one tab number"),
            "click": (1, "it takes one element number from `changmun read`; to click a point use `changmun click-at <x> <y>`"),
            "hover": (1, "it takes one element number from `changmun read`"),
            "click-at": (2, "it takes x and y"),
            "scroll": (1, "it takes one of down, up, top, bottom; \(tab)"),
        ]
    }()

    /// The commands whose operands are free text, where a word that looks like a flag may be part of it.
    private static let freeText: Set<String> = ["open", "go", "type", "select", "wait"]

    /// The command line as a tool call. Flags may come anywhere after the command. `--headless` sends the tool call to the user's
    /// headless Changmun: before the command, or after it where no free text could include the word (a `type 3 --headless`
    /// is refused, not guessed at: sent to the browser in use, a command meant for the headless one would act on the wrong browser).
    static func parse(_ arguments: [String]) throws -> Command {
        var headless = false
        let command = try parseTool(arguments, headless: &headless)
        guard headless else { return command }
        switch command {
        case .call(let name, let args, let output): return .headlessCall(name, args, output: output)
        case .help, .tools, .headlessCall: return command
        case .headless: throw UsageError(message: "--headless doesn't apply to headless")
        }
    }

    private static func parseTool(_ arguments: [String], headless: inout Bool) throws -> Command {
        var words: [String] = []
        var tab: Int?, max: Int?, output: String?, submit = false, labels = false, gone = false, element: Int?, timeout: Double?
        var modifiers: [String] = []
        var flags: [String] = []
        var rest = arguments.makeIterator()
        while let word = rest.next() {
            if word.hasPrefix("-"), word.count > 1, appliesTo[word] != nil { flags.append(word) }
            switch word {
            case "--headless":
                if let command = words.first, freeText.contains(command) {
                    throw UsageError(message: "--headless goes before \(command) (changmun --headless \(command) …); to use the word itself, give it to `changmun call`")
                }
                headless = true
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
            case "--labels":
                labels = true
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
        if let limit = operandLimits[name], operands.count > limit.count {
            throw UsageError(message: "\(name) doesn't take “\(operands.dropFirst(limit.count).joined(separator: " "))”: \(limit.hint)")
        }
        if ["show", "close"].contains(name), tab != nil, !operands.isEmpty {
            throw UsageError(message: "\(name) takes the tab once: `\(name) 3` or `\(name) --tab 3`")
        }
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
        case "headless":
            guard operands.count == 1, let verb = HeadlessVerb(rawValue: operands[0]) else { throw UsageError(message: "headless needs start, stop or status") }
            return .headless(verb)
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
        case "screenshot":
            if labels { args["labels"] = true }
            return .call("screenshot", args, output: output)
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

    /// Where the `index`th (from 0) image of one call goes. A name given with -o is used as it is for the first image and gets
    /// -2, -3… before its extension for the others. Without one it is changmun-<milliseconds>.<ext>, with -2, -3… when the file is
    /// there already (two screenshots in one millisecond, or several images in one reply): none overwrites another.
    static func imagePath(output: String?, ext: String, index: Int, now: Date = Date(),
                          exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        func numbered(_ stem: String, _ n: Int, _ ext: String) -> String { n == 1 ? "\(stem).\(ext)" : "\(stem)-\(n).\(ext)" }
        if let output {
            guard index > 0 else { return output }
            let url = URL(fileURLWithPath: output)
            let stem = url.pathExtension.isEmpty ? output : String(output.dropLast(url.pathExtension.count + 1))
            return numbered(stem, index + 1, url.pathExtension.isEmpty ? ext : url.pathExtension)
        }
        let stem = "changmun-\(Int(now.timeIntervalSince1970 * 1000))"
        var n = index + 1
        while exists(numbered(stem, n, ext)) { n += 1 }
        return numbered(stem, n, ext)
    }

    /// Prints the tool's text; an image is saved to a file whose path is printed. Returns the exit status.
    static func show(_ result: [String: Any], saveImageTo output: String?) -> Int32 {
        let failed = result["isError"] as? Bool ?? false
        var images = 0
        for item in result["content"] as? [[String: Any]] ?? [] {
            if let text = item["text"] as? String {
                if failed { FileHandle.standardError.write(Data((text + "\n").utf8)) } else { print(text) }
            } else if item["type"] as? String == "image", let base64 = item["data"] as? String, let data = Data(base64Encoded: base64) {
                let ext = (item["mimeType"] as? String) == "image/png" ? "png" : "jpg"
                let path = imagePath(output: output, ext: ext, index: images)
                images += 1
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
