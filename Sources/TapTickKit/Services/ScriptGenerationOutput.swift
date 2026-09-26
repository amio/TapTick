import Foundation

/// Decodes transport events only. Snapshots replace prior text; token deltas append to it.
/// Diagnostics, reasoning and tool results must never enter the executable source buffer.
struct ScriptGenerationOutput {
    let provider: ScriptGenerationProvider
    private var buffer = Data()
    private(set) var text = ""
    private var parts: [String: String] = [:]
    private var partOrder: [String] = []

    init(provider: ScriptGenerationProvider) {
        self.provider = provider
    }

    mutating func receive(_ data: Data) throws {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            try decode(line)
        }
        guard buffer.count < 2 * 1024 * 1024 else {
            throw ScriptGenerationError(message: "The AI tool returned an oversized response event.")
        }
    }

    mutating func finish() throws {
        if !buffer.isEmpty {
            try decode(buffer)
            buffer.removeAll()
        }
    }

    private mutating func decode(_ data: Data) throws {
        guard !data.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) else { return }
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = event["type"] as? String
        else {
            throw ScriptGenerationError(
                message: "The AI tool returned an unexpected output format. Update it and retry.")
        }
        switch provider {
        case .os: break
        case .codex:
            if type == "turn.failed" || type == "error" {
                throw failure(event)
            }
            if type == "item.completed" || type == "item.updated",
                let item = event["item"] as? [String: Any],
                item["type"] as? String == "agent_message",
                item["phase"] as? String != "commentary",
                let content = item["text"] as? String
            {
                text = content
            }
        case .claude, .grok:
            try receiveMessagesEvent(event)
        case .gemini:
            if type == "message", event["role"] as? String == "assistant",
                let content = event["content"] as? String
            {
                if event["delta"] as? Bool == true { text += content } else { text = content }
            }
            if type == "result", event["status"] as? String == "error" { throw failure(event) }
            if type == "error", event["severity"] as? String != "warning" { throw failure(event) }
        case .copilot:
            let payload = event["data"] as? [String: Any] ?? event
            guard payload["parentToolCallId"] == nil else { return }
            if type == "assistant.message_start" { text = "" }
            if type == "assistant.message_delta", let delta = payload["deltaContent"] as? String {
                text += delta
            }
            if type == "assistant.message", let content = payload["content"] as? String {
                text = content
            }
            if type == "session.error" || type == "error" { throw failure(payload) }
        case .opencode:
            if type == "error" { throw failure(event) }
            if type == "text", let part = event["part"] as? [String: Any],
                let content = part["text"] as? String, let id = part["id"] as? String
            {
                if parts[id] == nil { partOrder.append(id) }
                parts[id] = content
                text = partOrder.compactMap { parts[$0] }.joined()
            }
            if type == "step_finish", let part = event["part"] as? [String: Any],
                part["reason"] as? String == "length"
            {
                throw ScriptGenerationError(message: "The AI response reached its length limit. Try a smaller request.")
            }
        }
    }

    private mutating func receiveMessagesEvent(_ object: [String: Any]) throws {
        let event = object["event"] as? [String: Any] ?? object
        let type = event["type"] as? String
        switch type {
        case "message_start":
            text = ""
        case "content_block_start":
            if let block = event["content_block"] as? [String: Any], block["type"] as? String == "text" {
                text += block["text"] as? String ?? ""
            }
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta" {
                text += delta["text"] as? String ?? ""
            }
        case "assistant":
            if let message = event["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            {
                text = content.filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }.joined()
                try checkStopReason(message)
            }
        case "message_delta":
            if let delta = event["delta"] as? [String: Any] { try checkStopReason(delta) }
        case "result":
            if event["is_error"] as? Bool == true { throw failure(event) }
            if let status = event["subtype"] as? String, status.hasPrefix("error") { throw failure(event) }
            if let result = event["result"] as? String { text = result }
        case "error": throw failure(event)
        default: break
        }
    }

    private func checkStopReason(_ event: [String: Any]) throws {
        if event["stop_reason"] as? String == "max_tokens" {
            throw ScriptGenerationError(message: "The AI response reached its length limit. Try a smaller request.")
        }
    }

    private func failure(_ event: [String: Any]) -> ScriptGenerationError {
        let error = event["error"] as? [String: Any]
        let detail =
            event["message"] as? String ?? error?["message"] as? String
            ?? (error?["data"] as? [String: Any])?["message"] as? String
            ?? event["error"] as? String ?? event["result"] as? String
            ?? (event["errors"] as? [String])?.joined(separator: "\n")
            ?? "The AI tool could not complete the request. Check its login and model configuration."
        return ScriptGenerationError(message: String(detail.prefix(2000)))
    }

    static func validatedScript(_ response: String, preservingShebang shebang: String?) throws -> String {
        var source = response
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), let newline = trimmed.firstIndex(of: "\n") {
            source = String(trimmed[trimmed.index(after: newline)..<trimmed.index(trimmed.endIndex, offsetBy: -3)])
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScriptGenerationError(message: "The AI tool returned no script.")
        }
        guard ScriptShebang.inspect(source).isValid,
            !source.hasSuffix("```"), !source.hasPrefix("diff ")
        else {
            throw ScriptGenerationError(
                message:
                    "The AI response was not a complete script with a valid shebang and installed interpreter. Try again."
            )
        }
        if let shebang, source.components(separatedBy: .newlines).first != shebang {
            throw ScriptGenerationError(message: "The AI response changed the original shebang. Try again.")
        }
        return source
    }
}
