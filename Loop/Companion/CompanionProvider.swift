import Foundation
import Security

enum CompanionKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Loop") + ".companion",
         kSecAttrAccount as String: "openrouter"]
    }

    static func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw CompanionError.invalid("The API key could not be read from Keychain. Unlock the phone and try again.")
        }
        return key
    }

    static func write(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace), key.count <= 512 else {
            throw CompanionError.invalid("Enter a valid OpenRouter API key.")
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw CompanionError.invalid("Could not securely save the API key.") }
        } else if status != errSecSuccess {
            throw CompanionError.invalid("Could not securely update the API key.")
        }
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CompanionError.invalid("Could not remove the API key.")
        }
    }
}

struct CompanionToolCall {
    let id: String
    let name: String
    let arguments: Data
}

struct CompanionCompletion {
    let message: [String: Any]
    let text: String
    let calls: [CompanionToolCall]
}

protocol CompanionProvider {
    func complete(model: String, reasoningEffort: CompanionReasoningEffort, messages: [[String: Any]], tools: [[String: Any]]) async throws -> CompanionCompletion
}

struct OpenRouterCompanionProvider: CompanionProvider {
    static func requestBody(model: String, reasoningEffort: CompanionReasoningEffort, messages: [[String: Any]], tools: [[String: Any]]) -> [String: Any] {
        var body: [String: Any] = [
            "model": model, "messages": messages,
            "stream": false, "max_tokens": 16384, "provider": ["require_parameters": true]
        ]
        if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto" }
        if reasoningEffort != .providerDefault { body["reasoning"] = ["effort": reasoningEffort.rawValue] }
        return body
    }

    func complete(model: String, reasoningEffort: CompanionReasoningEffort, messages: [[String: Any]], tools: [[String: Any]]) async throws -> CompanionCompletion {
        guard let key = try CompanionKeychain.read(), !key.isEmpty else {
            throw CompanionError.invalid("Connect your OpenRouter key in Mochi’s settings first.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Michizzloop Mochi", forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(model: model, reasoningEffort: reasoningEffort, messages: messages, tools: tools))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CompanionError.invalid("No response from OpenRouter.") }
        guard (200..<300).contains(http.statusCode) else {
            // Do not surface raw provider bodies: these can echo request data or credentials.
            let explanation: String
            switch http.statusCode {
            case 401, 403: explanation = "OpenRouter rejected the key or model access. Check your connection settings."
            case 402: explanation = "Your OpenRouter account needs credits."
            case 429: explanation = "OpenRouter is rate limiting requests. Try again shortly."
            default: explanation = "OpenRouter could not complete the request (HTTP \(http.statusCode)). Check the model ID or try again."
            }
            throw CompanionError.invalid(explanation)
        }
        guard data.count <= 2_000_000,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], let choice = choices.first,
              let message = choice["message"] as? [String: Any] else {
            throw CompanionError.invalid("OpenRouter returned an unreadable response.")
        }
        guard choice["finish_reason"] as? String != "length" else {
            throw CompanionError.invalid("The model ran out of response space. Try a shorter request or a different model.")
        }
        let rawCalls = message["tool_calls"] as? [[String: Any]] ?? []
        guard rawCalls.count <= 8 else { throw CompanionError.invalid("The model requested too many actions at once.") }
        let calls = try rawCalls.map { call -> CompanionToolCall in
            guard let id = call["id"] as? String,
                  let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  let arguments = function["arguments"] as? String, arguments.utf8.count <= 16_384 else {
                throw CompanionError.invalid("The model returned an invalid tool request. Nothing was changed.")
            }
            return CompanionToolCall(id: id, name: name, arguments: Data(arguments.utf8))
        }
        let text = message["content"] as? String ?? ""
        guard !text.isEmpty || !calls.isEmpty else { throw CompanionError.invalid("The model returned an empty response.") }
        return CompanionCompletion(message: message, text: text, calls: calls)
    }
}

enum OpenRouterModelCatalog {
    struct Response: Decodable { var data: [CompanionModel] }

    static func load() async throws -> [CompanionModel] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: URL(string: "https://openrouter.ai/api/v1/models")!)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 15_000_000 else {
            throw CompanionError.invalid("Could not refresh OpenRouter’s model list. Your saved model is unchanged.")
        }
        let models = try JSONDecoder().decode(Response.self, from: data).data.filter(\.isChatToolModel)
        guard !models.isEmpty else { throw CompanionError.invalid("OpenRouter returned no compatible models. Your saved model is unchanged.") }
        return models.sorted {
            if ($0.id == CompanionModel.gpt61.id) != ($1.id == CompanionModel.gpt61.id) { return $0.id == CompanionModel.gpt61.id }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

enum CompanionTools {
    private static func tool(_ name: String, _ description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
            "parameters": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]]
    }

    static let definitions: [[String: Any]] = {
        let string: [String: Any] = ["type": "string"]
        let number: [String: Any] = ["type": "number"]
        let date: [String: Any] = ["type": "string", "description": "ISO 8601 date with explicit UTC offset, e.g. 2026-10-18T21:00:00-04:00"]
        let interval: [String: Any] = ["start": date, "end": date]
        let rule: [String: Any] = ["type": "object", "additionalProperties": false, "properties": [
            "kind": ["type": "string", "enum": ["dailySummary", "fallingGlucose", "missedCarbs"]],
            "title": string, "enabled": ["type": "boolean"],
            "hour": ["type": "integer"], "minute": ["type": "integer"], "timeZone": string,
            "belowMGDL": number, "rateMGDLPerMinute": number, "windowMinutes": number,
            "carbLookbackMinutes": number, "cooldownMinutes": number
        ], "required": ["kind", "title", "enabled"]]
        return [
            tool("get_glucose_summary", "Read available recorded glucose statistics for up to 7 days. Requires health-data sharing permission.", properties: interval, required: ["start", "end"]),
            tool("get_insulin_summary", "Read recorded insulin delivery totals; not a dosing recommendation. Requires health-data sharing permission.", properties: interval, required: ["start", "end"]),
            tool("get_carb_entries", "Read logged carb entries for a date range. Requires health-data sharing permission.", properties: interval, required: ["start", "end"]),
            tool("get_cycle_context", "Read today's menstrual-cycle context, up to six logged period records, and clearly labeled calendar estimates. Symptoms such as energy, mood, sleep, and cravings are not tracked. Includes sourced general context. Requires health-data sharing permission. Use for cycle/period questions; never infer insulin resistance or symptoms from phase alone.", properties: [:], required: []),
            tool("propose_automation", "Prepare a rule for explicit user review. Daily summaries require hour, minute, timeZone. Glucose rules require positive rateMGDLPerMinute, windowMinutes, cooldownMinutes; fallingGlucose also needs belowMGDL; missedCarbs needs carbLookbackMinutes. Ask for missing settings; do not invent them. Does not enable the rule.", properties: ["rule": rule], required: ["rule"]),
            tool("list_automations", "List saved rules, pending actions, and their real statuses.", properties: [:], required: []),
            tool("propose_automation_update", "Propose a complete replacement for a saved rule, including pausing it with enabled=false. Requires user approval.", properties: ["id": string, "rule": rule], required: ["id", "rule"]),
            tool("prepare_carb_entry", "Prepare a carb draft for the normal carb form. Ask the user for grams, date, and absorption hours. Never infer grams from a glucose rise. Nothing is saved by this tool.", properties: ["grams": number, "date": date, "absorptionHours": number], required: ["grams", "date", "absorptionHours"]),
            tool("update_personality", "Propose a new complete personality prompt for user approval. This affects tone only, not app permissions or clinical rules.", properties: ["prompt": string], required: ["prompt"])
        ]
    }()
}
