import Foundation

/// One message in the OpenAI-style chat transcript sent to the model.
public struct ChatWireMessage: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Codable { case system, user, assistant, tool }

    public var role: Role
    public var content: String?
    public var toolCalls: [AIToolCall] = []
    public var toolCallID: String?

    public static func system(_ text: String) -> Self { .init(role: .system, content: text) }
    public static func user(_ text: String) -> Self { .init(role: .user, content: text) }
    public static func tool(id: String, output: String) -> Self { .init(role: .tool, content: output, toolCallID: id) }

    var json: [String: Any] {
        var out: [String: Any] = ["role": role.rawValue]
        out["content"] = content ?? (toolCalls.isEmpty ? "" : NSNull())
        if !toolCalls.isEmpty {
            out["tool_calls"] = toolCalls.map {
                ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
            }
        }
        if let toolCallID { out["tool_call_id"] = toolCallID }
        return out
    }
}

public struct AIToolCall: Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    /// JSON-encoded arguments, as produced by the model.
    public let arguments: String
}

/// A function the model may call; `parameters` is a JSON Schema object.
public struct AIToolSpec: Sendable {
    public let name: String
    public let description: String
    public let parametersJSON: String

    var json: [String: Any] {
        let params = (try? JSONSerialization.jsonObject(with: Data(parametersJSON.utf8))) ?? ["type": "object", "properties": [:]]
        return ["type": "function", "function": ["name": name, "description": description, "parameters": params]]
    }
}

public struct AIChatReply: Sendable {
    public let content: String?
    public let toolCalls: [AIToolCall]
    public var promptTokens = 0
    public var completionTokens = 0
}

/// Chat completions with tool calling for every configured provider (all speak the OpenAI wire format).
public enum AIChatService {
    public static func complete(
        provider: AIProvider,
        model: String,
        githubToken: String?,
        messages: [ChatWireMessage],
        tools: [AIToolSpec],
        userInitiated: Bool = true
    ) async throws -> AIChatReply {
        var request = try await makeRequest(provider: provider, githubToken: githubToken)
        if provider == .githubCopilot {
            // Copilot bills a premium request per user turn; tool-result follow-ups are agent turns.
            request.setValue(userInitiated ? "user" : "agent", forHTTPHeaderField: "X-Initiator")
        }
        let resolvedModel: String = switch provider {
        case .githubCopilot: model
        case .githubModels: model.isEmpty ? "gpt-4o-mini" : model
        case .ollama: model.isEmpty ? "llama3.2" : model
        case .customOpenAI: model.isEmpty ? "gpt-4o" : model
        }
        var payload: [String: Any] = [
            "model": resolvedModel,
            "messages": messages.map(\.json),
            "temperature": 0.2,
        ]
        if !tools.isEmpty {
            payload["tools"] = tools.map(\.json)
            payload["tool_choice"] = "auto"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 500
        guard (200...299).contains(status) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "AIChat", code: status, userInfo: [NSLocalizedDescriptionKey: "\(provider.rawValue) returned \(status): \(text.prefix(400))"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
            throw NSError(domain: "AIChat", code: 500, userInfo: [NSLocalizedDescriptionKey: "Unexpected response from \(provider.rawValue)."])
        }
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { raw -> AIToolCall? in
            guard let fn = raw["function"] as? [String: Any], let name = fn["name"] as? String else { return nil }
            let args: String
            if let s = fn["arguments"] as? String { args = s }
            else if let obj = fn["arguments"], let d = try? JSONSerialization.data(withJSONObject: obj) { args = String(decoding: d, as: UTF8.self) }
            else { args = "{}" }
            return AIToolCall(id: raw["id"] as? String ?? UUID().uuidString, name: name, arguments: args)
        }
        let content = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var reply = AIChatReply(content: content?.isEmpty == true ? nil : content, toolCalls: calls)
        if let usage = json["usage"] as? [String: Any] {
            reply.promptTokens = (usage["prompt_tokens"] as? NSNumber)?.intValue ?? 0
            reply.completionTokens = (usage["completion_tokens"] as? NSNumber)?.intValue ?? 0
        }
        return reply
    }

    private static func makeRequest(provider: AIProvider, githubToken: String?) async throws -> URLRequest {
        func request(_ urlString: String, bearer: String?) throws -> URLRequest {
            guard let url = URL(string: urlString) else { throw URLError(.badURL) }
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.timeoutInterval = 120
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let bearer { r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
            return r
        }
        switch provider {
        case .githubCopilot:
            let (token, endpoint) = try await CopilotAuthService.shared.getCopilotSessionToken()
            var r = try request("\(endpoint)/chat/completions", bearer: token)
            r.setValue("vscode/1.90.0", forHTTPHeaderField: "Editor-Version")
            r.setValue("vscode-chat", forHTTPHeaderField: "Copilot-Integration-Id")
            return r
        case .githubModels:
            guard let token = githubToken ?? KeychainHelper.getGitHubToken(), !token.isEmpty else {
                throw NSError(domain: "AIChat", code: 401, userInfo: [NSLocalizedDescriptionKey: "GitHub Models needs a GitHub token. Sign in under Settings › Accounts."])
            }
            return try request("https://models.inference.ai.azure.com/chat/completions", bearer: token)
        case .ollama:
            return try request("http://localhost:11434/v1/chat/completions", bearer: nil)
        case .customOpenAI:
            let key = KeychainHelper.getToken(forAccount: "custom_ai_api_key") ?? ""
            guard !key.isEmpty else {
                throw NSError(domain: "AIChat", code: 401, userInfo: [NSLocalizedDescriptionKey: "Add an API key under Settings › AI & Copilot."])
            }
            let endpoint = UserDefaults.standard.string(forKey: "custom_ai_endpoint") ?? "https://api.openai.com/v1"
            return try request("\(endpoint)/chat/completions", bearer: key)
        }
    }
}
