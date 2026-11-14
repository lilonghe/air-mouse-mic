import SwiftUI

/// 系统菜单中的设备标题，仅绘制内容，不覆盖系统菜单材质。
struct PanelView: View {
    @ObservedObject var controller: RemoteController

    var body: some View {
        HStack(spacing: 6) {
            Text("T1-Remote")
                .font(.system(size: 13, weight: .medium))
            Circle().fill(connectionColor).frame(width: 5, height: 5)
            Text(controller.connection.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("启用遥控器", isOn: Binding(
                get: { controller.enabled },
                set: { controller.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)
            .help(controller.enabled ? "停用遥控器" : "启用遥控器")
        }
        .padding(.horizontal, 16)
        .frame(width: 284, height: 34)
    }

    private var connectionColor: Color {
        switch controller.connection {
        case .connected: return .green
        case .connecting: return .orange
        case .off: return .secondary
        }
    }
}
