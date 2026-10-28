import Foundation
import XCTest
@testable import PulseLoop

/// URLProtocol stub that replays a queue of canned Messages-API responses and records
/// every request (headers + body), so a multi-request tool loop can be asserted.
final class AnthropicStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var queue: [(status: Int, body: Data)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            let bufSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufSize)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
        }
        Self.requests.append(request)
        Self.bodies.append(body)

        let next: (status: Int, body: Data) = Self.queue.isEmpty ? (status: 500, body: Data()) : Self.queue.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct FixedKeyStore: APIKeyStore {
    let key: String?
    func readKey() throws -> String? { key }
    func saveKey(_ key: String) throws {}
    func deleteKey() throws {}
}

/// Verifies `AnthropicClient` translates the app's OpenAI-Responses-shaped requests to
/// Claude's Messages API and back. All payloads are synthetic.
final class AnthropicClientTests: XCTestCase {

    // MARK: Fixtures

    private static let textResponse = #"""
    {"id":"msg_text","type":"message","role":"assistant","model":"claude-opus-5-5",
     "content":[
       {"type":"thinking","thinking":"","signature":"sig-synthetic-text"},
       {"type":"text","text":"You slept "},
       {"type":"text","text":"well."}
     ],
     "stop_reason":"end_turn",
     "usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":200,"cache_creation_input_tokens":30}}
    """#

    private static let toolUseResponse = #"""
    {"id":"msg_01","type":"message","role":"assistant","model":"claude-opus-5-5",
     "content":[
       {"type":"thinking","thinking":"","signature":"sig-synthetic-001"},
       {"type":"text","text":"Let me check."},
       {"type":"tool_use","id":"toolu_01","name":"get_daily_summary","input":{"date":"2026-10-01"}},
       {"type":"tool_use","id":"toolu_02","name":"get_sleep_summary","input":{}}
     ],
     "stop_reason":"tool_use",
     "usage":{"input_tokens":100,"output_tokens":20}}
    """#

    private static let afterToolsResponse = #"""
    {"id":"msg_02","type":"message","role":"assistant","model":"claude-opus-5-5",
     "content":[
       {"type":"thinking","thinking":"","signature":"sig-synthetic-002"},
       {"type":"text","text":"Not JSON yet."}
     ],
     "stop_reason":"end_turn",
     "usage":{"input_tokens":150,"output_tokens":5}}
    """#

    private static let refusalResponse = #"""
    {"id":"msg_r","type":"message","role":"assistant","model":"claude-opus-5-5",
     "content":[],"stop_reason":"refusal","stop_details":{"category":"bio"},
     "usage":{"input_tokens":10,"output_tokens":0}}
    """#

    private let toolSpec: [String: Any] = [
        "type": "function",
        "name": "get_daily_summary",
        "description": "Daily summary.",
        "parameters": [
            "type": "object",
            "properties": ["date": ["type": "string"]],
            "required": ["date"],
            "additionalProperties": false,
        ],
        "strict": true,
    ]

    override func setUp() {
        super.setUp()
        AnthropicStubURLProtocol.queue = []
        AnthropicStubURLProtocol.requests = []
        AnthropicStubURLProtocol.bodies = []
    }

    private func client(model: String = AnthropicModel.opus55.rawValue) -> AnthropicClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnthropicStubURLProtocol.self]
        return AnthropicClient(apiKey: "sk-ant-test", model: model, session: URLSession(configuration: config))
    }

    private func enqueue(_ json: String, status: Int = 200) {
        AnthropicStubURLProtocol.queue.append((status: status, body: Data(json.utf8)))
    }

    /// Decodes the body of the `index`-th request the client sent.
    private func sentBody(_ index: Int) throws -> [String: Any] {
        let bodies = AnthropicStubURLProtocol.bodies
        let data = try XCTUnwrap(bodies.indices.contains(index) ? bodies[index] : nil, "request \(index) not sent")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func initialBody(effort: String? = nil) throws -> Data {
        try OpenAIRequestBuilder.data(
            model: "ignored-by-adapter",
            input: [
                OpenAIRequestBuilder.message(role: "system", content: "SYSTEM PROMPT"),
                OpenAIRequestBuilder.message(role: "developer", content: "DEVELOPER CONTEXT"),
                OpenAIRequestBuilder.message(role: "user", content: "How did I sleep?"),
            ],
            tools: [toolSpec, ["type": "web_search"]],
            textFormat: CoachResponseSchema.textFormat,
            previousResponseId: nil,
            reasoningEffort: effort)
    }

    // MARK: Request shape

    func testRequestHeadersAndBodyShape() async throws {
        enqueue(Self.textResponse)
        _ = try await client().send(requestBody: initialBody())

        let request = try XCTUnwrap(AnthropicStubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try sentBody(0)
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 16_000)

        let system = try XCTUnwrap(body["system"] as? String)
        XCTAssertTrue(system.hasPrefix("SYSTEM PROMPT\n\nDEVELOPER CONTEXT"))
        XCTAssertTrue(system.contains(CoachResponseSchema.promptInstruction))

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1, "system/developer go to top-level system, not messages")
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let blocks = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.first?["type"] as? String, "text")
        XCTAssertEqual(blocks.first?["text"] as? String, "How did I sleep?")

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1, "the OpenAI-hosted web_search tool is dropped")
        XCTAssertEqual(tools[0]["name"] as? String, "get_daily_summary")
        XCTAssertEqual(tools[0]["description"] as? String, "Daily summary.")
        let schema = try XCTUnwrap(tools[0]["input_schema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["required"] as? [String], ["date"])
        XCTAssertNil(tools[0]["parameters"])
        XCTAssertNil(tools[0]["type"])
        XCTAssertNil(tools[0]["strict"])
        XCTAssertEqual((body["tool_choice"] as? [String: Any])?["type"] as? String, "auto")

        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low")
        for key in ["temperature", "top_p", "top_k", "thinking", "input", "text", "reasoning",
                    "response_format", "previous_response_id"] {
            XCTAssertNil(body[key], "\(key) must not be sent")
        }
    }

    func testFallbackOnlyForOpusAndSonnet() async throws {
        for (index, model) in AnthropicModel.allCases.enumerated() {
            enqueue(Self.textResponse)
            _ = try await client(model: model.rawValue).send(requestBody: initialBody())

            let request = AnthropicStubURLProtocol.requests[index]
            let body = try sentBody(index)
            let expectedFallback: String? = model == .haiku55 ? nil : "default"
            let expectedBeta: String? = model == .haiku55 ? nil : AnthropicClient.fallbackBetaHeader
            XCTAssertEqual(body["model"] as? String, model.rawValue)
            XCTAssertEqual(body["fallbacks"] as? String, expectedFallback, model.rawValue)
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), expectedBeta, model.rawValue)
        }
    }

    func testReasoningEffortIsForwardedAndUnsupportedLevelFallsBackToLow() async throws {
        enqueue(Self.textResponse)
        enqueue(Self.textResponse)
        _ = try await client().send(requestBody: initialBody(effort: "high"))
        _ = try await client().send(requestBody: initialBody(effort: "none"))

        let first = try sentBody(0)
        let second = try sentBody(1)
        XCTAssertEqual((first["output_config"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertEqual((second["output_config"] as? [String: Any])?["effort"] as? String, "low")
    }

    // MARK: Tool loop

    /// The second request must replay the assistant content exactly as received
    /// (thinking block included) and answer both tool calls in ONE user message.
    func testToolUseRoundTripReplaysThinkingAndBatchesResults() async throws {
        enqueue(Self.toolUseResponse)
        enqueue(Self.afterToolsResponse)
        enqueue(Self.textResponse)
        let client = client()

        let first = try await client.send(requestBody: initialBody())
        XCTAssertEqual(first.id, "msg_01")
        XCTAssertEqual(first.functionCalls.count, 2)
        XCTAssertEqual(first.functionCalls[0].name, "get_daily_summary")
        XCTAssertEqual(first.functionCalls[0].callID, "toolu_01")
        let args = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(first.functionCalls[0].arguments.utf8)) as? [String: Any])
        XCTAssertEqual(args["date"] as? String, "2026-10-01")
        XCTAssertEqual(first.functionCalls[1].arguments, "{}")

        let followUp = try OpenAIRequestBuilder.data(
            model: "ignored-by-adapter",
            input: [
                OpenAIRequestBuilder.functionCallOutput(callID: "toolu_01", output: #"{"steps":9000}"#),
                OpenAIRequestBuilder.functionCallOutput(callID: "toolu_02", output: #"{"error":"no sleep data"}"#),
            ],
            tools: [toolSpec, ["type": "web_search"]],
            textFormat: CoachResponseSchema.textFormat,
            previousResponseId: first.id,
            reasoningEffort: nil)
        let second = try await client.send(requestBody: followUp)
        XCTAssertEqual(second.outputText, "Not JSON yet.")
        XCTAssertTrue(second.functionCalls.isEmpty)

        let body0 = try sentBody(0)
        let body1 = try sentBody(1)
        let messages = try XCTUnwrap(body1["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])

        // Assistant turn replayed unchanged, thinking block and signature included.
        let originalRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(Self.toolUseResponse.utf8)) as? [String: Any])
        let originalContent = try XCTUnwrap(originalRoot["content"] as? [Any])
        let replayed = try XCTUnwrap(messages[1]["content"] as? [Any])
        XCTAssertEqual(replayed as NSArray, originalContent as NSArray)
        let replayedBlocks = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(replayedBlocks.first?["type"] as? String, "thinking")
        XCTAssertEqual(replayedBlocks.first?["signature"] as? String, "sig-synthetic-001")

        // One user message carrying both results, tool_result blocks only.
        let results = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.map { $0["type"] as? String }, ["tool_result", "tool_result"])
        XCTAssertEqual(results[0]["tool_use_id"] as? String, "toolu_01")
        XCTAssertEqual(results[0]["content"] as? String, #"{"steps":9000}"#)
        XCTAssertNil(results[0]["is_error"])
        XCTAssertEqual(results[1]["tool_use_id"] as? String, "toolu_02")
        XCTAssertEqual(results[1]["is_error"] as? Bool, true)

        // The prefix preserved thinking is bound to stays identical.
        XCTAssertEqual(body1["system"] as? String, body0["system"] as? String)
        XCTAssertEqual(body1["tools"] as? NSArray, body0["tools"] as? NSArray)

        // JSON-repair request: no tools in the Responses body, but Claude keeps the same
        // tools array (prefix) and is told not to call any.
        let repair = try OpenAIRequestBuilder.data(
            model: "ignored-by-adapter",
            input: [OpenAIRequestBuilder.message(role: "user", content: "Return only valid JSON now.")],
            tools: [],
            textFormat: CoachResponseSchema.textFormat,
            previousResponseId: second.id,
            reasoningEffort: nil)
        let third = try await client.send(requestBody: repair)
        XCTAssertEqual(third.outputText, "You slept well.")

        let body2 = try sentBody(2)
        XCTAssertEqual(body2["tools"] as? NSArray, body0["tools"] as? NSArray)
        XCTAssertEqual((body2["tool_choice"] as? [String: Any])?["type"] as? String, "none")
        let repairMessages = try XCTUnwrap(body2["messages"] as? [[String: Any]])
        XCTAssertEqual(repairMessages.count, 5)
        let replayedSecond = try XCTUnwrap(repairMessages[3]["content"] as? [[String: Any]])
        XCTAssertEqual(replayedSecond.first?["signature"] as? String, "sig-synthetic-002")
        XCTAssertEqual(repairMessages[4]["role"] as? String, "user")
    }

    func testUnansweredToolCallsGetErrorResultsOnRepair() async throws {
        enqueue(Self.toolUseResponse)
        enqueue(Self.textResponse)
        let client = client()
        let first = try await client.send(requestBody: initialBody())

        // The orchestrator hit its round cap and went straight to a repair request.
        let repair = try OpenAIRequestBuilder.data(
            model: "ignored-by-adapter",
            input: [OpenAIRequestBuilder.message(role: "user", content: "Return only valid JSON now.")],
            tools: [],
            textFormat: CoachResponseSchema.textFormat,
            previousResponseId: first.id,
            reasoningEffort: nil)
        _ = try await client.send(requestBody: repair)

        let messages = try XCTUnwrap(try sentBody(1)["messages"] as? [[String: Any]])
        let blocks = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["tool_result", "tool_result", "text"])
        XCTAssertEqual(blocks[0]["is_error"] as? Bool, true)
    }

    // MARK: Response mapping

    func testTextResponseMapsToOutputTextAndUsage() async throws {
        enqueue(Self.textResponse)
        let response = try await client().send(requestBody: initialBody())

        XCTAssertEqual(response.id, "msg_text")
        XCTAssertEqual(response.outputText, "You slept well.")
        XCTAssertTrue(response.functionCalls.isEmpty)
        let usage = try XCTUnwrap(response.usage)
        XCTAssertEqual(usage.inputTokens, 280, "input + cache reads + cache writes")
        XCTAssertEqual(usage.cachedInputTokens, 200)
        XCTAssertEqual(usage.outputTokens, 10)
    }

    func testRefusalThrowsClearError() async throws {
        enqueue(Self.refusalResponse)
        do {
            _ = try await client().send(requestBody: initialBody())
            XCTFail("expected a refusal error")
        } catch {
            guard case ResponsesError.refusal(let reason) = error else {
                return XCTFail("expected ResponsesError.refusal, got \(error)")
            }
            XCTAssertTrue(reason.contains("bio"))
            XCTAssertEqual(CoachTurnError(error).code, "Declined")
        }
    }

    func testTruncatedToolCallIsNotReturned() async throws {
        enqueue(Self.toolUseResponse.replacingOccurrences(of: #""stop_reason":"tool_use""#, with: #""stop_reason":"max_tokens""#))
        do {
            _ = try await client().send(requestBody: initialBody())
            XCTFail("expected an error for a truncated tool call")
        } catch {
            guard case ResponsesError.decoding(_) = error else {
                return XCTFail("expected ResponsesError.decoding, got \(error)")
            }
        }
    }

    func testHTTPErrorsMapToHTTPCase() async throws {
        for status in [400, 401, 403, 429, 529] {
            enqueue(#"{"type":"error","error":{"type":"synthetic_error","message":"synthetic failure"}}"#, status: status)
            do {
                _ = try await client().send(requestBody: initialBody())
                XCTFail("expected HTTP \(status) to throw")
            } catch {
                guard case ResponsesError.http(let code, _) = error else {
                    return XCTFail("expected ResponsesError.http, got \(error)")
                }
                XCTAssertEqual(code, status)
                XCTAssertEqual(CoachTurnError(error).reason, "synthetic failure")
            }
        }
    }

    func testMissingKeyThrowsWithoutNetwork() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnthropicStubURLProtocol.self]
        let client = AnthropicClient(apiKey: "", session: URLSession(configuration: config))
        do {
            _ = try await client.send(requestBody: initialBody())
            XCTFail("expected missing-key error")
        } catch {
            guard case ResponsesError.missingAPIKey = error else {
                return XCTFail("expected ResponsesError.missingAPIKey, got \(error)")
            }
        }
        XCTAssertTrue(AnthropicStubURLProtocol.requests.isEmpty)
    }

    // MARK: Provider plumbing

    func testResolverBuildsAnthropicClientFromItsKeyStore() {
        var settings = CoachSettings()
        settings.coachMasterEnabled = true
        settings.providerMode = .userAnthropicKey
        settings.model = AnthropicModel.sonnet55.rawValue
        settings.reasoningEffort = "max"
        let none = FixedKeyStore(key: nil)

        let resolved = CoachClientResolver.resolve(
            settings: settings,
            openAIKeyStore: none,
            geminiKeyStore: none,
            openRouterKeyStore: none,
            minimaxKeyStore: none,
            anthropicKeyStore: FixedKeyStore(key: "sk-ant-test"))

        XCTAssertEqual(resolved.key, "sk-ant-test")
        XCTAssertTrue(resolved.client is AnthropicClient)
        let flags = CoachFeatureFlags(settings: settings, hasAPIKey: resolved.key != nil)
        XCTAssertTrue(flags.coachEnabled)
        XCTAssertEqual(flags.effectiveModel, "claude-sonnet-5-5")
        XCTAssertEqual(settings.resolvedReasoningEffort, "max")
        XCTAssertEqual(settings.reasoningEffortOptions, ReasoningEffort.lowToMax)
        XCTAssertNotNil(CoachPricingCatalog.price(for: flags.effectiveModel))
    }
}
