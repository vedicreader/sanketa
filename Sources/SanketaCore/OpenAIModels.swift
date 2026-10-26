import Foundation

/// Rules for the model list of an OpenAI-compatible server and the default model choice.
public enum OpenAIModels {
    public static func host(_ url: URL) -> String {
        (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    public static func isOpenAI(_ baseURL: URL) -> Bool { host(baseURL) == "api.openai.com" }

    public static func isLocal(_ baseURL: URL) -> Bool { ["localhost", "127.0.0.1", "::1"].contains(host(baseURL)) }

    /// https, or plain http to this Mac only: the key and the query must not cross the network in clear text.
    public static func isAllowed(_ baseURL: URL) -> Bool {
        switch baseURL.scheme?.lowercased() {
        case "https": return true
        case "http": return isLocal(baseURL)
        default: return false
        }
    }

    public static let insecureNote = "The server address must start with https://"

    static let excluded = ["audio", "realtime", "transcribe", "tts", "image", "search", "embedding", "moderation", "instruct",
                           "codex", "deep-research", "computer-use", "dall-e", "whisper"]

    /// The ids that can answer a chat request, sorted. Another server's ids can't be classified, so all are kept.
    public static func chatCapable(_ ids: [String], openAI: Bool) -> [String] {
        guard openAI else { return ids.sorted() }
        return ids.filter { id in
            id.range(of: #"^(gpt-|chatgpt-|o[0-9])"#, options: .regularExpression) != nil
                && !excluded.contains { id.contains($0) }
                && id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil
                // chat-latest aliases and pro models do not take the request this chooser sends (strict schema,
                // low reasoning effort); o1-mini and o1-preview do not take `reasoning_effort`
                && id.range(of: #"(chat-latest$|-pro(-|$)|^o1-(mini|preview))"#, options: .regularExpression) == nil
        }.sorted()
    }

    /// Cheapest first, by input price on 2026-10-24.
    public static let preference = ["gpt-5-nano", "gpt-4.1-nano", "gpt-4o-mini", "gpt-5-mini", "gpt-4.1-mini"]

    /// The first `preference` id present; else the smallest `nano` id; else the smallest `mini` id; else the smallest id.
    public static func cheapest(_ chatCapable: [String]) -> String? {
        if let p = preference.first(where: chatCapable.contains) { return p }
        let sorted = chatCapable.sorted()
        return sorted.first { $0.contains("nano") } ?? sorted.first { $0.contains("mini") } ?? sorted.first
    }

    /// The name that people know for an OpenAI model id, such as "GPT-5 Nano" for `gpt-5-nano` or "o3 Mini" for
    /// `o3-mini`. An id of another form, such as one from a different server, stays as it is.
    public static func displayName(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard let head = parts.first else { return id }
        let name: String, rest: ArraySlice<String>
        switch head {
        case "gpt", "chatgpt":
            guard parts.count > 1, parts[1].first?.isNumber == true else { return id }
            name = (head == "gpt" ? "GPT-" : "ChatGPT-") + parts[1]
            rest = parts.dropFirst(2)
        case let h where h.range(of: #"^o[0-9]+$"#, options: .regularExpression) != nil:
            name = h
            rest = parts.dropFirst()
        default: return id
        }
        // words get a capital letter; a date such as 2024-08-06 stays one word
        var words = [name], numeric = false
        for p in rest {
            let n = p.allSatisfy(\.isNumber)
            if n && numeric { words[words.count - 1] += "-" + p } else { words.append(n ? p : p.prefix(1).uppercased() + p.dropFirst()) }
            numeric = n
        }
        return words.joined(separator: " ")
    }

    public static func isReasoning(_ id: String) -> Bool { id.range(of: #"^(o[0-9]|gpt-5)"#, options: .regularExpression) != nil }
}

/// The chat completions request body and answer. The body holds only the prompt: instructions, request and entries.
public enum OpenAIRequest {
    public static func body(model: String, prompt: ChoicePrompt, openAI: Bool, schema: Bool = true) -> Data {
        var b: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": prompt.instructions], ["role": "user", "content": prompt.userText]],
        ]
        if schema {
            b["response_format"] = ["type": "json_schema", "json_schema": [
                "name": "choice", "strict": true,
                "schema": [
                    "type": "object",
                    "properties": ["picks": ["type": "array", "items": ["type": "string", "enum": prompt.refs],
                                             "maxItems": prompt.maxPicks] as [String: Any]],
                    "required": ["picks"], "additionalProperties": false,
                ] as [String: Any],
            ] as [String: Any]] as [String: Any]
        }
        if openAI {
            b["store"] = false
            if OpenAIModels.isReasoning(model) { b["max_completion_tokens"] = 1000; b["reasoning_effort"] = "low" }
            else { b["max_completion_tokens"] = 100 }
        } else {
            b["max_tokens"] = 100
        }
        return (try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])) ?? Data()
    }

    /// The content without `<think>…</think>` blocks and a Markdown code fence, which some servers add when they
    /// do not take the schema.
    static func unwrapped(_ content: String) -> String {
        var s = content.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") && s.hasSuffix("```") && s.count >= 6 {
            s = String(s.dropFirst(3).dropLast(3).drop { $0.isLetter }).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// `choices[0].message.content` read as `{"picks": [...]}`.
    public static func parse(_ data: Data) throws -> [String] {
        struct Reply: Decodable {
            struct Choice: Decodable { struct Message: Decodable { var content: String? }; var message: Message }
            var choices: [Choice]
        }
        struct Picks: Decodable { var picks: [String] }
        guard let r = try? JSONDecoder().decode(Reply.self, from: data), let content = r.choices.first?.message.content,
              let p = try? JSONDecoder().decode(Picks.self, from: Data(unwrapped(content).utf8)) else { throw ChoiceError.badResponse }
        return p.picks
    }
}
