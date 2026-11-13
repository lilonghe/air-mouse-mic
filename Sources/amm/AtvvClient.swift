import CoreBluetooth
import Foundation

/// T1-Remote 的 ATVV 客户端：只订阅 CTL，按事件回调按下/松手
final class AtvvClient: NSObject {
    enum LinkState {
        case stopped
        case connecting
        case connected
    }

    private let serviceUUID = CBUUID(string: "ab5e0001-5a21-4f05-bc7d-af01f617b664")
    private let cmdUUID = CBUUID(string: "ab5e0002-5a21-4f05-bc7d-af01f617b664")
    private let ctlUUID = CBUUID(string: "ab5e0004-5a21-4f05-bc7d-af01f617b664")
    var onStateChange: ((LinkState) -> Void)?
    var onPress: (() -> Void)?
    var onRelease: ((TimeInterval) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var cmd: CBCharacteristic?
    private var ctl: CBCharacteristic?
    private var running = false
    private var pressDate: Date?

    /// 开始扫描已连接设备并建立 ATVV 连接
    func start() {
        guard !running else { return }
        running = true
        onStateChange?(.connecting)
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// 停止并断开连接
    func stop() {
        running = false
        pressDate = nil
        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        cmd = nil
        ctl = nil
        central = nil
        onStateChange?(.stopped)
    }

    /// 往 CMD 特征写数据，设备只支持 writeWithoutResponse
    private func send(_ bytes: [UInt8]) {
        guard let peripheral, let cmd else { return }
        peripheral.writeValue(Data(bytes), for: cmd, type: .withoutResponse)
    }

    /// 找到已配对的遥控器并连接，没找到就稍后重试
    private func connectIfPossible() {
        guard running, let central, central.state == .poweredOn else { return }
        guard let found = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first else {
            log("遥控器不在已连接列表，3 秒后重试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.connectIfPossible()
            }
            return
        }
        log("找到设备：\(found.name ?? "未知")")
        peripheral = found
        found.delegate = self
        central.connect(found, options: nil)
    }
}

extension AtvvClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard running else { return }
        guard central.state == .poweredOn else {
            log("蓝牙不可用，state=\(central.state.rawValue)")
            onStateChange?(.connecting)
            return
        }
        connectIfPossible()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("ATVV 已连接，发现服务")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("ATVV 连接失败：\(error?.localizedDescription ?? "未知")")
        retryLater()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        log("ATVV 断开：\(error?.localizedDescription ?? "无错误")")
        self.peripheral = nil
        cmd = nil
        ctl = nil
        if pressDate != nil {
            pressDate = nil
            onRelease?(0)
        }
        onStateChange?(.connecting)
        retryLater()
    }

    /// 断线后延迟重连，避免立刻打转
    private func retryLater() {
        guard running else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.connectIfPossible()
        }
    }
}

extension AtvvClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            log("ATVV 服务不存在")
            return
        }
        peripheral.discoverCharacteristics([cmdUUID, ctlUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == cmdUUID { cmd = characteristic }
            if characteristic.uuid == ctlUUID { ctl = characteristic }
        }
        guard let ctl else {
            log("缺少 CTL 特征")
            return
        }
        peripheral.setNotifyValue(true, for: ctl)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == ctlUUID, characteristic.isNotifying else { return }
        log("CTL 订阅完成")
        onStateChange?(.connected)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == ctlUUID,
              let data = characteristic.value,
              let opcode = data.first else { return }
        handleControl(opcode: opcode, payload: Array(data))
    }

    /// CTL 事件：04 按下、00 02 松手、00 08 超时
    private func handleControl(opcode: UInt8, payload: [UInt8]) {
        switch opcode {
        case 0x04:
            guard pressDate == nil else { return }
            pressDate = Date()
            log("设备起会话 → 按下")
            send([0x0D, 0x00])
            onPress?()

        case 0x00:
            let reason = payload.count >= 2 ? payload[1] : 0xFF
            switch reason {
            case 0x02, 0x08:
                let duration = pressDate.map { Date().timeIntervalSince($0) } ?? 0
                pressDate = nil
                log(reason == 0x02 ? "松手（HTT release）" : "松手（超时兜底）")
                onRelease?(duration)
            default:
                break
            }

        case 0x08:
            log("START_SEARCH，回 MIC_CLOSE")
            send([0x0D, 0x00])

        default:
            break
        }
    }
}
