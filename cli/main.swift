import Foundation
import CoreBluetooth
import IOKit.hid
import Cocoa
import Darwin

// MARK: - 常量

let SVC   = CBUUID(string: "ab5e0001-5a21-4f05-bc7d-af01f617b664")
let C_CMD = CBUUID(string: "ab5e0002-5a21-4f05-bc7d-af01f617b664")
let C_AUD = CBUUID(string: "ab5e0003-5a21-4f05-bc7d-af01f617b664")
let C_CTL = CBUUID(string: "ab5e0004-5a21-4f05-bc7d-af01f617b664")

let REMOTE_VID = 0x620A
let REMOTE_PID = 0x0407
let VOICE_HID_KEY: UInt8 = 0xAA      // 语音键在 HID 键盘报文里的键值
let SEARCH_KEYCODE: Int64 = 177      // AC Search 在 macOS 侧映射成的虚拟键码

let SAMPLE_RATE = 16000
let MAX_RECORD_SECONDS = 300.0        // 仅防跑飞；正常会话由 ATVV 事件收尾
let LOCK_LATCH = false                // 锁存模式：首次按键开麦，再次按键关麦
let PRE_ROLL_SECONDS = 0.3            // 落盘时保留的按键前导
let OPEN_WAIT_SECONDS = 2.0           // MIC_OPEN 后等 AUDIO_START 的上限
let CLOSE_WAIT_SECONDS = 0.6          // MIC_CLOSE 后等 AUDIO_STOP 的上限
let EXTEND_INTERVAL_SECONDS = 5.0     // 推流期间续期间隔
let MAX_HOLD_SECONDS = 60.0           // 兜底：组合键最多按住多久
let HOTKEY_KEYCODE: CGKeyCode = 34    // 可配置：I 键
let CTRL_DEVICE_BIT: CGEventFlags = CGEventFlags(rawValue: 0x1)   // NX_DEVICELCTLKEYMASK，真键盘必有，输入法按它判断 Ctrl 真的按住
let HOTKEY_MODIFIERS: CGEventFlags = [.maskControl, CTRL_DEVICE_BIT]
let HOTKEY_MODIFIER_KEYCODE: CGKeyCode = 59
let AUDIO_MODE = CommandLine.arguments.contains("--audio")   // 加 --audio 才订阅 ATVV 抓遥控器音频
let HID_MODE = CommandLine.arguments.contains("--hid")       // 加 --hid 强制走纯 HID 模式（不用 ATVV）
let SELFTEST = CommandLine.arguments.contains("--selftest")  // 自检：启动后自己发一次 Ctrl+I

let STEP: [Int] = [7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767]
let INDEX_TABLE = [-1,-1,-1,-1,2,4,6,8]

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    print("[\(f.string(from: Date()))] \(s)"); fflush(stdout)
}

// MARK: - 进程生命周期

var instanceLockFD: Int32 = -1
var signalSources: [DispatchSourceSignal] = []

/// 用文件锁保证同一时间只有一个实例；进程退出（含 Ctrl+C）时内核自动释放
func acquireInstanceLock() -> Bool {
    let path = "/tmp/amm.lock"
    let fd = open(path, O_CREAT | O_EXLOCK | O_NONBLOCK, 0o600)
    guard fd >= 0 else { return false }
    instanceLockFD = fd
    return true
}

// MARK: - ADPCM

/// 解码一个 IMA ADPCM nibble
func decodeNibble(_ n: Int, _ predictor: inout Int, _ stepIndex: inout Int) -> Int {
    let step = STEP[stepIndex]
    var diff = step >> 3
    if n & 1 != 0 { diff += step >> 2 }
    if n & 2 != 0 { diff += step >> 1 }
    if n & 4 != 0 { diff += step }
    if n & 8 != 0 { predictor -= diff } else { predictor += diff }
    predictor = min(32767, max(-32768, predictor))
    stepIndex = min(88, max(0, stepIndex + INDEX_TABLE[n & 7]))
    return predictor
}

/// 写 16bit 单声道 PCM 的 WAV
func writeWav(_ path: String, _ samples: [Int16]) {
    var data = Data()
    let dataSize = UInt32(samples.count * 2)
    func append(_ s: String) { data.append(s.data(using: .ascii)!) }
    func append32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
    func append16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
    append("RIFF"); append32(36 + dataSize); append("WAVE")
    append("fmt "); append32(16); append16(1); append16(1)
    append32(UInt32(SAMPLE_RATE)); append32(UInt32(SAMPLE_RATE * 2)); append16(2); append16(16)
    append("data"); append32(dataSize)
    for s in samples { append16(UInt16(bitPattern: s)) }
    try? data.write(to: URL(fileURLWithPath: path))
}

// MARK: - Spotlight 拦截

/// 吞掉 AC Search 映射出的 keycode，避免唤起 Spotlight
final class SpotlightBlocker {
    private var tap: CFMachPort?

    func start() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                return Unmanaged.passUnretained(event)
            }
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode == HOTKEY_KEYCODE || keycode == HOTKEY_MODIFIER_KEYCODE ||
               type == .flagsChanged {
                let kind = type == .keyDown ? "DOWN" : (type == .keyUp ? "UP  " : "FLAGS")
                let flags = event.flags.rawValue
                let srcpid = event.getIntegerValueField(.eventSourceUnixProcessID)
                log("KEYDBG [\(kind)] key=\(keycode) flags=0x\(String(flags, radix: 16)) srcpid=\(srcpid)")
            }
            if keycode == SEARCH_KEYCODE {
                log("已拦截 AC Search (keycode \(keycode))")
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                              place: .headInsertEventTap,
                                              options: .defaultTap,
                                              eventsOfInterest: mask,
                                              callback: callback,
                                              userInfo: nil) else {
            return false
        }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }

    /// 退出时停用事件拦截，避免程序结束后还在吞 AC Search
    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        self.tap = nil
        log("Spotlight 拦截已关闭")
    }
}

// MARK: - HID 监听

var activeHidWatcher: HidReleaseWatcher?

// MARK: - 按键注入

/// 把事件投进全局 HID 事件流
func postEvent(_ event: CGEvent?) {
    guard let event else { return }
    event.post(tap: .cghidEventTap)
}

/// 会话期间按住组合键（如 Ctrl+I），结束时松开
final class HotkeyHolder {
    private(set) var held = false

    /// 切换保持状态，失败时保持原状态
    func setHeld(_ hold: Bool) {
        guard hold != held else { return }
        if hold {
            guard postModifier(down: true), postKey(down: true, flags: HOTKEY_MODIFIERS) else { return }
            held = true
            log("组合键已按住")
        } else {
            guard postKey(down: false, flags: HOTKEY_MODIFIERS), postModifier(down: false) else { return }
            held = false
            log("组合键已松开")
        }
    }

    /// 真键盘按 Ctrl 走的是 flagsChanged 事件，不是 keyDown/keyUp
    private func postModifier(down: Bool) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            log("组合键发送失败：创建事件源失败")
            return false
        }
        let event = CGEvent(source: source)
        event?.type = .flagsChanged
        event?.setIntegerValueField(.keyboardEventKeycode, value: Int64(HOTKEY_MODIFIER_KEYCODE))
        var flags: CGEventFlags = []
        if down { flags = HOTKEY_MODIFIERS }
        event?.flags = flags
        guard event != nil else {
            log("组合键发送失败：创建修饰键事件失败")
            return false
        }
        postEvent(event)
        return true
    }

    /// 发送组合键的按下/抬起，返回是否成功
    private func postKey(down: Bool, flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            log("组合键发送失败：创建事件源失败")
            return false
        }
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: HOTKEY_KEYCODE,
            keyDown: down
        ) else {
            log("组合键发送失败：创建按键事件失败")
            return false
        }
        event.flags = flags
        postEvent(event)
        return true
    }
}

/// IOHIDManager 的设备接入/移除回调，用来观察 HID 链路是否被系统重连
private func hidDeviceCallback(context: UnsafeMutableRawPointer?,
                               result: IOReturn,
                               sender: UnsafeMutableRawPointer?,
                               device: IOHIDDevice) {
    guard let watcher = activeHidWatcher else { return }
    watcher.handleDevice(added: result == kIOReturnSuccess, device: device)
}

/// 只认 T1-Remote，别的键盘报文一律丢弃
func isRemoteDevice(_ device: IOHIDDevice) -> Bool {
    let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
    let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
    return vid == REMOTE_VID && pid == REMOTE_PID
}

/// IOHIDDevice 的元素值回调，转交给 watcher 处理
private func hidValueCallback(context: UnsafeMutableRawPointer?,
                              result: IOReturn,
                              sender: UnsafeMutableRawPointer?,
                              value: IOHIDValue) {
    guard let watcher = activeHidWatcher else { return }
    let element = IOHIDValueGetElement(value)
    guard isRemoteDevice(IOHIDElementGetDevice(element)) else { return }
    watcher.handle(
        page: Int(IOHIDElementGetUsagePage(element)),
        usage: Int(IOHIDElementGetUsage(element)),
        value: Int(IOHIDValueGetIntegerValue(value))
    )
}

/// IOHIDDevice 的原始报文回调，补元素回调漏掉的按键
private func hidReportCallback(context: UnsafeMutableRawPointer?,
                               result: IOReturn,
                               sender: UnsafeMutableRawPointer?,
                               type: IOHIDReportType,
                               reportID: UInt32,
                               report: UnsafeMutablePointer<UInt8>,
                               reportLength: CFIndex) {
    guard type == kIOHIDReportTypeInput,
          let sender,
          let watcher = activeHidWatcher else { return }
    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    guard isRemoteDevice(device) else { return }
    watcher.handleReport(reportID: reportID, report: report, length: reportLength)
}

/// 监听遥控器键盘接口，语音键按下/抬起时回调
final class HidReleaseWatcher {
    private var manager: IOHIDManager?
    private var wasDown = false
    private(set) var reportCount = 0
    private(set) var valueCount = 0
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    /// 用 IOHIDManager 统一持有设备；管理器一旦释放，设备句柄就收不到报文
    func start() -> Bool {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: NSNumber(value: REMOTE_VID),
            kIOHIDProductIDKey as String: NSNumber(value: REMOTE_PID),
            kIOHIDPrimaryUsagePageKey as String: NSNumber(value: 0x01),
            kIOHIDPrimaryUsageKey as String: NSNumber(value: 0x06),
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, hidDeviceCallback, nil)
        IOHIDManagerRegisterInputValueCallback(mgr, hidValueCallback, nil)

        IOHIDManagerRegisterInputReportCallback(mgr, hidReportCallback, nil)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            log("HID 键盘接口打开失败（检查输入监控权限）")
            return false
        }
        manager = mgr
        log("HID 键盘接口已监听（等设备匹配）")
        return true
    }

    /// 退出时关闭键盘接口，避免进程结束后还占着 HID
    func stop() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
        wasDown = false
        log("HID 键盘接口已关闭")
    }

    /// 设备接入/移除：用来判断链路是不是被系统热插拔了
    func handleDevice(added: Bool, device: IOHIDDevice) {
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
        log(added ? "HID 设备接入: \(name)" : "HID 设备移除: \(name)")
    }

    /// 元素值回调：只关心键盘页的语音键
    func handle(page: Int, usage: Int, value: Int) {
        valueCount += 1
        guard page == 0x07, usage == Int(VOICE_HID_KEY) else { return }
        transition(down: value != 0, source: "value")
    }

    /// 报文回调：直接看键盘报文里有没有 0xAA
    func handleReport(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length > 0 else { return }
        reportCount += 1
        let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
        log("HID r\(reportID): \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        guard reportID == 1, length > 2 else { return }
        transition(down: bytes.dropFirst().contains(VOICE_HID_KEY), source: "report")
    }

    /// 两种回调共用同一个按下状态，重复到达只算一次
    private func transition(down: Bool, source: String) {
        if down && !wasDown {
            wasDown = true
            log("HID 语音键按下 (\(source))")
            onPress?()
        } else if !down && wasDown {
            wasDown = false
            log("HID 语音键抬起 (\(source))")
            onRelease?()
        }
    }
}

// MARK: - ATVV 采集

final class AtvvCapture: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum SessionState {
        case idle
        case opening
        case streaming
        case closing
    }

    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var cmd: CBCharacteristic?
    var aud: CBCharacteristic?
    var ctl: CBCharacteristic?

    var frameSize = 128
    var pending: [UInt8] = []
    var pcm: [Int16] = []
    var predictor = 0
    var stepIndex = 0
    var syncPending = false
    var syncPredictor = 0
    var syncStepIndex = 0

    var state: SessionState = .idle
    var recordStart = Date()
    var frames = 0
    var sessionId: UInt8 = 0
    var pressSampleIndex: Int?
    var openTimer: Timer?
    var extendTimer: Timer?
    var closeTimer: Timer?
    var timeoutWatchdog: Timer?
    var closeReason = ""
    var capsRequested = false
    var hotkey = HotkeyHolder()
    var atvvHold = false
    var holdTimer: Timer?

    /// 纯热键模式不需要 ATVV 连接；多一条 BLE 链路只会和系统 HID 抢调度
    func start() {
        guard !HID_MODE else {
            log("纯 HID 模式：不建立 ATVV 连接")
            return
        }
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// 退出时停掉所有定时器、松开组合键并断开 ATVV 连接
    func shutdown() {
        openTimer?.invalidate(); openTimer = nil
        extendTimer?.invalidate(); extendTimer = nil
        closeTimer?.invalidate(); closeTimer = nil
        timeoutWatchdog?.invalidate(); timeoutWatchdog = nil
        if state == .opening || state == .streaming {
            log("退出前补发 MIC_CLOSE，避免设备留在推流状态")
            send([0x0D, 0x00])
            state = .closing
        }
        hotkey.setHeld(false)
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("bluetooth state = \(c.state.rawValue)")
        guard c.state == .poweredOn else { return }
        tryConnect()
    }

    /// 找到已配对的遥控器并连接；没找到就过几秒再试，等设备被按键唤醒
    func tryConnect() {
        guard let p = central.retrieveConnectedPeripherals(withServices: [SVC]).first else {
            log("ATVV 设备当前不在已连接列表，3 秒后重试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.tryConnect() }
            return
        }
        log("找到设备: \(p.name ?? "?")")
        peripheral = p; p.delegate = self
        central.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("已连接，发现服务")
        p.discoverServices([SVC])
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("连接断开: \(error?.localizedDescription ?? "无错误")")
        state = .idle
        openTimer?.invalidate(); openTimer = nil
        extendTimer?.invalidate(); extendTimer = nil
        closeTimer?.invalidate(); closeTimer = nil
        timeoutWatchdog?.invalidate(); timeoutWatchdog = nil
        audioPendingReset()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.tryConnect() }
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("连接失败: \(error?.localizedDescription ?? "?")"); exit(2)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == SVC }) else {
            log("ATVV 服务不存在"); exit(2)
        }
        p.discoverCharacteristics([C_CMD, C_AUD, C_CTL], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == C_CMD { cmd = ch }
            if ch.uuid == C_AUD { aud = ch }
            if ch.uuid == C_CTL { ctl = ch }
        }
        guard let a = aud, let c = ctl else { log("缺少 AUD/CTL 特征"); exit(2) }
        guard AUDIO_MODE else {
            log("热键模式：只订阅 CTL，按键由 ATVV 事件驱动")
            p.setNotifyValue(true, for: c)
            return
        }
        p.setNotifyValue(true, for: a)
        p.setNotifyValue(true, for: c)
        if let cmd { p.setNotifyValue(true, for: cmd) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        let ready = AUDIO_MODE ? (aud?.isNotifying == true && ctl?.isNotifying == true) : (ctl?.isNotifying == true)
        guard ready else { return }
        guard !capsRequested else { return }
        capsRequested = true
        log("订阅完成：GET_CAPS，空闲不发包（\(LOCK_LATCH ? "锁存" : "按住")模式）")
        send([0x0A, 0x01, 0x00, 0x00, 0x03, 0x03])
    }

    /// 往 CMD 特征写数据（设备只支持 writeWithoutResponse）
    func send(_ bytes: [UInt8]) {
        guard let p = peripheral, let c = cmd else { return }
        log("TX \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        p.writeValue(Data(bytes), for: c, type: .withoutResponse)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value, !data.isEmpty else { return }
        if ch.uuid == C_CTL {
            handleControl(Array(data))
        } else if ch.uuid == C_CMD {
            log("CMD 通知: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
        } else {
            handleAudio(Array(data))
        }
    }

    /// 处理 CTL：START_SEARCH / AUDIO_START / AUDIO_STOP / MIC_OPEN_ERROR
    func handleControl(_ b: [UInt8]) {
        guard let op = b.first else { return }
        log("CTL op=0x\(String(format: "%02X", op)) len=\(b.count) data=\(b.map { String(format: "%02X", $0) }.joined(separator: " "))")

        switch op {
        case 0x08:
            handleSearch()

        case 0x04:
            if !AUDIO_MODE {
                noteAtvvPress()
                send([0x0D, 0x00])
                return
            }
            guard b.count >= 4 else {
                log("!! AUDIO_START 长度不足，忽略")
                return
            }
            handleAudioStart(reason: b[1], codec: b[2], streamId: b[3])

        case 0x00:
            let reason = b.count >= 2 ? b[1] : 0xFF
            log("AUDIO_STOP reason=0x\(String(format: "%02X", reason))")
            if !AUDIO_MODE {
                // 0x02 = HTT release（松手）；0x08 = 超时兜底；0x00 是我们关麦的回应，忽略
                if reason == 0x02 || reason == 0x08 {
                    noteAtvvRelease(reason: reason)
                } else {
                    log("忽略 AUDIO_STOP 0x00（我方 MIC_CLOSE 的回应）")
                }
                return
            }
            finishSession(reason: String(format: "stop_0x%02X", reason))

        case 0x0C:
            // T1 的错误码按小端写线上，0C 01 0F 实际是 0x0F01
            let code = b.count >= 3 ? (UInt16(b[1]) | (UInt16(b[2]) << 8)) : 0xFFFF
            log("!! MIC_OPEN_ERROR 0x\(String(format: "%04X", code))")
            handleOpenError()

        case 0x0B where b.count >= 7:
            let fs = (Int(b[5]) << 8) | Int(b[6])
            if fs > 0 { frameSize = fs }
            log("CAPS frame=\(frameSize)")

        case 0x0A where b.count >= 7:
            let pred = Int16(bitPattern: (UInt16(b[4]) << 8) | UInt16(b[5]))
            syncPredictor = Int(pred); syncStepIndex = Int(b[6]); syncPending = true

        default:
            break
        }
    }

    /// 断连后清掉半截数据，避免下次解码错位
    func audioPendingReset() {
        pending.removeAll()
        pcm.removeAll()
        frames = 0
    }

    /// START_SEARCH：空闲时立即开麦；推流中在锁存模式下作为第二次点击收尾
    func handleSearch() {
        if !AUDIO_MODE {
            log("START_SEARCH，热键模式下直接回 MIC_CLOSE")
            send([0x0D, 0x00])
            return
        }
        switch state {
        case .idle:
            log("START_SEARCH → MIC_OPEN")
            send([0x0C, 0x00])
            state = .opening
            startOpenTimer()

        case .opening, .streaming:
            if LOCK_LATCH {
                log("START_SEARCH（已建锁）→ MIC_CLOSE")
                closeSession(reason: "second_click")
            } else {
                log("START_SEARCH（会话进行中，忽略）")
            }

        case .closing:
            log("START_SEARCH（正在关闭，忽略）")
        }
    }

    /// 开麦后等 AUDIO_START；超时只放弃本次，不重复开麦
    func startOpenTimer() {
        openTimer?.invalidate()
        openTimer = Timer.scheduledTimer(withTimeInterval: OPEN_WAIT_SECONDS, repeats: false) { [weak self] _ in
            guard let self, self.state == .opening else { return }
            self.state = .idle
            self.openTimer = nil
            log("!! \(OPEN_WAIT_SECONDS) 秒内没有 AUDIO_START")
        }
    }

    /// AUDIO_START：开始录音；没有 HID 按下时只等设备 15 秒超时
    func handleAudioStart(reason: UInt8, codec: UInt8, streamId: UInt8) {
        if state == .closing {
            log("AUDIO_START 在关闭中到达，补发 MIC_CLOSE")
            send([0x0D, 0x00])
            startCloseTimer(reason: closeReason)
            return
        }
        guard state != .streaming else {
            log("AUDIO_START 已在推流中，忽略")
            return
        }
        openTimer?.invalidate(); openTimer = nil
        sessionId = streamId
        recordStart = Date()
        predictor = 0; stepIndex = 0; syncPending = false
        pending.removeAll(); pcm.removeAll(); frames = 0
        state = .streaming
        let hidSeen = activeHidWatcher?.reportCount ?? 0
        log("AUDIO_START reason=0x\(String(format: "%02X", reason)) codec=\(codec) session=\(streamId)，开始录音（此前 HID 报文累计 \(hidSeen)）")
        if codec != 0x02 {
            log("!! 非预期 codec=\(codec)")
        }
        hotkey.setHeld(true)
        if pressSampleIndex != nil {
            startExtendTimer()
        } else {
            // 没有真实的 HID 按下就无法知道松手时间，不续期，让设备 15 秒超时收尾
            log("无 HID 按下信号，等设备 15 秒超时收尾")
            startTimeoutWatchdog()
        }
    }

    /// 没有 HID 按下时设备不会上报松手，用略长于传输超时的看门狗兜底
    func startTimeoutWatchdog() {
        timeoutWatchdog?.invalidate()
        timeoutWatchdog = Timer.scheduledTimer(withTimeInterval: 16, repeats: false) { [weak self] _ in
            guard let self, self.state == .streaming else { return }
            log("16 秒仍无 AUDIO_STOP，主动收尾")
            self.closeSession(reason: "watchdog")
        }
    }

    /// 推流期间每 5 秒续期，重置设备的 15 秒传输超时
    func startExtendTimer() {
        extendTimer?.invalidate()
        extendTimer = Timer.scheduledTimer(withTimeInterval: EXTEND_INTERVAL_SECONDS, repeats: true) { [weak self] _ in
            guard let self, self.state == .streaming else { return }
            self.send([0x0E, self.sessionId])
            self.logExtend()
        }
    }

    func logExtend() {
        log("MIC_EXTEND 0x0E 已发送（session=\(sessionId)）")
    }

    /// 主动收尾：发 MIC_CLOSE，等设备回 AUDIO_STOP 或超时后落盘
    func closeSession(reason: String) {
        guard state == .opening || state == .streaming else { return }
        state = .closing
        closeReason = reason
        openTimer?.invalidate(); openTimer = nil
        extendTimer?.invalidate(); extendTimer = nil
        timeoutWatchdog?.invalidate(); timeoutWatchdog = nil
        hotkey.setHeld(false)
        send([0x0D, 0x00])
        log("MIC_CLOSE 已发送（\(reason)），等 AUDIO_STOP")
        startCloseTimer(reason: reason)
    }

    /// 关闭阶段的兜底计时，避免设备不回 AUDIO_STOP 时一直挂住
    func startCloseTimer(reason: String) {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: CLOSE_WAIT_SECONDS, repeats: false) { [weak self] _ in
            guard let self, self.state == .closing else { return }
            log("等 AUDIO_STOP 超时，直接收尾")
            self.finishSession(reason: reason)
        }
    }

    /// 结束会话：停所有定时器、松开组合键、落盘并回到空闲
    func finishSession(reason: String) {
        guard state != .idle else { return }
        state = .idle
        openTimer?.invalidate(); openTimer = nil
        extendTimer?.invalidate(); extendTimer = nil
        closeTimer?.invalidate(); closeTimer = nil
        timeoutWatchdog?.invalidate(); timeoutWatchdog = nil
        hotkey.setHeld(false)
        flushSegment(reason: reason)
    }

    /// 开麦失败：回到空闲，等下一次按键重试
    func handleOpenError() {
        guard state == .opening else { return }
        state = .idle
        openTimer?.invalidate(); openTimer = nil
    }

    /// HID 语音键按下：记录真实按下位置，落盘时保留一小段前导
    func noteHIDPress() {
        if HID_MODE { hotkey.setHeld(true); return }
        guard AUDIO_MODE else { return }
        guard state == .opening || state == .streaming, pressSampleIndex == nil else { return }
        pressSampleIndex = pcm.count
        if state == .streaming {
            timeoutWatchdog?.invalidate(); timeoutWatchdog = nil
            startExtendTimer()
        }
        log("HID 按下定界")
    }

    /// 设备起会话（AUDIO_START）就是按下：按住组合键等松手信号
    func noteAtvvPress() {
        guard !atvvHold else {
            log("已在按住中，重复的 AUDIO_START 忽略")
            return
        }
        atvvHold = true
        log("按键按下（ATVV）")
        hotkey.setHeld(true)
        // 兜底：万一设备的松手信号丢了，别让组合键一直按住
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: MAX_HOLD_SECONDS, repeats: false) { [weak self] _ in
            guard let self, self.atvvHold else { return }
            log("按住超过 \(Int(MAX_HOLD_SECONDS)) 秒，强制释放组合键")
            self.noteAtvvRelease(reason: 0xFF)
        }
    }

    /// 设备发 AUDIO_STOP：0x02 是松手，0x08 是超时兜底，都要放开组合键
    func noteAtvvRelease(reason: UInt8) {
        guard atvvHold else {
            log("未在按住中，忽略 AUDIO_STOP 0x\(String(format: "%02X", reason))")
            return
        }
        atvvHold = false
        holdTimer?.invalidate(); holdTimer = nil
        log(reason == 0x02 ? "按键抬起（ATVV HTT release）" : "按键抬起（ATVV 超时兜底 0x\(String(format: "%02X", reason))）")
        hotkey.setHeld(false)
    }

    /// HID 语音键抬起：按住模式收尾；锁存模式忽略
    func noteHIDRelease() {
        if HID_MODE { hotkey.setHeld(false); return }
        guard AUDIO_MODE else { return }
        guard !LOCK_LATCH else { return }
        guard state == .opening || state == .streaming else { return }
        closeSession(reason: "hid_release")
    }

    /// 把当前累积的音频按按键窗口切出一段写盘
    func flushSegment(reason: String) {
        let start = pressSampleIndex.map { max(0, $0 - Int(Double(SAMPLE_RATE) * PRE_ROLL_SECONDS)) } ?? 0
        let segment = start < pcm.count ? Array(pcm[start...]) : []
        pressSampleIndex = nil
        pcm.removeAll()
        guard !segment.isEmpty else {
            log("语音段为空（\(reason)）")
            return
        }
        let secs = Double(segment.count) / Double(SAMPLE_RATE)
        log("语音段结束(\(reason)): \(String(format: "%.2f", secs)) 秒")
        writeSegment(segment)
    }

    /// 处理音频通知：按 frameSize 拼帧解码
    func handleAudio(_ b: [UInt8]) {
        guard state == .streaming || state == .closing else { return }
        pending.append(contentsOf: b)
        while pending.count >= frameSize {
            let frame = Array(pending.prefix(frameSize))
            pending.removeFirst(frameSize)
            decodeFrame(frame)
        }
        if state == .streaming,
           Double(pcm.count) / Double(SAMPLE_RATE) > MAX_RECORD_SECONDS {
            log("单段超过 \(Int(MAX_RECORD_SECONDS)) 秒，强制收尾")
            closeSession(reason: "max_duration")
        }
    }

    /// 解码一帧 headerless IMA ADPCM（高 nibble 在前，跨帧连续）
    func decodeFrame(_ frame: [UInt8]) {
        if syncPending {
            predictor = syncPredictor; stepIndex = syncStepIndex; syncPending = false
        }
        for byte in frame {
            let high = Int16(decodeNibble(Int(byte >> 4), &predictor, &stepIndex))
            let low = Int16(decodeNibble(Int(byte & 0x0F), &predictor, &stepIndex))
            pcm.append(high); pcm.append(low)
        }
        frames += 1
    }

    /// 原样写盘（不裁剪、不增益）
    func writeSegment(_ segment: [Int16]) {
        let peak = segment.map { abs(Int($0)) }.max() ?? 0
        log("原始峰值 \(peak)")
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let path = "/tmp/amm-capture-\(stamp).wav"
        writeWav(path, segment)
        log("已写入 \(path)")
    }
}

// MARK: - 启动

guard acquireInstanceLock() else {
    log("!! 已有实例在运行（/tmp/amm.lock 被占用），本次退出")
    exit(1)
}

let capture = AtvvCapture()
let modeName = AUDIO_MODE ? "ATVV 音频采集" : (HID_MODE ? "纯 HID 热键" : "ATVV 热键（CTL 事件驱动）")
log("模式：\(modeName)")

let blocker = SpotlightBlocker()
log(blocker.start() ? "Spotlight 拦截已启用" : "!! Spotlight 拦截启用失败")

let hid = HidReleaseWatcher()
activeHidWatcher = hid
hid.onPress = {
    DispatchQueue.main.async { capture.noteHIDPress() }
}
hid.onRelease = {
    DispatchQueue.main.async { capture.noteHIDRelease() }
}
log(hid.start() ? "HID 抬起监听已启用" : "!! HID 监听失败（检查输入监控权限）")

/// 统一退出路径：关拦截、关 HID、断 ATVV，确保不留后台残留
func shutdownAndExit(_ code: Int32) {
    blocker.stop()
    hid.stop()
    capture.shutdown()
    log("已退出，监听全部关闭")
    exit(code)
}

/// 收到 Ctrl+C / kill 时走同一套清理
func installSignalHandlers() {
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            log("收到退出信号 \(sig)")
            shutdownAndExit(0)
        }
        source.resume()
        signalSources.append(source)
    }
}

installSignalHandlers()

if SELFTEST {
    log("自检：发送一次 Ctrl+I")
    capture.hotkey.setHeld(true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        capture.hotkey.setHeld(false)
        log("自检结束")
        shutdownAndExit(0)
    }
}

capture.start()

Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
    log("待命中… HID 报文 \(hid.reportCount) / 元素值 \(hid.valueCount)")
}

DispatchQueue.main.asyncAfter(deadline: .now() + 1800) {
    log("到达常驻上限，退出")
    shutdownAndExit(0)
}
RunLoop.main.run()
