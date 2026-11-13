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

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("AtvvMenu 启动")
        requestAccessibilityIfNeeded()
        setupPopover()
        setupStatusItem()
        bindIconUpdates()
        updateIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
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
    }

    private func updateIcon() {
        let symbol: String
        if !controller.enabled {
            symbol = "mic.slash"
        } else if controller.speaking {
            symbol = "waveform"
        } else {
            symbol = "mic"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "T1-Remote")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = "T1-Remote · \(controller.connection.title)"
    }
}
