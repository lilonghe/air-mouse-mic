import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// 菜单栏图标与弹出面板
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = RemoteController()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    private var connectionAnimation: Timer?
    private var connectionFrame = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("AtvvMenu 启动")
        requestAccessibilityIfNeeded()
        setupPopover()
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

    private func setupPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PanelView(controller: controller))
        self.popover = popover
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
