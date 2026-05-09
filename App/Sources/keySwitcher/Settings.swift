import Foundation
import AppKit
import ServiceManagement

struct HotkeyConfig: Codable {
    var smartConvert: HotkeyBinding
    var forceSwap: HotkeyBinding
    var transliterate: HotkeyBinding
    var toggleEnabled: HotkeyBinding
    var polishText: HotkeyBinding

    init(
        smartConvert: HotkeyBinding,
        forceSwap: HotkeyBinding,
        transliterate: HotkeyBinding,
        toggleEnabled: HotkeyBinding = .disabled,
        polishText: HotkeyBinding = .modifier(ModifierHotkey.rightOption)
    ) {
        self.smartConvert = smartConvert
        self.forceSwap = forceSwap
        self.transliterate = transliterate
        self.toggleEnabled = toggleEnabled
        self.polishText = polishText
    }

    enum CodingKeys: String, CodingKey {
        case smartConvert, forceSwap, transliterate, toggleEnabled, polishText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.smartConvert = try c.decode(HotkeyBinding.self, forKey: .smartConvert)
        self.forceSwap = try c.decode(HotkeyBinding.self, forKey: .forceSwap)
        self.transliterate = try c.decode(HotkeyBinding.self, forKey: .transliterate)
        self.toggleEnabled = try c.decodeIfPresent(HotkeyBinding.self, forKey: .toggleEnabled) ?? .disabled
        self.polishText = try c.decodeIfPresent(HotkeyBinding.self, forKey: .polishText)
            ?? .modifier(ModifierHotkey.rightOption)
    }

    static let `default` = HotkeyConfig(
        smartConvert: .modifier(ModifierHotkey.leftOption),
        forceSwap:    .combo(KeyCombo(modifiers: [.option, .shift], keyCode: 3)),
        transliterate: .combo(KeyCombo(modifiers: [.option, .shift], keyCode: 17)),
        toggleEnabled: .disabled,
        polishText: .modifier(ModifierHotkey.rightOption)
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
            SoundFeedback.preview()
        }
    }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled") }
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
    let revertThreshold: Int = 3

    @Published var aiWorkerURL: String {
        didSet { UserDefaults.standard.set(aiWorkerURL, forKey: "aiWorkerURL") }
    }
    @Published var aiModel: String {
        didSet { UserDefaults.standard.set(aiModel, forKey: "aiModel") }
    }
    @Published var aiEnabled: Bool {
        didSet { UserDefaults.standard.set(aiEnabled, forKey: "aiEnabled") }
    }

    @Published var customApiEndpoint: String {
        didSet { UserDefaults.standard.set(customApiEndpoint, forKey: "customApiEndpoint") }
    }
    @Published var customApiKey: String {
        didSet { UserDefaults.standard.set(customApiKey, forKey: "customApiKey") }
    }
    @Published var customApiModel: String {
        didSet { UserDefaults.standard.set(customApiModel, forKey: "customApiModel") }
    }

    var useCustomAPI: Bool {
        !customApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        let stored = (d.array(forKey: "ignoredAutoSwap") as? [String]) ?? []
        self.ignoredAutoSwap = Set(stored.map { $0.lowercased() })
        let storedForce = (d.array(forKey: "forceSwapWords") as? [String]) ?? []
        self.forceSwapWords = Set(storedForce.map { $0.lowercased() })
        self.pendingReverts = (d.dictionary(forKey: "pendingReverts") as? [String: Int]) ?? [:]
        self.aiWorkerURL = d.string(forKey: "aiWorkerURL") ?? Settings.defaultWorkerURL
        self.aiModel = d.string(forKey: "aiModel") ?? Settings.defaultAIModel
        self.aiEnabled = d.object(forKey: "aiEnabled") as? Bool ?? true
        self.customApiEndpoint = d.string(forKey: "customApiEndpoint") ?? ""
        self.customApiKey = d.string(forKey: "customApiKey") ?? ""
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
