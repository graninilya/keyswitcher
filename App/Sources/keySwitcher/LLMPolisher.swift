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

private let polishSystemPrompt = """
Ты пунктуационный корректор. Тебе дают текст — ты возвращаешь ЕГО ЖЕ полностью, только с минимальными правками.

ЧТО МОЖНО ПРАВИТЬ:
- Знаки препинания (запятые, точки, тире, скобки, вопросительные/восклицательные).
- Капитализация первой буквы предложения.
- Явные опечатки (1-2 перестановки/пропуска/лишние буквы).

СТРОГИЕ ПРАВИЛА (нарушение = провал):
1. ВОЗВРАЩАЙ ВЕСЬ ИСХОДНЫЙ ТЕКСТ ПОЛНОСТЬЮ — все слова от начала до конца, даже если в начале/середине нечего править.
2. НЕ добавляй слов которых не было в оригинале.
3. НЕ удаляй существующие слова.
4. НЕ меняй формы слов (падеж, число, время).
5. НЕ перефразируй и не меняй порядок слов.
6. НЕ давай объяснений, кавычек вокруг ответа, никаких префиксов вроде "Исправлено:".

ПРИМЕРЫ:
Вход: "Ваш профиль будет активен после модерации (до 3-х рабочих дней). ладно ок?"
Выход: "Ваш профиль будет активен после модерации (до 3-х рабочих дней). Ладно, ок?"

Вход: "купил масло хлеб молоко"
Выход: "Купил масло, хлеб, молоко."

Вход: "крутяык"
Выход: "крутяк"

Вход: "Это нормальное предложение."
Выход: "Это нормальное предложение."
"""

enum LLMPolisher {

    static func polish(_ text: String) async -> Result<String, LLMPolishError> {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .failure(.emptyText) }
        guard Settings.shared.aiEnabled else { return .failure(.disabled) }

        if Settings.shared.useCustomAPI {
            return await polishViaCustomAPI(text)
        }
        return await polishViaWorker(text)
    }

    private static func polishViaWorker(_ text: String) async -> Result<String, LLMPolishError> {
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

    private static func polishViaCustomAPI(_ text: String) async -> Result<String, LLMPolishError> {
        let endpoint = Settings.shared.customApiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Settings.shared.customApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = Settings.shared.customApiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, !key.isEmpty, !model.isEmpty else {
            return .failure(.http(0, "Заполни URL, ключ и модель в настройках"))
        }
        guard let url = URL(string: endpoint) else {
            return .failure(.http(0, "Invalid endpoint URL: \(endpoint)"))
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": polishSystemPrompt],
                ["role": "user", "content": text],
            ],
            "temperature": 0.2,
            "max_tokens": 2048,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.decode("encode body"))
        }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
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
            guard let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String, !content.isEmpty else {
                return .failure(.decode("no choices[0].message.content"))
            }
            return .success(content.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failure(.network(error))
        }
    }
}
