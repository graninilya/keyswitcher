import Foundation

enum LLMPolishError: Error, LocalizedError {
    case disabled
    case emptyText
    case http(Int, String)
    case decode(String)
    case network(Error)
    case unreachable

    /// Короткая формулировка для плашки — её читает человек, а не разработчик.
    var userMessage: String {
        switch self {
        case .disabled:   return "AI выключен — включить можно в настройках"
        case .emptyText:  return "Тут нечего править"
        case .unreachable:
            return "Не могу достучаться до сервиса. В России его часто блокируют — выручает VPN или свой ключ в настройках"
        case .http(let code, let body):
            switch code {
            case 401, 403: return "Ключ не подошёл — проверь его в настройках"
            case 429:      return "Слишком часто. Подожди чуть-чуть"
            case 500...599: return "У сервиса неполадки. Попробуй позже"
            // 0 — наша же проверка настроек, 200 — сервис объяснил отказ сам.
            // В обоих случаях текст осмысленный, показываем его.
            case 0, 200:   return String(body.prefix(160))
            default:       return "Сервис ответил ошибкой \(code)"
            }
        case .decode:     return "Пришёл странный ответ — не смог его разобрать"
        case .network(let e):
            let ns = e as NSError
            switch ns.code {
            case NSURLErrorTimedOut:             return "Ответа так и не дождался"
            case NSURLErrorNotConnectedToInternet: return "Похоже, нет интернета"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return "Адрес не отвечает. В России его часто блокируют — выручает VPN или свой ключ в настройках"
            case NSURLErrorNetworkConnectionLost: return "Связь оборвалась. Попробуй ещё раз"
            case NSURLErrorCancelled:            return "Запрос прервался. Попробуй ещё раз"
            default:                             return "Что-то не так со связью"
            }
        }
    }

    var errorDescription: String? {
        switch self {
        case .disabled:           return "AI отключён в настройках"
        case .emptyText:          return "Пустой текст"
        case .unreachable:        return "Все адреса недоступны"
        case .http(let s, let b): return "HTTP \(s): \(b.prefix(120))"
        case .decode(let m):      return "Ответ невалидный: \(m)"
        case .network(let e):     return "Сеть: \(e.localizedDescription)"
        }
    }

    /// Стоит ли пробовать другой адрес.
    var worthRetryingElsewhere: Bool {
        switch self {
        case .network:            return true
        case .http(let code, _):  return code == 0 || code >= 500
        case .unreachable:        return true
        default:                  return false
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

    /// Адреса пробуются по очереди: основной домен в России нередко заблокирован,
    /// и запасной может оказаться живым без всякого VPN.
    private static func workerCandidates() -> [String] {
        var list = [Settings.shared.aiWorkerURL]
        for mirror in Settings.shared.aiMirrorURLs where !mirror.isEmpty {
            if !list.contains(mirror) { list.append(mirror) }
        }
        return list
    }

    private static func polishViaWorker(_ text: String) async -> Result<String, LLMPolishError> {
        var lastError: LLMPolishError = .unreachable

        for urlString in workerCandidates() {
            let result = await requestWorker(urlString, text: text)
            switch result {
            case .success(let out):
                LLMTransport.noteSuccess()
                return .success(out)
            case .failure(let error):
                lastError = error
                guard error.worthRetryingElsewhere else { return .failure(error) }
                // Считаем только сетевые: 5xx и опечатка в адресе соединением не лечатся.
                if case .network = error { LLMTransport.noteFailure() }
                Log.hotkey.info("адрес не ответил, пробую следующий")
            }
        }
        return .failure(lastError)
    }

    private static func requestWorker(_ urlString: String, text: String) async -> Result<String, LLMPolishError> {
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

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload

        do {
            let (data, response) = try await LLMTransport.current().data(for: req)
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
            let (data, response) = try await LLMTransport.current().data(for: req)
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
            LLMTransport.noteSuccess()
            return .success(content.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            LLMTransport.noteFailure()
            return .failure(.network(error))
        }
    }
}
