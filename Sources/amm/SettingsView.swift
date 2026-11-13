import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置界面：语音模式、快捷键、日志导出
struct SettingsView: View {
    @ObservedObject var controller: RemoteController
    @Binding var showSettings: Bool

    @State private var recording = false
    @State private var keyMonitor: Any?
    @State private var recordingHint: String?
    @State private var exportHint: String?
    @ObservedObject private var logs = LogStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("设置")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("返回") {
                    stopRecording()
                    showSettings = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            }
            .padding(.bottom, 22)

            modeSection
                .padding(.bottom, 20)
            hotkeySection
                .padding(.bottom, 20)
            Color.primary.opacity(0.08)
                .frame(height: 1)
            logSection
                .padding(.top, 12)
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .onDisappear { stopRecording() }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("语音模式")
                .fontWeight(.medium)
            HStack(spacing: 3) {
                ForEach(VoiceMode.allCases) { mode in
                    Button {
                        controller.mode = mode
                    } label: {
                        Text(mode.title)
                            .font(.system(size: 12, weight: controller.mode == mode ? .semibold : .regular))
                            .foregroundStyle(controller.mode == mode ? .primary : .secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 29)
                            .background {
                                if controller.mode == mode {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                        .shadow(color: .primary.opacity(0.08), radius: 2, y: 1)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(controller.mode == mode ? .isSelected : [])
                }
            }
            .padding(3)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("语音模式")
            Text(controller.mode.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("触发快捷键")
                .fontWeight(.medium)
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                HStack {
                    Text(recording ? "等待按键…" : controller.hotkey.display)
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundStyle(recording ? Color.accentColor : Color.primary)
                    Spacer()
                    Text(recording ? "取消" : "点击录制")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(recording ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.10),
                                      lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recording ? "取消录制快捷键" : "录制快捷键，当前为 \(controller.hotkey.display)")
            Text(recordingHint ?? (recording ? "按下组合键，Esc 取消" : "需包含 Control、Option、Shift 或 Command"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Text("运行日志")
                    Text("\(logs.lines.count) 行记录")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                Spacer()
                Button("导出日志…") { exportLog() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            if let exportHint {
                Text(exportHint)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 监听本进程按键，用来录制新的快捷键组合
    private func startRecording() {
        guard !recording else { return }
        recordingHint = nil
        recording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            let modifiers = Self.cgFlags(from: event.modifierFlags)
            guard !modifiers.isEmpty else {
                recordingHint = "请同时按住至少一个修饰键"
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

    /// 移除按键监听，同时清除录制提示。
    private func stopRecording() {
        recordingHint = nil
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
        recording = false
    }

    /// 保存当前日志到用户选择的位置
    private func exportLog() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "amm-log.txt"
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
