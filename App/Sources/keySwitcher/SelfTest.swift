import Foundation
import AppKit
import ApplicationServices

/// Проверка детектора на живых словарях: `keySwitcher --self-test`.
///
/// Полноценный XCTest потребовал бы разделить проект на библиотеку и исполняемый
/// таргет — правка структуры ради тестов трогала бы и сам детектор. Здесь проверка
/// идёт по тем же данным, что в бою, и годится для запуска в CI.
enum SelfTest {

    /// Раскладка, в которой пользователь физически набрал бы такой текст.
    /// Для строк без кириллицы направление свапа берётся из ТЕКУЩЕЙ раскладки
    /// системы, поэтому её надо выставить явно — иначе результат зависит от того,
    /// что было включено на машине в момент запуска.
    private enum Typed {
        case latin, cyrillic

        var language: InputLanguage {
            self == .latin ? .english : .russian
        }
    }

    /// Ожидание: `nil` — оставить как есть, строка — что должно получиться.
    private static let cases: [(input: String, typed: Typed, expected: String?)] = [
        // Промах раскладкой: набрано латиницей, имелась в виду кириллица
        ("ghbdtn",     .latin, "привет"),
        ("gjrf",       .latin, "пока"),
        ("cgfcb,j",    .latin, "спасибо"),
        ("hf,jnftn",   .latin, "работает"),
        ("ckjdj",      .latin, "слово"),
        ("hfcrkflrf",  .latin, "раскладка"),
        ("z,kjrj",     .latin, "яблоко"),

        // Обратное направление
        ("руддщ",      .cyrillic, "hello"),
        ("цкшеу",      .cyrillic, "write"),

        // Валидные слова — трогать нельзя
        ("привет",     .cyrillic, nil),
        ("работает",   .cyrillic, nil),
        ("буквы",      .cyrillic, nil),
        ("hello",      .latin, nil),
        ("world",      .latin, nil),
        ("system",     .latin, nil),

        // Аббревиатуры из встроенного списка
        ("мзт",        .cyrillic, "vpn"),
        ("ыйд",        .cyrillic, "sql"),
        ("вты",        .cyrillic, "dns"),
        ("vpn",        .latin, nil),
        ("sql",        .latin, nil),

        // Одиночные буквы — предлоги не трогаем
        ("я",          .cyrillic, nil),
        ("и",          .cyrillic, nil),
        ("a",          .latin, nil),

        // Составные слова через дефис
        ("что-то",     .cyrillic, nil),
        ("какой-то",   .cyrillic, nil),
        ("well-known", .latin, nil),
        ("e-mail",     .latin, nil),
        ("xnj-nj",     .latin, "что-то"),

        // Ключи командной строки: ведущий дефис — не буква, трогать нельзя
        ("-rf",        .latin, nil),
        ("-vvv",       .latin, nil),
        ("--force",    .latin, nil),
        ("-la",        .latin, nil),
        ("-i",         .latin, nil),
        ("nj-",        .latin, nil),

        // Слишком короткое или мусор
        ("q",          .latin, nil),
        ("---",        .latin, nil),
    ]

    /// Проверка доставки синтетических событий: `keySwitcher --test-injection`.
    /// Отвечает на вопрос «доходят ли наши нажатия до приложений» — без него
    /// приходится гадать, потерялось разрешение или сломана отправка.
    static func testInjection() -> Never {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("исходное", forType: .string)
        let before = pb.changeCount

        print("Доступ к управлению: \(AXIsProcessTrusted() ? "выдан" : "НЕ ВЫДАН")")
        print("Через 3 секунды отправлю ⌘C — выделите любой текст.")
        Thread.sleep(forTimeInterval: 3)

        InputInjection.shared.sendCommand(keyCode: 8)
        Thread.sleep(forTimeInterval: 0.6)

        let after = pb.changeCount
        if after > before {
            let copied = pb.string(forType: .string) ?? ""
            print("⌘C дошёл: буфер изменился, скопировано \(copied.count) символов")
        } else {
            print("⌘C НЕ дошёл: буфер не изменился (было \(before), стало \(after))")
            print("Значит система не доставляет наши события приложениям.")
        }
        exit(after > before ? 0 : 1)
    }

    static func run() -> Never {
        let restore = InputSourceSwitcher.current()
        defer { if let restore = restore { InputSourceSwitcher.restore(restore) } }

        var passed = 0
        var failures: [String] = []

        for c in cases {
            InputSourceSwitcher.switchTo(c.typed.language)
            // Переключение раскладки применяется не мгновенно.
            Thread.sleep(forTimeInterval: 0.05)
            KeyboardLayoutCache.invalidate()

            let got = LayoutMap.shared.autoConvert(c.input)
            let ok: Bool
            if let expected = c.expected {
                ok = got?.lowercased() == expected.lowercased()
            } else {
                ok = got == nil || got?.lowercased() == c.input.lowercased()
            }
            if ok {
                passed += 1
            } else {
                let expectedText = c.expected ?? "<не трогать>"
                let gotText = got ?? "<не тронуто>"
                failures.append("  \(c.input): ожидалось \(expectedText), получено \(gotText)")
            }
        }

        // exit() ниже пропустит defer, поэтому возвращаем раскладку явно и даём
        // системе успеть применить выбор.
        if let restore = restore {
            InputSourceSwitcher.restore(restore)
            Thread.sleep(forTimeInterval: 0.1)
        }

        print("Детектор: \(passed)/\(cases.count)")
        if !failures.isEmpty {
            print("Расхождения:")
            failures.forEach { print($0) }
        }

        // Проверки, не зависящие ни от словарей, ни от раскладки.
        var unitFailures: [String] = []

        if Transliteration.apply("Иванов").lowercased() != "ivanov" {
            unitFailures.append("  транслитерация: Иванов → \(Transliteration.apply("Иванов"))")
        }
        if Transliteration.apply("hello") != "hello" {
            unitFailures.append("  транслитерация: латиница должна остаться нетронутой")
        }

        // Типографика: механические правила, которые раньше уходили в модель.
        let typo: [(String, String)] = [
            ("слово - слово",        "слово — слово"),
            ("что-то",               "что-то"),
            ("привет , как дела ?",  "привет, как дела?"),
            ("текст...",             "текст…"),
            ("он сказал \"да\"",     "он сказал «да»"),
            ("два  пробела",         "два пробела"),
            ("привет,как дела",      "привет, как дела"),
            ("текст  .",             "текст."),

            // Числа и диапазоны — тире меняет смысл, трогать нельзя
            ("5 - 3 = 2",            "5 - 3 = 2"),
            ("2020 - 2024",          "2020 - 2024"),
            ("3.14 и 10:30",         "3.14 и 10:30"),

            // Сокращения и инициалы: точка не заканчивает предложение
            ("и т.д. и т.п.",        "и т.д. и т.п."),
            ("А.С. Пушкин",          "А.С. Пушкин"),

            // Код, пути, ссылки — не наша территория
            ("{\"name\": \"Ilya\"}", "{\"name\": \"Ilya\"}"),
            ("path/to/file.txt",     "path/to/file.txt"),
            ("README.md",            "README.md"),
            ("x != y",               "x != y"),
            ("a ? b : c",            "a ? b : c"),
            ("user@example.com",     "user@example.com"),
            ("https://ya.ru/a,b",    "https://ya.ru/a,b"),
            ("ls -la",               "ls -la"),
            ("std::vector",          "std::vector"),
            ("obj.method().chain()", "obj.method().chain()"),
        ]
        for (input, expected) in typo {
            var opts = Typography.Options.all
            opts.nbsp = false   // неразрывные пробелы визуально неотличимы в сравнении
            let got = Typography.apply(input, options: opts)
            if got != expected {
                unitFailures.append("  типографика: '\(input)' → '\(got)', ожидалось '\(expected)'")
            }
        }

        // Повторное применение не должно менять результат: хоткей жмут по два раза,
        // и правила прогоняются до и после модели.
        for (input, _) in typo {
            let once = Typography.apply(input)
            let twice = Typography.apply(once)
            if once != twice {
                unitFailures.append("  типографика не идемпотентна: '\(input)' → '\(once)' → '\(twice)'")
            }
        }

        let nbsp = Typography.apply("в лесу", options: .all)
        if !nbsp.contains("\u{00A0}") {
            unitFailures.append("  типографика: после короткого предлога нужен неразрывный пробел")
        }
        if Typography.apply("И В ЛЕСУ", options: .all).contains("\u{00A0}") {
            unitFailures.append("  типографика: в аббревиатуре неразрывные пробелы не нужны")
        }

        if Stats.humanDuration(45) != "45 сек" { unitFailures.append("  длительность: 45 сек") }
        if Stats.humanDuration(90) != "1 мин" { unitFailures.append("  длительность: 1 мин") }
        if Stats.humanDuration(3600) != "1 ч" { unitFailures.append("  длительность: 1 ч") }

        let resonance = AntiResonanceGuard()
        if !resonance.allow(from: "ghbdtn", to: "привет") {
            unitFailures.append("  anti-resonance: первая замена должна проходить")
        }
        if resonance.allow(from: "привет", to: "ghbdtn") {
            unitFailures.append("  anti-resonance: обратная замена должна подавляться")
        }
        if !resonance.allow(from: "lf", to: "да") {
            unitFailures.append("  anti-resonance: другая пара должна проходить")
        }
        if !resonance.allow(from: "lf", to: "да") {
            unitFailures.append("  anti-resonance: повтор той же пары должен проходить")
        }

        if !unitFailures.isEmpty {
            print("Логика:")
            unitFailures.forEach { print($0) }
        }

        let allOk = failures.isEmpty && unitFailures.isEmpty
        print(allOk ? "OK" : "ЕСТЬ РАСХОЖДЕНИЯ")
        exit(allOk ? 0 : 1)
    }
}
