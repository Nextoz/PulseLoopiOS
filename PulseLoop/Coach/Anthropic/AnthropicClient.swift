import Foundation

/// Adapts the app's `ResponsesClient` protocol to Anthropic's native **Messages API**
/// (`POST https://api.anthropic.com/v1/messages`). There is no official Swift SDK, so this
/// is raw HTTP, and it deliberately does not use Anthropic's OpenAI-compatible endpoint.
/// Like `MiniMaxClient`, it is a translating adapter: the orchestrator keeps building an
/// OpenAI Responses request body and this class maps it to and from Claude's shape.
///
/// Request rules the Claude 5.5 models enforce (each one is an HTTP 400 when broken):
/// - No `temperature` / `top_p` / `top_k`, no assistant prefill, and `tool_choice` only
///   `auto` (or `none`). Thinking can't be disabled on Opus 5.5, so `thinking` is never
///   sent (omitting it means adaptive); depth is set with `output_config.effort`.
/// - Preserved thinking: the assistant's full `content` array, thinking blocks included,
///   is replayed unchanged before the tool results, and the `system` prompt, the `tools`
///   array and every earlier message stay identical for the whole agent turn. That is why
///   a JSON-repair request (which carries no tools) keeps the original `tools` array and
///   switches `tool_choice` to `none` instead of dropping the tools.
///
/// The coach's output shape is enforced the way `MiniMaxClient` does it: a prompt
/// instruction in `system` plus the orchestrator's JSON-repair loop. OpenAI's
/// `response_format` and the OpenAI-hosted `web_search` tool are not forwarded.
///
/// State: the Responses API is stateful, the Messages API is not. This class accumulates
/// `messages` across `send` calls; the orchestrator creates a fresh client per agent turn
/// via the factory.
final class AnthropicClient: ResponsesClient, @unchecked Sendable {
    static let apiVersion = "2023-06-01"
    /// Beta header for the `fallbacks: "default"` scalar form. The array form uses a
    /// different header, and pairing the wrong header with a form is a 400.
    static let fallbackBetaHeader = "server-side-fallback-2026-07-01"
    /// Effort sent for a preset model when the user leaves Reasoning on "Default": a chat
    /// coach wants short thinking and a fast first answer.
    static let defaultEffort = "low"
    /// Non-streaming cap. Thinking counts toward it, so it has headroom over the reply.
    static let maxOutputTokens = 16_000
    private static let supportedEfforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let endpoint: URL

    // Fixed for the whole agent turn once the first request is built (preserved thinking).
    private var system = ""
    private var tools: [[String: Any]] = []
    // Accumulated Messages-API conversation for this turn.
    private var messages: [[String: Any]] = []
    // Response id → the assistant `content` array exactly as received, replayed on the
    // continuation that answers it.
    private var storedAssistantContent: [String: [[String: Any]]] = [:]

    init(
        apiKey: String,
        model: String = AnthropicModel.default.rawValue,
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.endpoint = endpoint
    }

    private var preset: AnthropicModel? { AnthropicModel(rawValue: model) }
    /// Opus and Sonnet 5.5 opt into server-side refusal fallback. Haiku 5.5 has none (a
    /// fallback list there is a 400), and a Custom model id isn't known to support it.
    private var usesServerFallback: Bool { preset?.supportsServerFallback ?? false }

    func send(requestBody: Data) async throws -> OpenAIResponse {
        guard !apiKey.isEmpty else { throw ResponsesError.missingAPIKey }

        guard let req = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] else {
            throw ResponsesError.decoding("AnthropicClient: invalid request body")
        }

        let input = req["input"] as? [[String: Any]] ?? []
        let requestTools = Self.convertTools(req["tools"] as? [[String: Any]] ?? [])
        let textFormat = (req["text"] as? [String: Any])?["format"] as? [String: Any]
        let effortHint = (req["reasoning"] as? [String: Any])?["effort"] as? String

        if let previousId = req["previous_response_id"] as? String {
            appendContinuation(previousId: previousId, input: input)
        } else {
            setupConversation(from: input, tools: requestTools, textFormat: textFormat)
        }

        let body = buildBody(effort: resolvedEffort(effortHint), allowToolCalls: !requestTools.isEmpty)
        let root = try await post(body)
        return try parseMessage(root)
    }

    // MARK: - Conversation setup

    /// First request: `system` / `developer` items become the top-level `system` prompt;
    /// the rest become alternating `user` / `assistant` messages (the API rejects two
    /// consecutive messages with the same role, so neighbours are merged).
    private func setupConversation(from input: [[String: Any]], tools newTools: [[String: Any]], textFormat: [String: Any]?) {
        messages = []
        storedAssistantContent = [:]
        tools = newTools
        var systemParts: [String] = []
        for item in input {
            guard let role = item["role"] as? String, item["content"] != nil else { continue }
            switch role {
            case "system", "developer":
                let text = Self.plainText(from: item)
                if !Self.isBlank(text) { systemParts.append(text) }
            case "assistant":
                appendMerging(role: "assistant", blocks: Self.contentBlocks(from: item, allowImages: false))
            default:
                appendMerging(role: "user", blocks: Self.contentBlocks(from: item, allowImages: true))
            }
        }
        if let instruction = Self.outputInstruction(for: textFormat) { systemParts.append(instruction) }
        system = systemParts.joined(separator: "\n\n")
        // Trimmed chat history can start on an assistant reply; the conversation has to
        // open with a user turn.
        if let first = messages.first, (first["role"] as? String) == "assistant" {
            messages.insert(
                ["role": "user", "content": [["type": "text", "text": "(Continuing our earlier conversation.)"]]],
                at: 0)
        }
    }

    /// Continuation: replay the stored assistant turn for `previousId` unchanged, then ONE
    /// user message holding every `tool_result` (results first, then any new text).
    private func appendContinuation(previousId: String, input: [[String: Any]]) {
        var toolUseIds: [String] = []
        if let content = storedAssistantContent[previousId] {
            messages.append(["role": "assistant", "content": content])
            toolUseIds = content.compactMap { block in
                (block["type"] as? String) == "tool_use" ? block["id"] as? String : nil
            }
        }

        var results: [[String: Any]] = []
        var answered = Set<String>()
        var trailing: [[String: Any]] = []
        for item in input {
            if (item["type"] as? String) == "function_call_output",
               let callId = item["call_id"] as? String {
                results.append(Self.toolResult(id: callId, output: item["output"] as? String ?? ""))
                answered.insert(callId)
            } else if let role = item["role"] as? String, item["content"] != nil {
                trailing += Self.contentBlocks(from: item, allowImages: role != "assistant")
            }
        }
        // Every tool_use must be answered in the very next user message. The orchestrator
        // can stop its tool loop at the round cap and go straight to a JSON-repair request;
        // answer the unrun calls so that request isn't a 400.
        for id in toolUseIds where !answered.contains(id) {
            results.append([
                "type": "tool_result", "tool_use_id": id,
                "content": "{\"error\":\"tool call was not run\"}", "is_error": true,
            ])
        }
        appendMerging(role: "user", blocks: results + trailing)
    }

    private func appendMerging(role: String, blocks: [[String: Any]]) {
        guard !blocks.isEmpty else { return }
        if let last = messages.indices.last,
           (messages[last]["role"] as? String) == role,
           let existing = messages[last]["content"] as? [[String: Any]] {
            messages[last]["content"] = existing + blocks
        } else {
            messages.append(["role": role, "content": blocks])
        }
    }

    // MARK: - Request

    private func resolvedEffort(_ hint: String?) -> String? {
        if let hint, Self.supportedEfforts.contains(hint) { return hint }
        // A Custom model id may predate `effort` (Haiku 4.5 rejects it), so only presets
        // get the default.
        return preset != nil ? Self.defaultEffort : nil
    }

    private func buildBody(effort: String?, allowToolCalls: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxOutputTokens,
            "messages": messages,
            // Automatic prompt caching: the breakpoint follows the growing conversation, so
            // each tool round re-reads the previous round's prefix.
            "cache_control": ["type": "ephemeral"],
        ]
        if !system.isEmpty { body["system"] = system }
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = ["type": allowToolCalls ? "auto" : "none"]
        }
        if let effort { body["output_config"] = ["effort": effort] }
        if usesServerFallback { body["fallbacks"] = "default" }
        return body
    }

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if usesServerFallback {
            request.setValue(Self.fallbackBetaHeader, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = bodyData
        // Thinking runs before the reply, so a turn takes longer than a chat completion.
        request.timeoutInterval = 120

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ResponsesError.transport(error)
        }

        // 400 (bad request), 401/403 (bad key), 429 (rate limit) and 529 (overloaded) all
        // surface as `.http`; `CoachTurnError` reads `error.message` out of the body.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw ResponsesError.http(status: http.statusCode, body: errorBody)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResponsesError.decoding("AnthropicClient: response was not a JSON object")
        }
        if (root["type"] as? String) == "error" {
            let msg = (root["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
            throw ResponsesError.decoding("Anthropic error: \(msg)")
        }
        return root
    }

    // MARK: - Parse Messages response → OpenAIResponse

    private func parseMessage(_ root: [String: Any]) throws -> OpenAIResponse {
        let content = root["content"] as? [[String: Any]] ?? []
        let stopReason = root["stop_reason"] as? String

        // Check the stop reason before reading content: a refusal can leave partial or
        // cut-off blocks that must not be shown or executed.
        switch stopReason {
        case "refusal":
            throw ResponsesError.refusal(Self.refusalReason(root))
        case "pause_turn":
            // Only server-side tools pause a turn, and none are sent.
            throw ResponsesError.decoding("Claude paused before finishing its answer. Try again.")
        default:
            break
        }

        var text = ""
        var calls: [ResponseFunctionCall] = []
        for block in content[Self.servedStart(content)...] {
            switch block["type"] as? String {
            case "text":
                text += block["text"] as? String ?? ""
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                calls.append(ResponseFunctionCall(name: name, callID: id, arguments: Self.jsonString(block["input"])))
            default:
                // thinking / redacted_thinking / fallback: replayed, never shown.
                break
            }
        }

        if stopReason == "max_tokens", !calls.isEmpty {
            // A truncated tool input can still parse as a partial object; never run it.
            throw ResponsesError.decoding("Claude's reply was cut off (max_tokens) in the middle of a tool call. Try a lower Reasoning level.")
        }

        var outputItems: [ResponseOutputItem] = []
        if !Self.isBlank(text) { outputItems.append(.message(text: text)) }
        outputItems += calls.map { ResponseOutputItem.functionCall($0) }

        if outputItems.isEmpty {
            if stopReason == "max_tokens" {
                throw ResponsesError.decoding("Claude used its whole output budget (max_tokens) before answering. Try a lower Reasoning level.")
            }
            throw ResponsesError.emptyOutput
        }

        let responseId = (root["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        storedAssistantContent[responseId] = Self.echoContent(content)
        return OpenAIResponse(id: responseId, outputItems: outputItems, usage: Self.usage(from: root))
    }

    /// Index of the first block produced by the model that served the turn: just past the
    /// last `fallback` marker, or 0 when no fallback happened.
    private static func servedStart(_ content: [[String: Any]]) -> Int {
        guard let marker = content.lastIndex(where: { ($0["type"] as? String) == "fallback" }) else { return 0 }
        return marker + 1
    }

    /// The assistant content to replay next request. Unchanged unless a refusal fallback
    /// happened mid-output: then only `text` blocks before the last `fallback` marker are
    /// kept (the declined model's thinking / tool_use blocks are omitted), the marker is
    /// dropped, and everything after it is kept as received.
    private static func echoContent(_ content: [[String: Any]]) -> [[String: Any]] {
        let start = servedStart(content)
        guard start > 0 else { return content }
        let declinedText = content[..<(start - 1)].filter { ($0["type"] as? String) == "text" }
        return Array(declinedText) + Array(content[start...])
    }

    private static func refusalReason(_ root: [String: Any]) -> String {
        let details = root["stop_details"] as? [String: Any]
        var reason = "Claude declined this request"
        if let category = details?["category"] as? String, !category.isEmpty {
            reason += " (safety category: \(category))"
        }
        reason += ". Try rephrasing, or pick a different model."
        if let explanation = details?["explanation"] as? String, !explanation.isEmpty {
            reason += " \(explanation)"
        }
        return reason
    }

    /// Maps Claude's `usage`. `input_tokens` excludes cache reads and writes, while
    /// `CoachTokenUsage.inputTokens` includes its cached subset, so all three are summed.
    private static func usage(from root: [String: Any]) -> CoachTokenUsage? {
        guard let usage = root["usage"] as? [String: Any],
              let input = usage["input_tokens"] as? Int,
              let output = usage["output_tokens"] as? Int else { return nil }
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        return CoachTokenUsage(
            inputTokens: input + cacheRead + cacheWrite, outputTokens: output, cachedInputTokens: cacheRead)
    }

    // MARK: - Mapping helpers

    /// Responses function specs (`{type: function, name, description, parameters}`) →
    /// Claude tools (`{name, description, input_schema}`). The OpenAI-hosted `web_search`
    /// tool (and anything that isn't a function) is dropped. `strict` is not forwarded:
    /// the specs are written for OpenAI's strict mode, Claude's strict mode supports a
    /// different schema subset, and each tool validates its own arguments anyway.
    static func convertTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool -> [String: Any]? in
            guard (tool["type"] as? String) == "function", let name = tool["name"] as? String else { return nil }
            var out: [String: Any] = ["name": name]
            if let desc = tool["description"] as? String, !desc.isEmpty { out["description"] = desc }
            let emptySchema: [String: Any] = ["type": "object", "properties": [String: Any]()]
            out["input_schema"] = (tool["parameters"] as? [String: Any]) ?? emptySchema
            return out
        }
    }

    /// The system-prompt instruction that stands in for OpenAI's enforced `text.format`.
    /// The coach's own schema uses its hand-written field spec; any other JSON schema
    /// (summaries, notifications, meal estimates) is spelled out verbatim.
    static func outputInstruction(for textFormat: [String: Any]?) -> String? {
        guard let textFormat, (textFormat["type"] as? String) == "json_schema" else { return nil }
        if (textFormat["name"] as? String) == CoachResponseSchema.name {
            return CoachResponseSchema.promptInstruction
        }
        guard let schema = textFormat["schema"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "Your final answer MUST be a single JSON object (no Markdown, no code fences, "
            + "no prose before or after) that matches this JSON schema:\n" + json
    }

    /// Responses message `content` → Claude content blocks. Plain-string content becomes
    /// one text block; the `input_text` + `input_image` part array maps to `text` + base64
    /// `image` blocks. Blank text is skipped (the API rejects whitespace-only text blocks).
    private static func contentBlocks(from item: [String: Any], allowImages: Bool) -> [[String: Any]] {
        if let text = item["content"] as? String {
            return isBlank(text) ? [] : [["type": "text", "text": text]]
        }
        guard let parts = item["content"] as? [[String: Any]] else { return [] }
        var out: [[String: Any]] = []
        for part in parts {
            switch part["type"] as? String {
            case "input_text", "output_text", "text":
                if let text = part["text"] as? String, !isBlank(text) {
                    out.append(["type": "text", "text": text])
                }
            case "input_image":
                if allowImages, let source = imageSource(fromDataURL: part["image_url"] as? String) {
                    out.append(["type": "image", "source": source])
                }
            default:
                break
            }
        }
        return out
    }

    private static func plainText(from item: [String: Any]) -> String {
        if let text = item["content"] as? String { return text }
        let parts = item["content"] as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// Splits a `data:<mime>;base64,<data>` URL into Claude's base64 image `source`.
    private static func imageSource(fromDataURL url: String?) -> [String: Any]? {
        guard let url, url.hasPrefix("data:"),
              let comma = url.firstIndex(of: ","),
              let semicolon = url.firstIndex(of: ";"),
              semicolon < comma
        else { return nil }
        let mime = String(url[url.index(url.startIndex, offsetBy: 5)..<semicolon])
        let data = String(url[url.index(after: comma)...])
        return ["type": "base64", "media_type": mime, "data": data]
    }

    private static func toolResult(id: String, output: String) -> [String: Any] {
        var block: [String: Any] = [
            "type": "tool_result", "tool_use_id": id,
            "content": isBlank(output) ? "(no output)" : output,
        ]
        if isErrorOutput(output) { block["is_error"] = true }
        return block
    }

    /// The app's tools report failure as a bare `{"error": "…"}` object
    /// (`ToolResult.error`); the orchestrator's budget guards use the same shape.
    static func isErrorOutput(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj.count == 1 && obj["error"] != nil
    }

    private static func jsonString(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
