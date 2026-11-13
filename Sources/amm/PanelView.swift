import SwiftUI

/// 点击菜单栏图标展开的面板
struct PanelView: View {
    @ObservedObject var controller: RemoteController
    @Environment(\.colorScheme) private var colorScheme
    @State private var showSettings = false

    var body: some View {
        Group {
            if showSettings {
                SettingsView(controller: controller, showSettings: $showSettings)
            } else {
                mainPanel
            }
        }
        .frame(width: 280)
        .padding(16)
        .foregroundStyle(primaryText)
        .background {
            PanelMaterial()
                .overlay {
                    LinearGradient(
                        colors: [Color.blue.opacity(colorScheme == .dark ? 0.07 : 0.09),
                                 Color.indigo.opacity(0.025)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    .allowsHitTesting(false)
                }
        }
    }

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("T1-Remote")
                    .font(.system(size: 18, weight: .semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 7, height: 7)
                    Text(controller.connection.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(secondaryText)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                statusItem(title: "ATVV 连接",
                           value: controller.connection.title)
                separator.frame(width: 1, height: 32)
                statusItem(title: "语音状态",
                           value: controller.speaking ? "说话中" : "空闲")
                separator.frame(width: 1, height: 32)
                statusItem(title: "当前模式",
                           value: controller.mode.title)
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            VStack(spacing: 0) {
                separator.frame(height: 1)
                HStack {
                    Text("启用遥控器")
                        .font(.system(size: 14))
                        .foregroundStyle(secondaryText)
                    Spacer()
                    Toggle("启用遥控器", isOn: Binding(
                        get: { controller.enabled },
                        set: { controller.setEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(.blue)
                }
                .padding(.vertical, 10)
                separator.frame(height: 1)
                HStack {
                    Button("退出") { NSApp.terminate(nil) }
                        .buttonStyle(.plain)
                        .help("退出 air-mouse-mic")
                    Spacer()
                    Button("设置") { showSettings = true }
                        .buttonStyle(.plain)
                }
                .font(.system(size: 14))
                .foregroundStyle(secondaryText)
                .padding(.top, 10)
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

    private var primaryText: Color {
        colorScheme == .dark ? Color(red: 0.90, green: 0.92, blue: 0.98)
            : Color(red: 0.15, green: 0.17, blue: 0.25)
    }

    private var secondaryText: Color {
        colorScheme == .dark ? Color(red: 0.62, green: 0.66, blue: 0.75)
            : Color(red: 0.47, green: 0.50, blue: 0.60)
    }

    private var separator: some View {
        Color.primary.opacity(0.08)
    }

    /// 三栏状态使用统一的两行文字排版。
    private func statusItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// 使用活跃的系统弹出层材质，让桌面背景透入面板。
private struct PanelMaterial: NSViewRepresentable {
    /// 创建由系统负责模糊与明暗适配的背景视图。
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    /// 背景材质不依赖业务状态，无需增量更新。
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
