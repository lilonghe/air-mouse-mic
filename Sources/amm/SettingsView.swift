import AppKit
import UniformTypeIdentifiers

/// 原生设置菜单：模式与快捷键通过侧边子菜单操作。
final class SettingsView: NSObject, NSMenuDelegate {
    private let controller: RemoteController
    private let modeItem = NSMenuItem(title: "语音模式", action: nil, keyEquivalent: "")
    private let hotkeyItem = NSMenuItem(title: "触发快捷键", action: nil, keyEquivalent: "")
    private let hotkeyMenu = NSMenu(title: "触发快捷键")
    private let recorderField = NSTextField(labelWithString: "")
    private var recording = false

    /// 设置菜单只持有已有控制器，不创建新的设备连接。
    init(controller: RemoteController) {
        self.controller = controller
        super.init()
    }

    /// 构建真实子菜单，材质和侧边展开位置交给 AppKit。
    func addItems(to menu: NSMenu) {
        let modes = NSMenu(title: "语音模式")
        modes.autoenablesItems = false
        for mode in VoiceMode.allCases {
            let option = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = mode.rawValue
            option.toolTip = mode.detail
            modes.addItem(option)
        }
        modeItem.submenu = modes
        menu.addItem(modeItem)

        hotkeyMenu.autoenablesItems = false
        hotkeyMenu.delegate = self
        let recorder = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 46))
        recorderField.frame = NSRect(x: 10, y: 9, width: 200, height: 28)
        recorderField.isBezeled = true
        recorderField.bezelStyle = .roundedBezel
        recorderField.drawsBackground = true
        recorderField.backgroundColor = .controlBackgroundColor
        recorderField.alignment = .center
        recorderField.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        recorderField.toolTip = "按下新的组合键，Esc 取消"
        recorderField.setAccessibilityLabel("录制快捷键")
        container.addSubview(recorderField)
        recorder.view = container
        hotkeyMenu.addItem(recorder)
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)
        menu.addItem(.separator())
        let export = NSMenuItem(title: "导出日志…", action: #selector(exportLog), keyEquivalent: "")
        export.target = self
        menu.addItem(export)
        refresh()
    }

    /// 同步当前值和选中对勾，不增删菜单项。
    func refresh() {
        modeItem.title = "语音模式：\(controller.mode.title)"
        for option in modeItem.submenu?.items ?? [] {
            option.state = option.representedObject as? String == controller.mode.rawValue ? .on : .off
        }
        hotkeyItem.title = "触发快捷键：\(controller.hotkey.display)"
        if !recording { recorderField.stringValue = controller.hotkey.display }
    }

    /// 仅接受来自已知模式菜单的有效选项。
    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = VoiceMode(rawValue: raw) else { return }
        controller.mode = mode
        refresh()
    }

    /// 只有快捷键侧边菜单打开期间才接收录制输入。
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === hotkeyMenu else { return }
        recording = true
        recorderField.stringValue = "按下组合键…"
    }

    /// 鼠标移出或 Esc 关闭子菜单时取消录制。
    func menuDidClose(_ menu: NSMenu) {
        guard menu === hotkeyMenu else { return }
        recording = false
        recorderField.stringValue = controller.hotkey.display
    }

    /// 菜单跟踪期间通过系统委托处理组合键，不依赖普通窗口事件监听。
    func menu(_ menu: NSMenu, hasKeyEquivalentFor event: NSEvent,
              target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
              action: UnsafeMutablePointer<Selector?>) -> Bool {
        guard recording, event.type == .keyDown,
              event.keyCode != 53 else { return false }
        let modifiers = Self.cgFlags(from: event.modifierFlags)
        target.pointee = self
        action.pointee = #selector(consumeRecordedKey(_:))
        guard !modifiers.isEmpty else {
            recorderField.stringValue = "需包含修饰键"
            return true
        }
        controller.hotkey = Hotkey(keyCode: event.keyCode, modifiers: modifiers, display: Self.display(for: event))
        recording = false
        refresh()
        DispatchQueue.main.async { [weak self] in
            self?.hotkeyMenu.cancelTracking()
        }
        return true
    }

    /// 已由菜单委托保存按键，阻止相同事件继续触发菜单动作。
    @objc private func consumeRecordedKey(_ sender: Any?) {}

    /// 菜单动作结束后再打开系统保存面板，避免嵌套菜单跟踪。
    @objc private func exportLog() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "amm-log.txt"
            panel.allowedContentTypes = [.plainText]
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try LogStore.shared.exportText().write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    /// 只保留快捷键支持的四种修饰键。
    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.command) { result.insert(.maskCommand) }
        return result
    }

    /// 按系统顺序生成组合键名称，保留特殊按键符号。
    private static func display(for event: NSEvent) -> String {
        var text = ""
        let flags = event.modifierFlags
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let characters = event.charactersIgnoringModifiers?.uppercased() ?? ""
        text += specialKeys[Int(event.keyCode)] ?? (characters.isEmpty ? "Key\(event.keyCode)" : characters)
        return text
    }

    private static let specialKeys: [Int: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
