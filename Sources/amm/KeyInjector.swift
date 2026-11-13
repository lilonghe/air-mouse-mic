import ApplicationServices
import CoreGraphics
import Foundation

/// 把快捷键注入系统事件流；按住/释放成对出现
final class KeyInjector {
    private struct ModifierStep {
        let mask: CGEventFlags
        let keyCode: CGKeyCode
    }

    /// 顺序按真键盘习惯：Control → Option → Shift → Command
    private let steps: [ModifierStep] = [
        ModifierStep(mask: .maskControl, keyCode: 59),
        ModifierStep(mask: .maskAlternate, keyCode: 58),
        ModifierStep(mask: .maskShift, keyCode: 56),
        ModifierStep(mask: .maskCommand, keyCode: 55),
    ]

    private var held: Hotkey?

    /// 按住快捷键，重复调用只算一次
    func hold(_ hotkey: Hotkey) {
        guard held == nil else { return }
        guard AXIsProcessTrusted() else {
            log("注入失败：air-mouse-mic 没有辅助功能权限，请在系统设置中授权后再次按键，无需重启 App")
            return
        }
        guard CGEventSource(stateID: .hidSystemState) != nil else {
            log("注入失败：无法创建事件源")
            return
        }

        var accumulated: CGEventFlags = []
        for step in steps where hotkey.modifiers.contains(step.mask) {
            accumulated.insert(step.mask)
            postFlagsChanged(keyCode: step.keyCode, flags: flagsFor(accumulated))
        }
        guard postKey(hotkey.keyCode, down: true, flags: flagsFor(hotkey.modifiers)) else { return }
        held = hotkey
        log("快捷键已按住：\(hotkey.display)")
    }

    /// 释放当前按住的快捷键
    func release() {
        guard let hotkey = held else { return }
        _ = postKey(hotkey.keyCode, down: false, flags: flagsFor(hotkey.modifiers))

        var accumulated = hotkey.modifiers
        for step in steps.reversed() where hotkey.modifiers.contains(step.mask) {
            accumulated.remove(step.mask)
            postFlagsChanged(keyCode: step.keyCode, flags: flagsFor(accumulated))
        }
        held = nil
        log("快捷键已释放：\(hotkey.display)")
    }

    var isHolding: Bool { held != nil }

    /// 修饰键事件，真键盘走的是 flagsChanged
    private func postFlagsChanged(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(source: source) else { return }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// 主键事件，成功返回 true
    private func postKey(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else {
            log("注入失败：无法创建按键事件")
            return false
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        return true
    }

    /// 补上真键盘才有的设备位：微信输入法靠它判断修饰键真的按住
    private func flagsFor(_ base: CGEventFlags) -> CGEventFlags {
        var flags = base
        if flags.contains(.maskControl) { flags.insert(CGEventFlags(rawValue: 0x1)) }
        if flags.contains(.maskShift) { flags.insert(CGEventFlags(rawValue: 0x2)) }
        if flags.contains(.maskAlternate) { flags.insert(CGEventFlags(rawValue: 0x20)) }
        if flags.contains(.maskCommand) { flags.insert(CGEventFlags(rawValue: 0x8)) }
        return flags
    }
}
