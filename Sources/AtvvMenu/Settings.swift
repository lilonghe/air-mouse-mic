import AppKit
import CoreGraphics

enum VoiceMode: String, CaseIterable, Identifiable {
    case hold
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold: return "长按触发"
        case .toggle: return "短按切换"
        }
    }

    var detail: String {
        switch self {
        case .hold: return "按住说话，松手结束"
        case .toggle: return "按一次开始，再按一次结束"
        }
    }
}

struct Hotkey: Equatable {
    var keyCode: CGKeyCode
    var modifiers: CGEventFlags
    var display: String

    static let defaultHotkey = Hotkey(
        keyCode: 34,
        modifiers: .maskControl,
        display: "⌃I"
    )

}

/// 设置持久化，全部放在 UserDefaults
enum SettingsStore {
    private static let modeKey = "voiceMode"
    private static let keyCodeKey = "hotkeyKeyCode"
    private static let flagsKey = "hotkeyFlags"
    private static let displayKey = "hotkeyDisplay"

    static func loadMode() -> VoiceMode {
        guard let raw = UserDefaults.standard.string(forKey: modeKey),
              let mode = VoiceMode(rawValue: raw) else {
            return .hold
        }
        return mode
    }

    static func saveMode(_ mode: VoiceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
    }

    static func loadHotkey() -> Hotkey {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeKey) != nil else {
            return .defaultHotkey
        }
        let keyCode = CGKeyCode(defaults.integer(forKey: keyCodeKey))
        let flags = CGEventFlags(rawValue: UInt64(defaults.integer(forKey: flagsKey)))
        let display = defaults.string(forKey: displayKey) ?? "⌃I"
        return Hotkey(keyCode: keyCode, modifiers: flags, display: display)
    }

    static func saveHotkey(_ hotkey: Hotkey) {
        let defaults = UserDefaults.standard
        defaults.set(Int(hotkey.keyCode), forKey: keyCodeKey)
        defaults.set(Int(hotkey.modifiers.rawValue), forKey: flagsKey)
        defaults.set(hotkey.display, forKey: displayKey)
    }
}
