import Foundation

/// Errors surfaced by the Responses client. The orchestrator catches these and
/// degrades to a graceful fallback rather than crashing the chat.
enum ResponsesError: Error, LocalizedError {
    case missingAPIKey
    case transport(Error)
    case http(status: Int, body: String)
    case decoding(String)
    case emptyOutput
    /// The model (or a provider safety classifier) declined the request — Claude's
    /// `stop_reason: "refusal"`. Carries a user-facing reason.
    case refusal(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No OpenAI API key configured."
        case .transport(let e): return "Network error: \(e.localizedDescription)"
        case .http(let status, let body): return "OpenAI returned HTTP \(status): \(body.prefix(200))"
        case .decoding(let msg): return "Could not parse OpenAI response: \(msg)"
        case .emptyOutput: return "OpenAI returned no output."
        case .refusal(let reason): return reason
        }
    }
}
