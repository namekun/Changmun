import AppKit
import SwiftUI

extension ChatStore {
    // MARK: Stream events

    func receive(_ event: [String: Any], run: UUID) {
        guard run == runID else { return }
        handle(event)
    }

    /// An action that asks the user every time is shown without the AI's title on its step, on the chip that is there and on one that
    /// comes later.
    func hideTitle(_ title: String?) {
        guard let title else { return }
        hiddenTitles.insert(title)
        for index in items.indices where items[index].kind == .tool && items[index].title == title { items[index].title = nil }
    }

    func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "system":
            if let id = event["session_id"] as? String { sessionID = id }
        case "stream_event":
            steerRetry = nil
            guard let inner = event["event"] as? [String: Any] else { return }
            switch inner["type"] as? String {
            case "message_start":
                currentMessage = (inner["message"] as? [String: Any])?["id"] as? String
                streamingIndex = nil
            case "content_block_start":
                streamingIndex = nil
            case "content_block_delta":
                guard let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String else { return }
                if let currentMessage { streamedMessages.insert(currentMessage) }
                appendAssistant(text)
            default:
                break
            }
        case "assistant":
            steerRetry = nil
            guard let message = event["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            let streamed = (message["id"] as? String).map(streamedMessages.contains) ?? false
            if event["is_api_error_message"] as? Bool == true {
                // An API error arrives as an assistant message ("Not logged in · Please run /login"); the result after it is the error row.
                // Its usage is all zeros, made up by the CLI: no request held that, so the ring keeps what the last real one did.
                apiError = (event["error"] as? String, content.compactMap { $0["text"] as? String }.joined(separator: "\n"))
                return
            }
            // What this request held is how full the conversation is.
            if let usage = message["usage"] as? [String: Any], let tokens = ContextUsage.tokens(in: usage) { noteContext(tokens) }
            for block in content {
                switch block["type"] as? String {
                case "text" where !streamed:
                    if let text = block["text"] as? String, !text.isEmpty {
                        streamingIndex = nil
                        appendAssistant(text)
                    }
                case "tool_use":
                    streamingIndex = nil
                    let name = (block["name"] as? String ?? "").replacingOccurrences(of: "mcp__changmun__", with: "")
                    let input = block["input"] as? [String: Any] ?? [:], described = Self.describe(tool: name, input: input)
                    // Signing in is decided on the app's words alone.
                    let title = name == "sign_in" ? nil : ToolCatalog.stepTitle(input["title"]).flatMap { hiddenTitles.contains($0) ? nil : $0 }
                    let step = ChatItem(kind: .tool, text: described, symbol: Self.symbol(tool: name), title: title, tool: name)
                    if let id = block["id"] as? String { steps[id] = step.id }
                    items.append(step)
                default:
                    break
                }
            }
        case "user":
            // The results of the tools the AI called: each step is marked with how it went.
            guard let message = event["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return }
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, let stepID = steps.removeValue(forKey: id),
                      let index = items.firstIndex(where: { $0.id == stepID }) else { continue }
                items[index].outcome = StepOutcome.of(error: block["is_error"] as? Bool == true, text: Self.text(of: block["content"]))
            }
        case "result":
            if let id = event["session_id"] as? String { sessionID = id }
            if let window = (event["modelUsage"] as? [String: Any]).flatMap(ContextUsage.window(inModelUsage:)) {
                contextWindow = window
                if let used = contextUsage?.used { noteContext(used) }
            }
            // A run whose requests were not seen one by one (no usage in them) is counted by the result's total.
            if contextUsage == nil, let usage = event["usage"] as? [String: Any], let tokens = ContextUsage.tokens(in: usage) { noteContext(tokens) }
            if event["is_error"] as? Bool == true {
                // A session that failed may not resume; the next message starts a fresh one, which may run on another model with another window.
                sessionID = nil
                contextWindow = nil
                if steerRetry != nil {
                    // The resumed session never answered: endRun sends the message again in a new conversation.
                    runFailed = true
                } else {
                    fail(event["result"] as? String ?? String(localized: "The AI request failed."), code: apiError?.code, status: event["api_error_status"] as? Int)
                }
            } else {
                steerRetry = nil
            }
            streamingIndex = nil
        default:
            break
        }
    }

    func noteContext(_ tokens: Int) {
        let usage = ContextUsage(used: tokens, window: contextWindow ?? ContextUsage.defaultWindow)
        if usage != contextUsage { contextUsage = usage }
    }

    private func appendAssistant(_ text: String) {
        if let index = streamingIndex, items.indices.contains(index), items[index].kind == .assistant {
            items[index].text += text
        } else {
            items.append(ChatItem(kind: .assistant, text: text))
            streamingIndex = items.count - 1
        }
    }

    /// The most of what `claude` said that is shown and kept with an error: the end of it, where the cause is.
    nonisolated static let maxErrorBytes = 4096

    nonisolated static func capped(_ text: String, bytes: Int = maxErrorBytes) -> String {
        guard text.utf8.count > bytes else { return text }
        // A character cut in half at the start is left out, not shown broken.
        let tail = String(decoding: text.utf8.suffix(bytes), as: UTF8.self)
        return "…" + (tail.first == "\u{FFFD}" ? String(tail.dropFirst()) : tail)
    }

    func fail(_ text: String, kind: AIErrorKind? = nil, code: String? = nil, status: Int? = nil) {
        let text = Self.capped(text)
        runFailed = true
        var failure = AIFailure.classify(text, code: code, status: status)
        if let kind { failure.kind = kind }
        items.append(ChatItem(kind: .error, text: text, failure: failure))
        isRunning = false
        step = nil
        AgentActivity.shared.cancel(caller: Self.caller)
    }

    /// The words of a tool result's content, which is a string or a list of blocks with text.
    private static func text(of content: Any?) -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
    }
}
