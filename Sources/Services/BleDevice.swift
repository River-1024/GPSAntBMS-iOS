import CoreBluetooth
import Foundation

/// 扫描发现的 BLE 设备（Identifiable，供 SwiftUI 列表使用）。
/// 结构体本体保持纯逻辑（不引用 CoreBluetooth），便于测试；
/// 从 CoreBluetooth 对象的构造放在扩展中。
struct BleDevice: Identifiable, Equatable {
    let id: UUID
    let name: String?
    let rssi: Int

    init(id: UUID, name: String?, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

extension BleDevice {
    /// 从 CoreBluetooth 对象构造（仅服务层使用）。
    init(peripheral: CBPeripheral, rssi: Int) {
        self.init(id: peripheral.identifier, name: peripheral.name, rssi: rssi)
    }
}
