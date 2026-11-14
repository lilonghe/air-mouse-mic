import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// 菜单栏图标与系统下拉菜单。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = RemoteController()
    private var statusItem: NSStatusItem?
    private lazy var settings = SettingsView(controller: controller)
    private let voiceItem = NSMenuItem(title: "语音状态：空闲", action: nil, keyEquivalent: "")
    private var cancellables = Set<AnyCancellable>()
    private var connectionAnimation: Timer?
    private var connectionFrame = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("air-mouse-mic (amm) 启动")
        requestAccessibilityIfNeeded()
        setupStatusItem()
        bindIconUpdates()
        updateIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        connectionAnimation?.invalidate()
        controller.shutdown()
    }

    /// 没有辅助功能权限时，注入的按键会被系统丢弃
    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        log("等待辅助功能授权：系统设置 → 隐私与安全性 → 辅助功能")
    }

    /// 使用系统菜单负责背景、圆角、选中反馈与侧边子菜单。
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.minimumWidth = 284
        let header = NSMenuItem()
        let headerView = NSHostingView(rootView: PanelView(controller: controller))
        headerView.frame = NSRect(x: 0, y: 0, width: 284, height: 34)
        header.view = headerView
        menu.addItem(header)
        menu.addItem(.separator())
        voiceItem.isEnabled = false
        menu.addItem(voiceItem)
        settings.addItems(to: menu)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    /// 每次打开时读取最新状态，不重建正在跟踪的菜单。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        settings.refresh()
        voiceItem.title = "语音状态：\(controller.speaking ? "说话中" : "空闲")"
    }

    /// AppKit 从主菜单查询组合键时，交由当前打开的快捷键子菜单处理。
    func menu(_ menu: NSMenu, hasKeyEquivalentFor event: NSEvent,
              target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
              action: UnsafeMutablePointer<Selector?>) -> Bool {
        settings.menu(menu, hasKeyEquivalentFor: event, target: target, action: action)
    }

    /// 连接、说话、开关状态变化时刷新图标
    private func bindIconUpdates() {
        let changes = Publishers.Merge3(
            controller.$connection.map { _ in () },
            controller.$speaking.map { _ in () },
            controller.$enabled.map { _ in () }
        )
        changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateIcon() }
            .store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
    }

    /// 连接中播放居中三点动效，其余状态继续使用静态系统图标。
    private func updateIcon() {
        voiceItem.title = "语音状态：\(controller.speaking ? "说话中" : "空闲")"
        let connecting = controller.enabled && controller.connection == .connecting && !controller.speaking
        updateConnectionAnimation(connecting: connecting)
        let symbol: String
        if !controller.enabled {
            symbol = "mic.slash"
        } else if controller.speaking {
            symbol = "waveform"
        } else {
            symbol = "mic"
        }
        let image = connecting ? connectingImage()
            : NSImage(systemSymbolName: symbol, accessibilityDescription: "T1-Remote")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = "T1-Remote · \(controller.connection.title)"
    }

    /// 仅连接期间运行低频计时器，尊重系统的减少动态效果设置。
    private func updateConnectionAnimation(connecting: Bool) {
        guard connecting, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            connectionAnimation?.invalidate()
            connectionAnimation = nil
            connectionFrame = 0
            return
        }
        guard connectionAnimation == nil else { return }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.connectionFrame = (self.connectionFrame + 1) % 18
            self.updateIcon()
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        connectionAnimation = timer
    }

    /// 横排三点在图标中央依次明暗变化，保持位置和大小稳定。
    private func connectingImage() -> NSImage {
        let frame = connectionFrame
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            for dot in 0..<3 {
                let phase = CGFloat(frame - dot * 6) * 2 * .pi / 18
                let opacity: CGFloat = reducedMotion ? 0.65 : 0.25 + 0.75 * (cos(phase) + 1) / 2
                NSColor.black.withAlphaComponent(opacity).setFill()
                NSBezierPath(ovalIn: NSRect(x: 2.5 + CGFloat(dot) * 5,
                                           y: 7.5, width: 3, height: 3)).fill()
            }
            return true
        }
        image.accessibilityDescription = "T1-Remote，连接中"
        return image
    }
}
