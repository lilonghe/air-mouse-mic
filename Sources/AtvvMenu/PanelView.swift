import SwiftUI

/// 点击菜单栏图标展开的面板
struct PanelView: View {
    @ObservedObject var controller: RemoteController
    @State private var showSettings = false

    var body: some View {
        Group {
            if showSettings {
                SettingsView(controller: controller, showSettings: $showSettings)
            } else {
                mainPanel
            }
        }
        .frame(width: 300)
        .padding(16)
    }

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.tint)
                Text("T1-Remote")
                    .font(.headline)
                Spacer()
            }

            VStack(spacing: 8) {
                statusRow(title: "ATVV 连接", value: controller.connection.title, color: connectionColor)
                statusRow(title: "语音状态",
                          value: controller.speaking ? "说话中" : "空闲",
                          color: controller.speaking ? .green : .secondary)
                statusRow(title: "当前模式", value: controller.mode.title, color: .secondary)
            }

            Divider()

            Toggle("启用遥控器", isOn: Binding(
                get: { controller.enabled },
                set: { controller.setEnabled($0) }
            ))
            .toggleStyle(.switch)

            Divider()

            HStack {
                Button("退出") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("设置")
            }
        }
    }

    private var connectionColor: Color {
        switch controller.connection {
        case .connected: return .green
        case .connecting: return .orange
        case .off: return .secondary
        }
    }

    private func statusRow(title: String, value: String, color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(value)
            }
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }
}
