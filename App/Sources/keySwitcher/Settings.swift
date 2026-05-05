import Foundation
import AppKit
import ServiceManagement

struct HotkeyConfig: Codable {
    var smartConvert: HotkeyBinding
    var forceSwap: HotkeyBinding
    var transliterate: HotkeyBinding
    var toggleEnabled: HotkeyBinding

    // Дефолт для toggleEnabled — чтобы старые сохранения без этого поля корректно загружались
    init(
        smartConvert: HotkeyBinding,
        forceSwap: HotkeyBinding,
        transliterate: HotkeyBinding,
        toggleEnabled: HotkeyBinding = .disabled
    ) {
        self.smartConvert = smartConvert
        self.forceSwap = forceSwap
        self.transliterate = transliterate
        self.toggleEnabled = toggleEnabled
    }

    enum CodingKeys: String, CodingKey {
        case smartConvert, forceSwap, transliterate, toggleEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.smartConvert = try c.decode(HotkeyBinding.self, forKey: .smartConvert)
        self.forceSwap = try c.decode(HotkeyBinding.self, forKey: .forceSwap)
        self.transliterate = try c.decode(HotkeyBinding.self, forKey: .transliterate)
        self.toggleEnabled = try c.decodeIfPresent(HotkeyBinding.self, forKey: .toggleEnabled) ?? .disabled
    }

    static let `default` = HotkeyConfig(
        smartConvert: .modifier(ModifierHotkey.leftOption),
        forceSwap:    .combo(KeyCombo(modifiers: [.option, .shift], keyCode: 3)),
        transliterate: .combo(KeyCombo(modifiers: [.option, .shift], keyCode: 17)),
        toggleEnabled: .disabled
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
    @Published var soundsEnabled: Bool {
        didSet { UserDefaults.standard.set(soundsEnabled, forKey: "soundsEnabled") }
    }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled") }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin(launchAtLogin) }
    }

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "hotkeys"),
           let cfg = try? JSONDecoder().decode(HotkeyConfig.self, from: data) {
            self.hotkeys = cfg
        } else {
            self.hotkeys = HotkeyConfig.default
        }
        self.soundsEnabled = d.object(forKey: "soundsEnabled") as? Bool ?? false
        self.enabled = d.object(forKey: "enabled") as? Bool ?? true
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
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
