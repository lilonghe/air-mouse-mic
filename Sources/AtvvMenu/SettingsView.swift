import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置界面：语音模式、快捷键、日志导出
struct SettingsView: View {
    @ObservedObject var controller: RemoteController
    @Binding var showSettings: Bool

    @State private var recording = false
    @State private var keyMonitor: Any?
    @State private var exportHint: String?
    @ObservedObject private var logs = LogStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button {
                    stopRecording()
                    showSettings = false
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                Text("设置").font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("语音模式").font(.system(size: 12))
                Picker("", selection: $controller.mode) {
                    ForEach(VoiceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(controller.mode.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("触发快捷键").font(.system(size: 12))
                    Spacer()
                    Text(controller.hotkey.display)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                Button(recording ? "请按下组合键（Esc 取消）" : "录制快捷键") {
                    recording ? stopRecording() : startRecording()
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Button("导出日志…") { exportLog() }
                Text(exportHint ?? "共 \(logs.lines.count) 行")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stopRecording() }
    }

    /// 监听本进程按键，用来录制新的快捷键组合
    private func startRecording() {
        guard !recording else { return }
        recording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            let modifiers = Self.cgFlags(from: event.modifierFlags)
            guard !modifiers.isEmpty else {
                exportHint = "需要带修饰键（⌃⌥⇧⌘）"
                return nil
            }
            controller.hotkey = Hotkey(
                keyCode: event.keyCode,
                modifiers: modifiers,
                display: Self.display(for: event)
            )
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
        recording = false
    }

    /// 保存当前日志到用户选择的位置
    private func exportLog() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "atvv-log.txt"
        panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try LogStore.shared.exportText().write(to: url, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { exportHint = "已导出到 \(url.lastPathComponent)" }
            } catch {
                DispatchQueue.main.async { exportHint = "导出失败：\(error.localizedDescription)" }
            }
        }
    }

    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.command) { result.insert(.maskCommand) }
        return result
    }

    private static func display(for event: NSEvent) -> String {
        var text = ""
        let flags = event.modifierFlags
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        text += keyName(for: event)
        return text
    }

    private static func keyName(for event: NSEvent) -> String {
        if let special = specialKeys[Int(event.keyCode)] { return special }
        let characters = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return characters.isEmpty ? "Key\(event.keyCode)" : characters
    }

    private static let specialKeys: [Int: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
