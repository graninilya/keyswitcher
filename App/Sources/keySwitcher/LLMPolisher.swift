import Foundation

enum LLMPolishError: Error, LocalizedError {
    case disabled
    case emptyText
    case http(Int, String)
    case decode(String)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .disabled:           return "AI отключён в настройках"
        case .emptyText:          return "Пустой текст"
        case .http(let s, let b): return "HTTP \(s): \(b.prefix(120))"
        case .decode(let m):      return "Ответ невалидный: \(m)"
        case .network(let e):     return "Сеть: \(e.localizedDescription)"
        }
    }
}

enum LLMPolisher {

    static func polish(_ text: String) async -> Result<String, LLMPolishError> {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .failure(.emptyText) }
        guard Settings.shared.aiEnabled else { return .failure(.disabled) }

        let urlString = Settings.shared.aiWorkerURL
        guard let url = URL(string: urlString) else {
            return .failure(.http(0, "Invalid worker URL: \(urlString)"))
        }

        let body: [String: Any] = [
            "model": Settings.shared.aiModel,
            "text": text,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.decode("encode body"))
        }

        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                let bodyStr = String(data: data, encoding: .utf8) ?? "<binary>"
                return .failure(.http(status, bodyStr))
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.decode("not a JSON object"))
            }
            if let ok = json["ok"] as? Bool, !ok {
                let err = json["error"] as? String ?? "(no message)"
                return .failure(.http(200, err))
            }
            guard let out = json["out"] as? String, !out.isEmpty else {
                return .failure(.decode("no 'out' field"))
            }
            return .success(out.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failure(.network(error))
        }
    }
}
