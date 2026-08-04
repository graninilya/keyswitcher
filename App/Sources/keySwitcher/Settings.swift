import Foundation
import AppKit
import ServiceManagement

extension Notification.Name {
    static let qkbStatusIconVisibilityChanged = Notification.Name("qkbStatusIconVisibilityChanged")
}

struct HotkeyConfig: Codable {
    var smartConvert: HotkeyBinding
    var forceSwap: HotkeyBinding
    var transliterate: HotkeyBinding
    var toggleEnabled: HotkeyBinding
    var polishText: HotkeyBinding
    var typography: HotkeyBinding

    init(
        smartConvert: HotkeyBinding,
        forceSwap: HotkeyBinding,
        transliterate: HotkeyBinding,
        toggleEnabled: HotkeyBinding = .disabled,
        polishText: HotkeyBinding = .modifier(ModifierHotkey.rightOption),
        typography: HotkeyBinding = .combo(KeyCombo(modifiers: [.option, .shift], keyCode: 35))
    ) {
        self.smartConvert = smartConvert
        self.forceSwap = forceSwap
        self.transliterate = transliterate
        self.toggleEnabled = toggleEnabled
        self.polishText = polishText
        self.typography = typography
    }

    enum CodingKeys: String, CodingKey {
        case smartConvert, forceSwap, transliterate, toggleEnabled, polishText, typography
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.smartConvert = try c.decode(HotkeyBinding.self, forKey: .smartConvert)
        self.forceSwap = try c.decode(HotkeyBinding.self, forKey: .forceSwap)
        self.transliterate = try c.decode(HotkeyBinding.self, forKey: .transliterate)
        self.toggleEnabled = try c.decodeIfPresent(HotkeyBinding.self, forKey: .toggleEnabled) ?? .disabled
        self.polishText = try c.decodeIfPresent(HotkeyBinding.self, forKey: .polishText)
            ?? .modifier(ModifierHotkey.rightOption)
        self.typography = try c.decodeIfPresent(HotkeyBinding.self, forKey: .typography)
            ?? .combo(KeyCombo(modifiers: [.option, .shift], keyCode: 35))
    }

    static let `default` = HotkeyConfig(
        smartConvert: .modifier(ModifierHotkey.leftOption),
        forceSwap:    .combo(KeyCombo(modifiers: [.option, .shift], keyCode: 3)),
        transliterate: .combo(KeyCombo(modifiers: [.option, .shift], keyCode: 17)),
        toggleEnabled: .disabled,
        polishText: .modifier(ModifierHotkey.rightOption),
        typography: .combo(KeyCombo(modifiers: [.option, .shift], keyCode: 35))
    )
}

enum HotkeyBinding: Codable, Equatable {
    case modifier(ModifierHotkey)
    case combo(KeyCombo)
    case disabled

    var displayName: String {
        switch self {
        case .modifier(let m): return m.displayName
        case .combo(let c): return c.displayName
        case .disabled: return "—"
        }
    }
}

struct KeyCombo: Codable, Equatable {
    var modifiersRaw: UInt
    var keyCode: Int

    init(modifiers: NSEvent.ModifierFlags, keyCode: Int) {
        self.modifiersRaw = modifiers.rawValue
        self.keyCode = keyCode
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRaw)
    }

    var displayName: String {
        var s = ""
        let m = modifiers
        if m.contains(.control)  { s += "⌃" }
        if m.contains(.option)   { s += "⌥" }
        if m.contains(.shift)    { s += "⇧" }
        if m.contains(.command)  { s += "⌘" }
        s += keyCodeName(keyCode)
        return s
    }
}

func keyCodeName(_ code: Int) -> String {
    let map: [Int: String] = [
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",
        11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
        18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",29:"0",
        31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",
        45:"N",46:"M",
        49:"Space",53:"Esc",36:"Return",51:"⌫",48:"Tab",
        96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",
        122:"F1",120:"F2",118:"F4"
    ]
    return map[code] ?? "key(\(code))"
}


final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var hotkeys: HotkeyConfig {
        didSet { save() }
    }
    @Published var soundName: String {
        didSet {
            UserDefaults.standard.set(soundName, forKey: "soundName")
            SoundFeedback.invalidateCache()
            SoundFeedback.preview()
        }
    }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled") }
    }
    @Published var autoConvertEnabled: Bool {
        didSet { UserDefaults.standard.set(autoConvertEnabled, forKey: "autoConvertEnabled") }
    }
    @Published var hideStatusIcon: Bool {
        didSet {
            UserDefaults.standard.set(hideStatusIcon, forKey: "hideStatusIcon")
            NotificationCenter.default.post(name: .qkbStatusIconVisibilityChanged, object: nil)
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin(launchAtLogin) }
    }
    @Published var ignoredAutoSwap: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(ignoredAutoSwap), forKey: "ignoredAutoSwap")
        }
    }
    @Published var forceSwapWords: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(forceSwapWords), forKey: "forceSwapWords")
        }
    }
    @Published var pendingReverts: [String: Int] {
        didSet {
            UserDefaults.standard.set(pendingReverts, forKey: "pendingReverts")
        }
    }
    @Published var pendingForceSwap: [String: Int] {
        didSet {
            UserDefaults.standard.set(pendingForceSwap, forKey: "pendingForceSwap")
        }
    }
    let revertThreshold: Int = 3
    let forceSwapPromoteThreshold: Int = 3

    @Published var aiWorkerURL: String {
        didSet { UserDefaults.standard.set(aiWorkerURL, forKey: "aiWorkerURL") }
    }
    /// Запасные адреса — пробуются по очереди, если основной молчит. Домен
    /// основного сервиса в России нередко заблокирован, и зеркало выручает.
    @Published var aiMirrorURLs: [String] {
        didSet { UserDefaults.standard.set(aiMirrorURLs, forKey: "aiMirrorURLs") }
    }
    @Published var aiModel: String {
        didSet { UserDefaults.standard.set(aiModel, forKey: "aiModel") }
    }
    @Published var aiEnabled: Bool {
        didSet { UserDefaults.standard.set(aiEnabled, forKey: "aiEnabled") }
    }
    /// Показывать «было → стало» до замены. По умолчанию выключено: подтверждение
    /// каждой правки — лишний шаг, а от неудачного результата уже защищает откат
    /// левым Option в течение 5 секунд.
    @Published var polishPreview: Bool {
        didSet { UserDefaults.standard.set(polishPreview, forKey: "polishPreview") }
    }
    /// Тире, ёлочки и пробелы расставляем сами — модели остаётся смысловая часть.
    @Published var typographyBeforeAI: Bool {
        didSet { UserDefaults.standard.set(typographyBeforeAI, forKey: "typographyBeforeAI") }
    }

    @Published var customApiEndpoint: String {
        didSet { UserDefaults.standard.set(customApiEndpoint, forKey: "customApiEndpoint") }
    }
    @Published var customApiKey: String {
        didSet {
            guard apiKeyLoaded else { return }   // не затирать хранилище значением-заглушкой
            KeychainStore.write(customApiKey, account: Settings.apiKeyAccount)
        }
    }
    static let apiKeyAccount = "customApiKey"

    private var apiKeyLoaded = false

    /// Читается при первом обращении: на старте связка ключей может ждать
    /// разблокировки, и приложение подвисало бы ещё до появления в строке меню.
    ///
    /// Только с главного потока: customApiKey — @Published, а публикация из фонового
    /// ломает SwiftUI и гонится с чтением из LLMPolisher.
    ///
    /// Флаг ставим лишь при внятном ответе хранилища. Заблокированная связка —
    /// не «ключа нет», и защёлкнуть это состояние на всю сессию нельзя.
    func ensureApiKeyLoaded() {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { self.ensureApiKeyLoaded() }
            return
        }
        guard !apiKeyLoaded else { return }

        let status = KeychainStore.readStatus(Settings.apiKeyAccount)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Log.clipboard.error("связка ключей недоступна (\(status, privacy: .public)) — повторю позже")
            return
        }
        apiKeyLoaded = true

        if status == errSecSuccess, let stored = KeychainStore.read(Settings.apiKeyAccount), !stored.isEmpty {
            UserDefaults.standard.removeObject(forKey: "customApiKey")
            customApiKey = stored
            return
        }
        // Из UserDefaults старое значение удаляем только после успешной записи
        // в связку — иначе сбой записи стоил бы пользователю ключа.
        let legacy = UserDefaults.standard.string(forKey: "customApiKey") ?? ""
        guard !legacy.isEmpty else { return }
        if KeychainStore.write(legacy, account: Settings.apiKeyAccount) {
            UserDefaults.standard.removeObject(forKey: "customApiKey")
            Log.clipboard.info("API-ключ перенесён в связку ключей")
        }
        customApiKey = legacy
    }
    @Published var customApiModel: String {
        didSet { UserDefaults.standard.set(customApiModel, forKey: "customApiModel") }
    }

    var useCustomAPI: Bool {
        ensureApiKeyLoaded()
        return !customApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !customApiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let defaultWorkerURL = "https://qkb-llm.graninilya.workers.dev"
    static let defaultAIModel = "@cf/google/gemma-3-12b-it"

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "hotkeys"),
           let cfg = try? JSONDecoder().decode(HotkeyConfig.self, from: data) {
            self.hotkeys = cfg
        } else {
            self.hotkeys = HotkeyConfig.default
        }
        if let stored = d.string(forKey: "soundName") {
            self.soundName = stored
        } else if (d.object(forKey: "soundsEnabled") as? Bool) == true {
            self.soundName = "Tink"
        } else {
            self.soundName = ""
        }
        self.enabled = d.object(forKey: "enabled") as? Bool ?? true
        self.autoConvertEnabled = d.object(forKey: "autoConvertEnabled") as? Bool ?? true
        self.hideStatusIcon = d.object(forKey: "hideStatusIcon") as? Bool ?? false
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        let stored = (d.array(forKey: "ignoredAutoSwap") as? [String]) ?? []
        self.ignoredAutoSwap = Set(stored.map { $0.lowercased() })
        let storedForce = (d.array(forKey: "forceSwapWords") as? [String]) ?? []
        self.forceSwapWords = Set(storedForce.map { $0.lowercased() })
        self.pendingReverts = (d.dictionary(forKey: "pendingReverts") as? [String: Int]) ?? [:]
        self.pendingForceSwap = (d.dictionary(forKey: "pendingForceSwap") as? [String: Int]) ?? [:]
        self.aiWorkerURL = d.string(forKey: "aiWorkerURL") ?? Settings.defaultWorkerURL
        self.aiMirrorURLs = d.stringArray(forKey: "aiMirrorURLs") ?? []
        self.aiModel = d.string(forKey: "aiModel") ?? Settings.defaultAIModel
        self.aiEnabled = d.object(forKey: "aiEnabled") as? Bool ?? true
        self.polishPreview = d.object(forKey: "polishPreview") as? Bool ?? false
        self.typographyBeforeAI = d.object(forKey: "typographyBeforeAI") as? Bool ?? true
        self.customApiEndpoint = d.string(forKey: "customApiEndpoint") ?? ""
        // Пустая строка на старте: связка ключей читается лениво, при первом обращении.
        // Обращение к ней на запуске может ждать разблокировки и подвешивает старт.
        self.customApiKey = ""
        self.customApiModel = d.string(forKey: "customApiModel") ?? ""
    }

    func addIgnored(_ word: String) {
        let key = word.lowercased()
        guard !key.isEmpty else { return }
        if !ignoredAutoSwap.contains(key) {
            ignoredAutoSwap.insert(key)
        }
        pendingReverts.removeValue(forKey: key)
        forceSwapWords.remove(key)
    }

    func removeIgnored(_ word: String) {
        ignoredAutoSwap.remove(word.lowercased())
    }

    func addForceSwap(_ word: String) {
        let key = word.lowercased()
        guard !key.isEmpty else { return }
        forceSwapWords.insert(key)
        ignoredAutoSwap.remove(key)
        pendingReverts.removeValue(forKey: key)
    }

    func removeForceSwap(_ word: String) {
        forceSwapWords.remove(word.lowercased())
    }

    /// Возвращает (count, promoted). promoted=true когда дошло до порога —
    /// caller показывает уведомление.
    func recordManualSwap(_ word: String) -> (count: Int, promoted: Bool) {
        let key = word.lowercased()
        guard !key.isEmpty else { return (0, false) }
        if forceSwapWords.contains(key) { return (0, false) }
        if LayoutMap.builtInForceSwap.contains(key) { return (0, false) }
        if ignoredAutoSwap.contains(key) { return (0, false) }
        let next = (pendingForceSwap[key] ?? 0) + 1
        if next >= forceSwapPromoteThreshold {
            pendingForceSwap.removeValue(forKey: key)
            return (next, true)
        }
        pendingForceSwap[key] = next
        return (next, false)
    }

    func dismissForceSwapCandidate(_ word: String) {
        pendingForceSwap.removeValue(forKey: word.lowercased())
    }

    @discardableResult
    func recordRevert(_ word: String) -> Bool {
        let key = word.lowercased()
        guard !key.isEmpty else { return false }
        if ignoredAutoSwap.contains(key) { return false }
        let next = (pendingReverts[key] ?? 0) + 1
        if next >= revertThreshold {
            pendingReverts.removeValue(forKey: key)
            ignoredAutoSwap.insert(key)
            return true
        } else {
            pendingReverts[key] = next
            return false
        }
    }

    private func applyLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("LaunchAtLogin error: \(error)")
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hotkeys) {
            UserDefaults.standard.set(data, forKey: "hotkeys")
        }
    }
}
