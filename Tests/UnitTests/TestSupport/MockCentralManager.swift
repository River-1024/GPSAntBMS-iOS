import CoreBluetooth

/// `CBCentralManager` 测试替身（子类化）：固定状态 + 空操作，阻断模拟器 daemon 干扰。
///
/// 背景：模拟器上真实 `CBCentralManager` 初始化后，系统 daemon 会异步回调
/// `centralManagerDidUpdateState`（模拟器无蓝牙硬件时状态为 `.unsupported`/
/// `.poweredOff`），覆盖测试通过 `handleBluetoothStateChange` 注入的状态。
/// 同步断言能抢在回调前完成（现有 BmsBluetoothServiceTests 全部同步断言），
/// 但 5 秒等待类断言必然被覆盖（CI 第 8 轮 `testBluetoothStateMirrorsFromSharedService`
/// 实测失败：注入的 `.poweredOn` 在等待窗口内被系统回调覆盖）。
///
/// 本替身将 `state` 固定为注入值（默认 `.poweredOn`）并把所有 BLE 操作改为空实现：
/// daemon 回调（若仍到达）读取 `central.state` 时走 override getter，始终报告同一
/// 固定状态，`handleBluetoothStateChange` 幂等，不再产生竞态覆盖。
final class MockCentralManager: CBCentralManager {
    private let fixedState: CBManagerState

    init(state: CBManagerState = .poweredOn) {
        self.fixedState = state
        super.init(delegate: nil, queue: nil, options: nil)
    }

    override var state: CBManagerState { fixedState }

    override func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?,
                                     options: [String: Any]? = nil) {}

    override func stopScan() {}

    override func connect(_ peripheral: CBPeripheral, options: [String: Any]? = nil) {}

    override func cancelPeripheralConnection(_ peripheral: CBPeripheral) {}

    override func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [CBPeripheral] { [] }

    override func retrieveConnectedPeripherals(withServices services: [CBUUID]) -> [CBPeripheral] { [] }
}
