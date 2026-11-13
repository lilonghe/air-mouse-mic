import Combine
import Foundation

/// 界面与遥控器之间的状态中心
final class RemoteController: ObservableObject {
    enum ConnectionState: Equatable {
        case off
        case connecting
        case connected

        var title: String {
            switch self {
            case .off: return "未启用"
            case .connecting: return "连接中…"
            case .connected: return "已连接"
            }
        }
    }

    @Published private(set) var connection: ConnectionState = .off
    @Published private(set) var speaking = false
    @Published private(set) var enabled = false
    @Published var mode: VoiceMode {
        didSet {
            SettingsStore.saveMode(mode)
            log("语音模式切换为：\(mode.title)")
        }
    }
    @Published var hotkey: Hotkey {
        didSet {
            SettingsStore.saveHotkey(hotkey)
            log("快捷键改为：\(hotkey.display)")
        }
    }

    private let client = AtvvClient()
    private let injector = KeyInjector()
    private var latched = false
    private var holdTimer: Timer?

    init() {
        mode = SettingsStore.loadMode()
        hotkey = SettingsStore.loadHotkey()
        client.onStateChange = { [weak self] state in
            self?.connection = state == .stopped ? .off : (state == .connected ? .connected : .connecting)
        }
        client.onPress = { [weak self] in self?.handlePress() }
        client.onRelease = { [weak self] duration in self?.handleRelease(duration: duration) }
    }

    /// 开关：打开才连接并接收遥控器事件
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        if value {
            log("启用遥控器")
            connection = .connecting
            client.start()
        } else {
            log("停用遥控器")
            client.stop()
            releaseAll()
            connection = .off
        }
    }

    /// 程序退出前解绑
    func shutdown() {
        client.stop()
        releaseAll()
        log("已退出")
    }

    /// 设备按下：长按模式立即按住，短按模式切换锁存
    private func handlePress() {
        switch mode {
        case .hold:
            injector.hold(hotkey)
            speaking = injector.isHolding
        case .toggle:
            if latched {
                injector.release()
            } else {
                injector.hold(hotkey)
            }
            latched = injector.isHolding
            speaking = latched
        }
        startHoldWatchdog()
    }

    /// 设备松手：长按模式释放，短按模式保持锁存
    private func handleRelease(duration: TimeInterval) {
        switch mode {
        case .hold:
            speaking = false
            injector.release()
            holdTimer?.invalidate()
            holdTimer = nil
        case .toggle:
            log(String(format: "单击切换（按压 %.0f ms）", duration * 1000))
        }
    }

    /// 兜底：锁存或按键信号丢失时不让快捷键一直按着
    private func startHoldWatchdog() {
        holdTimer?.invalidate()
        guard injector.isHolding else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            guard let self, self.injector.isHolding else { return }
            log("按住超过 60 秒，强制释放快捷键")
            self.releaseAll()
        }
    }

    /// 释放所有按住状态
    private func releaseAll() {
        holdTimer?.invalidate()
        holdTimer = nil
        latched = false
        speaking = false
        injector.release()
    }
}
