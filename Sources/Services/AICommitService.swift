import Foundation

public struct GeneratedCommitMessage: Sendable {
    public let summary: String
    public let description: String
}

public actor AICommitService {
    public static let shared = AICommitService()

    public init() {}

    public func generateCommitMessage(
        diff: String,
        provider: AIProvider = .githubCopilot,
        style: CommitStyle = .conventional,
        modelName: String = "gpt-4o"
    ) async throws -> GeneratedCommitMessage {
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "AICommitService", code: 400, userInfo: [NSLocalizedDescriptionKey: "No code changes found in git diff to analyze."])
        }

        // Truncate diff if extremely large to prevent token overflows
        let maxChars = 14000
        let truncatedDiff: String
        if diff.count > maxChars {
            truncatedDiff = String(diff.prefix(maxChars)) + "\n\n...[diff truncated for length]..."
        } else {
            truncatedDiff = diff
        }

        let systemPrompt = buildSystemPrompt(style: style)
        let userPrompt = "Here is the git diff:\n\n```diff\n\(truncatedDiff)\n```\n\nGenerate the commit message now."

        switch provider {
        case .githubCopilot:
            return try await callCopilot(systemPrompt: systemPrompt, userPrompt: userPrompt, model: modelName)

        case .githubModels:
            return try await callGitHubModels(systemPrompt: systemPrompt, userPrompt: userPrompt, model: modelName.isEmpty ? "gpt-4o-mini" : modelName)

        case .ollama:
            return try await callOllama(systemPrompt: systemPrompt, userPrompt: userPrompt, model: modelName.isEmpty ? "llama3.2" : modelName)

        case .customOpenAI:
            return try await callOpenAICompatible(systemPrompt: systemPrompt, userPrompt: userPrompt, model: modelName.isEmpty ? "gpt-4o" : modelName)
        }
    }

    // MARK: - Providers Implementation

    private func callCopilot(systemPrompt: String, userPrompt: String, model: String) async throws -> GeneratedCommitMessage {
        let (token, endpoint) = try await CopilotAuthService.shared.getCopilotSessionToken()

        guard let url = URL(string: "\(endpoint)/chat/completions") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25.0
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("vscode/1.90.0", forHTTPHeaderField: "Editor-Version")
        request.setValue("vscode-chat", forHTTPHeaderField: "Copilot-Integration-Id")

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.2
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Copilot Chat failed"
            throw NSError(domain: "CopilotChat", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "Copilot Chat error: \(errorText)"])
        }

        return try parseChatResponse(data)
    }

    private func callGitHubModels(systemPrompt: String, userPrompt: String, model: String) async throws -> GeneratedCommitMessage {
        guard let token = KeychainHelper.getGitHubToken(), !token.isEmpty else {
            throw NSError(domain: "GitHubModels", code: 401, userInfo: [NSLocalizedDescriptionKey: "GitHub Token required for GitHub Models. Please sign in or add a Personal Access Token in Preferences."])
        }

        guard let url = URL(string: "https://models.inference.ai.azure.com/chat/completions") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25.0
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.2
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "GitHub Models request failed"
            throw NSError(domain: "GitHubModels", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "GitHub Models error: \(errorText)"])
        }

        return try parseChatResponse(data)
    }

    private func callOllama(systemPrompt: String, userPrompt: String, model: String) async throws -> GeneratedCommitMessage {
        guard let url = URL(string: "http://localhost:11434/v1/chat/completions") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25.0
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.2
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "Ollama", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "Could not connect to Ollama on http://localhost:11434. Make sure Ollama is running."])
        }

        return try parseChatResponse(data)
    }

    private func callOpenAICompatible(systemPrompt: String, userPrompt: String, model: String) async throws -> GeneratedCommitMessage {
        let apiKey = KeychainHelper.getToken(forAccount: "custom_ai_api_key") ?? ""
        guard !apiKey.isEmpty else {
            throw NSError(domain: "OpenAI", code: 401, userInfo: [NSLocalizedDescriptionKey: "Custom API Key is required. Please set it in Preferences > AI & Copilot."])
        }

        let customEndpoint = UserDefaults.standard.string(forKey: "custom_ai_endpoint") ?? "https://api.openai.com/v1"
        guard let url = URL(string: "\(customEndpoint)/chat/completions") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25.0
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.2
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "API request failed"
            throw NSError(domain: "OpenAI", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "AI provider error: \(errorText)"])
        }

        return try parseChatResponse(data)
    }

    // MARK: - Formatting & Response Parsing

    private func buildSystemPrompt(style: CommitStyle) -> String {
        var base = """
        You are an expert Git commit message assistant.
        Analyze the provided git diff carefully and generate an accurate, high-quality commit message.

        Rules:
        1. The FIRST line MUST be the summary (under 60 characters).
        2. Do NOT put periods at the end of the summary line.
        3. Do NOT wrap the entire answer in markdown codeblocks (no ```).
        4. If there are additional details worth mentioning, leave ONE blank line after the summary, then provide concise bullet points explaining the why and what.
        """

        switch style {
        case .conventional:
            base += "\n5. Format the summary according to the Conventional Commits specification (e.g. feat:, fix:, refactor:, chore:, docs:, test:, style:). Example: feat(auth): add GitHub Copilot commit generator"
        case .gitmoji:
            base += "\n5. Start the summary with a relevant gitmoji followed by a conventional commit type (e.g. ✨ feat:, 🐛 fix:, ♻️ refactor:, 📝 docs:). Example: ✨ feat(auth): add GitHub Copilot commit generator"
        case .concise:
            base += "\n5. Write a simple imperative summary line without conventional prefixes. Do not output any description unless critical. Example: Add GitHub Copilot commit generator"
        case .detailed:
            base += "\n5. Provide a conventional commit summary, followed by a blank line and 2-4 clear bullet points summarizing key changes."
        }

        return base
    }

    private func parseChatResponse(_ data: Data) throws -> GeneratedCommitMessage {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "AICommitService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Unexpected response format from AI service."])
        }

        var cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            let lines = cleaned.components(separatedBy: "\n")
            let filtered = lines.filter { !$0.hasPrefix("```") }
            cleaned = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lines = cleaned.components(separatedBy: "\n")
        guard let firstLine = lines.first, !firstLine.isEmpty else {
            return GeneratedCommitMessage(summary: "update changes", description: "")
        }

        let summary = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptionLines = lines.dropFirst()
        let description = descriptionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return GeneratedCommitMessage(summary: summary, description: description)
    }
}
