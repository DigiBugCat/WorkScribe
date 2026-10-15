import Foundation

/// Request building and stream parsing for the OpenAI Responses API (POST https://api.openai.com/v1/responses).
/// Pure, so it is tested with fixtures; the app's `OpenAIResponsesGenerator` does the networking.
///
/// Privacy: the request holds only the question, at most two recent turns, and the bounded retrieved snippets in
/// `AskPrompt` (never whole transcripts, audio or screen images), capped again here at `maxInputCharacters`
/// (~6k tokens). `store: false` asks OpenAI not to keep the response for later retrieval.
public enum OpenAIResponses {
    public static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    public static let defaultModel = "gpt-5.4-mini"
    /// ≈ 6,000 tokens at ~4 characters per token.
    public static let maxInputCharacters = 24_000

    /// The user turn without the instruction (that goes in `instructions`), capped at `maxInputCharacters`.
    public static func input(_ prompt: AskPrompt) -> String {
        var text = "Sources:\n" + (prompt.sources.isEmpty ? "(none)" : prompt.sources)
        if !prompt.history.isEmpty {
            text += "\n\nEarlier in this chat:\n" + prompt.history.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n")
        }
        let question = "\n\nQuestion: " + prompt.question
        let room = max(0, maxInputCharacters - question.count)
        if text.count > room { text = String(text.prefix(room)) + "…" }
        return text + question
    }

    public static func body(_ prompt: AskPrompt, model: String, maxOutputTokens: Int = 1_200, stream: Bool = true) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "instructions": prompt.instruction,
            "input": [["role": "user", "content": [["type": "input_text", "text": input(prompt)]]]],
            "max_output_tokens": maxOutputTokens,
            "stream": stream,
            "store": false,
        ]
        // Reasoning models spend output tokens thinking; a short cited answer needs little.
        if model.hasPrefix("gpt-5") || model.hasPrefix("o") { body["reasoning"] = ["effort": "low"] }
        return body
    }

    public static func request(_ prompt: AskPrompt, model: String, apiKey: String, endpoint: URL = endpoint) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(prompt, model: model), options: [.sortedKeys])
        request.timeoutInterval = 60
        return request
    }

    public enum StreamEvent: Equatable, Sendable {
        case delta(String)
        case completed
        case failed(String)
        /// Other event types (created, in_progress, output_item.added, …).
        case ignored
    }

    /// Parses one SSE `data:` payload of a streaming response.
    public static func parse(data line: String) -> StreamEvent {
        let payload = line.trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .completed }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return .ignored }
        switch type {
        case "response.output_text.delta":
            return .delta(object["delta"] as? String ?? "")
        case "response.completed":
            return .completed
        case "response.incomplete":
            let reason = ((object["response"] as? [String: Any])?["incomplete_details"] as? [String: Any])?["reason"] as? String
            return reason == "max_output_tokens" ? .completed : .failed("Incomplete response: \(reason ?? "unknown")")
        case "response.failed":
            let error = (object["response"] as? [String: Any])?["error"] as? [String: Any]
            return .failed(error?["message"] as? String ?? "The model failed to respond")
        case "error":
            return .failed(object["message"] as? String ?? (object["error"] as? [String: Any])?["message"] as? String ?? "API error")
        default:
            return .ignored
        }
    }

    /// Feeds raw SSE lines; returns an event for each `data:` line.
    public static func parse(line: String) -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        return parse(data: String(line.dropFirst(5)))
    }

    /// The message from a non-2xx response body (`{"error":{"message":…}}`).
    public static func errorMessage(_ body: Data, status: Int) -> String {
        let message = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
            .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
        switch status {
        case 401: return "OpenAI rejected the API key (401). Check it in Settings."
        case 429: return message ?? "OpenAI rate limit or quota reached (429)."
        default: return message ?? "OpenAI error \(status)"
        }
    }
}
