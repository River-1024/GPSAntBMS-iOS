import Combine
import CoreBluetooth
import Foundation

/// ANT BMS 蓝牙服务（CoreBluetooth Central 角色；后台保活开启的行程中尽力维持连接）。
///
/// 协议要点（与 Android 端 `BmsBluetoothManager` / `AntProtocol` 对齐）：
/// - 服务 UUID：`FFE0`；数据特征 UUID：`FFE1`（Notify/Read/Write/Write No Response）。
/// - 连接后先 discoverServices，再调用 `peripheral.setNotifyValue(true, for: ffe1)`
///   开启 Notify（CCCD `2902` 由 CoreBluetooth 栈代为写入，**禁止**直接写描述符）。
/// - 在 `peripheral(_:didUpdateNotificationStateFor:error:)` 回调中确认 Notify
///   开启成功后，再启动周期轮询。
/// - 周期写入查询命令 `7E A1 01 00 00 BE 18 55 AA 55`（默认间隔 1000 ms，
///   经 `PollInterval` 钳制在 200 ms 至 60000 ms，与 Android 一致）。
/// - 查询写入使用 `.withResponse` 并**串行化**：任意时刻最多一个在途写入
///   （`BleQueryScheduler`），轮询节拍撞上在途写入时合并一个挂起查询，写入完成回调后补发。
/// - 写包长度按 `peripheral.maximumWriteValueLength(for: .withResponse)` 查询，
///   **不做** Android 式 MTU 请求（MTU 由栈协商）。
/// - 响应以 `7E A1` 开头、`AA 55` 结尾，Notify 分片经 `BmsFrameAssembler` 合包、
///   `AntProtocol` 解析、`BmsSnapshotMapper` 映射后发布快照。
///
/// 前台生命周期约束（对齐 `MIGRATION_PLAN.md` 第 4 节）：
/// - 仅 `scenePhase == .active`（经 `startForegroundSession()`）才扫描/连接/轮询/重连；
/// - `stopForegroundSession()`（`.inactive` / `.background`）停止扫描、轮询、挂起重连、
///   正在进行的连接，清空帧缓冲与查询调度状态；**保留**已记住的设备标识与最后遥测
///   （仅将连接标记置为断开）；
/// - 所有异步回调（定时器、重连任务）捕获世代计数（`generation`），非活跃或
///   世代过期时丢弃，防止迟到回调污染新会话；
/// - 生命周期取消屏障：`stopForegroundSession()` 记录被取消连接的 peripheral 标识，
///   并**先清除** `currentPeripheral`/`dataCharacteristic` 引用再请求系统取消；该标识
///   的迟到终止回调（`didDisconnectPeripheral`/`didFailToConnect`）在重连宽限期
///   （2 秒）内**消费**屏障；回前台时同设备重连照常排程，宽限期内回调未到达则在
///   `attemptReconnect` 尝试前**强制过期**屏障——有界恢复、无永久锁死，旧会话的
///   取消回调无法清掉新会话的同设备连接尝试，其它设备始终不受影响；
/// - `attemptReconnect` 强制过期屏障后会**复检连接状态**（仍断开且无连接流程在途
///   才继续 retrieve/startConnecting/startScan），宽限期内开始的更新连接（用户手动
///   连接其它设备等）不会被陈旧的排程重连覆盖。
// MARK: - 生命周期取消屏障：纯决策缝

/// 生命周期取消屏障的纯决策缝（无 CoreBluetooth 依赖，单元测试直接注入标识验证）：
/// 终止回调的 peripheral 标识与挂起取消标识一致时，该回调才消费取消。
enum LifecycleCancellationDecision {
    /// 判定 `callbackID` 是否应消费挂起取消 `pendingID`。
    static func shouldConsume(pendingID: UUID?, callbackID: UUID) -> Bool {
        pendingID == callbackID
    }
}

// MARK: - 重连尝试决策缝（宽限期结束时的连接状态复检）

/// 自动重连尝试（2 秒宽限期结束时）的纯决策缝（无 CoreBluetooth 依赖，单元测试
/// 直接注入状态断言——无需真实 CBPeripheral 或等待 2 秒）：排程时校验的连接状态
/// 在宽限期内可能已变化（用户手动连接其它设备、或其它路径已发起连接），尝试前
/// 必须重新校验——陈旧的排程重连不得覆盖更新的连接。
enum ReconnectDecision {
    /// 判定宽限期结束时的重连尝试是否应继续：仅当仍处于**断开**且**无任何连接流程
    /// 在途**（`.idle`）时才允许 retrieve/startConnecting/startScan。
    ///
    /// 校验「无连接流程在途」使用 `connectionState == .idle`（而非仅 `!= .connecting`）：
    /// 手动连接在宽限期内可能已越过 `.connecting` 进入服务/特征发现或 Notify 使能
    /// 阶段——任何非 `.idle` 阶段都代表更新的连接正在建立，陈旧排程重连一旦覆盖
    /// `currentPeripheral` 会使该连接流程悬空，因此一律拦截。
    static func shouldProceed(isConnected: Bool, connectionState: BleConnectionState) -> Bool {
        !isConnected && connectionState == .idle
    }
}

final class BmsBluetoothService: NSObject, ObservableObject, BmsSnapshotProviding {
    // MARK: - ANT BMS 固定 UUID（与 Android 端一致）

    enum AntUUID {
        static let service = CBUUID(string: "FFE0")
        static let dataCharacteristic = CBUUID(string: "FFE1")
        // 注意：CCCD `2902` 由 CoreBluetooth 栈在 `setNotifyValue` 时托管写入，
        // 代码中不直接写该描述符，因此此处不声明其 UUID。
    }

    /// 自动重连延迟（固定 2 秒，与 Android `RECONNECT_DELAY` 一致）。
    static let reconnectDelaySeconds: TimeInterval = 2

    // MARK: - 对外状态（@Published，UI / ViewModel 订阅）

    /// 蓝牙适配器状态（`poweredOn` 才允许扫描/连接）。
    @Published private(set) var bluetoothState: BluetoothState = .unknown
    /// 是否正在扫描。
    @Published private(set) var isScanning = false
    /// 是否已连接且 Notify 就绪（进入轮询）。
    @Published private(set) var isConnected = false
    /// 连接流程阶段。
    @Published private(set) var connectionState: BleConnectionState = .idle
    /// 扫描发现的 ANT 设备（按 RSSI 降序、确定性 tie-break）。
    @Published private(set) var discoveredDevices: [BleDevice] = []
    /// 当前选择/连接的设备；断开后保留，便于详情页展示上次设备。
    @Published private(set) var currentDevice: BleDevice?
    /// 最新 BMS 快照（断开时保留最后一次遥测，仅 `isConnected` 置 false）。
    @Published private(set) var snapshot = BmsSnapshot()
    /// 最近一次传输层错误（UI 提示依据；成功路径不重置）。
    @Published private(set) var lastError: BleTransportError?

    /// 上次成功连接的设备标识（自动重连依据；停止前台会话后保留）。
    var rememberedPeripheralID: UUID? { peripheralUUIDStore.load() }

    /// 当前轮询间隔（毫秒，已钳制在 200...60000）。
    private(set) var pollingIntervalMilliseconds = PollInterval.defaultMilliseconds

    /// 快照更新流（`BmsSnapshotProviding` 契约实现）。
    var snapshotPublisher: AnyPublisher<BmsSnapshot, Never> { $snapshot.eraseToAnyPublisher() }

    // MARK: - 内部状态

    private let peripheralUUIDStore: PeripheralUUIDPersisting
    private let centralManager: CBCentralManager
    private var currentPeripheral: CBPeripheral?
    private var dataCharacteristic: CBCharacteristic?
    /// 扫描见过的 peripheral 索引（连接目标解析用，UUID → 对象）。
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var scanRegistry = ScanResultRegistry()
    private var assembler = BmsFrameAssembler()
    private var queryScheduler = BleQueryScheduler()
    private var pollingTimer: Timer?
    private var reconnectWorkItem: DispatchWorkItem?
    /// 单挂起重连令牌（`private(set)` 供测试断言「重连已排程且恰好一次」）。
    private(set) var reconnectTaskPending = false
    /// 生命周期取消屏障：停止前台会话时记录被取消连接的 peripheral 标识；该标识的
    /// 迟到终止回调（`didDisconnectPeripheral`/`didFailToConnect`）在重连宽限期
    /// （2 秒）内消费此记录；宽限期内未消费则在重连尝试前强制过期——屏障只阻止
    /// 宽限期内对同一设备发起新连接，不阻止排程，保证有界恢复（`private(set)` 供
    /// 测试观察屏障状态）。
    private(set) var pendingLifecycleCancellationID: UUID?
    /// 宽泛扫描重连兜底：等待该标识出现在扫描结果中后自动连接。
    private var reconnectTargetID: UUID?
    private var autoReconnectEnabled = true
    private var isActive = false
    /// 世代计数：每次前台会话启停递增；异步任务捕获创建时的世代，过期即丢弃。
    private var generation = 0

    // MARK: - 初始化

    /// - Parameters:
    ///   - centralManager: 注入用（测试/自定义队列场景）；默认创建并挂载主队列 delegate。
    ///   - peripheralUUIDStore: 已记住设备标识的持久化实现（默认 UserDefaults）。
    init(centralManager: CBCentralManager? = nil,
         peripheralUUIDStore: PeripheralUUIDPersisting = UserDefaultsPeripheralUUIDStore()) {
        self.peripheralUUIDStore = peripheralUUIDStore
        if let centralManager {
            self.centralManager = centralManager
        } else {
            self.centralManager = CBCentralManager(delegate: nil, queue: nil)
        }
        super.init()
        self.centralManager.delegate = self
    }

    // MARK: - 扫描

    /// 开始扫描（宽泛扫描：不过滤 serviceUUIDs，因为 FFE0 是否参与广播尚未验证；
    /// 按设备名 `ANT` 前缀过滤展示与连接候选）。
    func startScan() {
        guard isActive, bluetoothState.isUsable, !isScanning else { return }
        scanRegistry.removeAll()
        discoveredDevices = []
        isScanning = true
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }

    /// 停止扫描（幂等）。
    func stopScan() {
        guard isScanning else { return }
        centralManager.stopScan()
        isScanning = false
    }

    // MARK: - 连接 / 断开

    /// 连接扫描列表中的设备（用户选择路径；记住该设备并启用自动重连）。
    func connect(to device: BleDevice) {
        guard isActive else {
            lastError = .notActive
            return
        }
        guard bluetoothState.isUsable else {
            lastError = .bluetoothUnavailable(bluetoothState)
            return
        }
        guard let peripheral = discoveredPeripherals[device.id]
            ?? centralManager.retrievePeripherals(withIdentifiers: [device.id]).first else {
            lastError = .peripheralNotAvailable
            return
        }
        currentDevice = device
        startConnecting(to: peripheral, remember: true)
    }

    /// 用户主动断开：关闭自动重连（与 Android `disconnect()` 一致）、取消挂起重连任务，
    /// 并立即停止轮询/标记断开/发布断开快照（`didDisconnectPeripheral` 到达前状态即为断开）。
    func disconnect() {
        autoReconnectEnabled = false
        cancelReconnectTask()
        reconnectTargetID = nil
        stopPolling()
        connectionState = .idle
        isConnected = false
        // 保留最后一次遥测数值，仅标记断开（立即发布，不等 didDisconnect 回调）。
        var updatedSnapshot = snapshot
        updatedSnapshot.isConnected = false
        snapshot = updatedSnapshot
        if let peripheral = currentPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    /// 设置轮询间隔（毫秒，钳制在 200...60000；轮询进行中会按新间隔重建定时器）。
    func setPollingInterval(_ milliseconds: Int) {
        pollingIntervalMilliseconds = PollInterval.clamped(milliseconds)
        guard pollingTimer != nil else { return }
        restartPollingTimer()
    }

    // MARK: - Notify 数据缝（服务内部回调使用；单元测试直接注入分片验证数据链路）

    /// 处理一段 Notify 分片：合包 → 解析 → 映射 → 发布快照。
    /// 非活跃期间的迟到数据一律丢弃（前台约束 + 世代守卫）。
    /// 发布时快照的连接标记取服务**实际**连接状态（`isConnected`，仅 Notify 就绪为 true），
    /// 解析到遥测本身不代表已连接（映射器保持连接中立）。
    func handleIncomingChunk(_ chunk: [UInt8]) {
        guard isActive else { return }
        guard !chunk.isEmpty else { return }

        var completeFrame: [UInt8]?
        do {
            completeFrame = try assembler.append(chunk)
        } catch let error as FrameAssemblerError {
            lastError = .frameAssemblyFailed(error)
            return
        } catch {
            return
        }
        guard let frame = completeFrame else { return }

        do {
            var mapped = BmsSnapshotMapper.map(try AntProtocol.processStatusResponse(frame))
            mapped.isConnected = isConnected
            mapped.lastUpdatedAt = Date()
            snapshot = mapped
        } catch let error as AntProtocolError {
            lastError = .parseFailed(error)
        } catch {
            return
        }
    }

    // MARK: - 连接流程内部实现

    private func startConnecting(to peripheral: CBPeripheral, remember: Bool) {
        guard isActive, bluetoothState.isUsable else { return }
        // 生命周期取消屏障：同一标识的旧取消在 2 秒重连宽限期内（尚未被终止回调
        // 消费、也未被 attemptReconnect 强制过期前）禁止发起新连接——扫描命中或
        // 用户选择同一设备在宽限期内均被拦截；宽限期结束后屏障已过期，放行。
        guard pendingLifecycleCancellationID != peripheral.identifier else { return }
        if remember {
            autoReconnectEnabled = true
            peripheralUUIDStore.save(peripheral.identifier)
        }
        if currentDevice?.id != peripheral.identifier {
            let scanned = discoveredDevices.first(where: { $0.id == peripheral.identifier })
            currentDevice = scanned ?? BleDevice(id: peripheral.identifier,
                                                 name: peripheral.name,
                                                 rssi: 0)
        }
        currentPeripheral = peripheral
        dataCharacteristic = nil
        assembler.reset()
        queryScheduler.reset()
        peripheral.delegate = self
        connectionState = .connecting
        isConnected = false
        var updatedSnapshot = snapshot
        updatedSnapshot.isConnected = false
        snapshot = updatedSnapshot
        centralManager.connect(peripheral, options: nil)
    }

    /// 连接失败/能力不满足时的清理：取消连接，由 `didDisconnectPeripheral` 统一收尾并
    /// 按需排程自动重连（当前仍在活跃且未禁用重连时）。
    private func teardownConnectionAndRetry(peripheral: CBPeripheral) {
        centralManager.cancelPeripheralConnection(peripheral)
    }

    // MARK: - 查询轮询（串行化 `.withResponse`）

    private func startPolling() {
        guard pollingTimer == nil else { return }
        restartPollingTimer()
    }

    private func restartPollingTimer() {
        pollingTimer?.invalidate()
        let interval = Double(pollingIntervalMilliseconds) / 1000.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        queryScheduler.reset()
    }

    private func pollTick() {
        guard isActive, isConnected, connectionState == .ready,
              let peripheral = currentPeripheral,
              let characteristic = dataCharacteristic else { return }
        if queryScheduler.pollTick() {
            writeQueryCommand(peripheral: peripheral, characteristic: characteristic)
        }
    }

    private func writeQueryCommand(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let data = Data(AntProtocol.queryStatusCommand)
        // MTU 由栈协商，不发起 requestMtu；写包按栈允许的最大长度分片。
        let chunkSize = max(1, peripheral.maximumWriteValueLength(for: .withResponse))
        var start = 0
        while start < data.count {
            let end = min(start + chunkSize, data.count)
            peripheral.writeValue(data.subdata(in: start..<end),
                                  for: characteristic,
                                  type: .withResponse)
            start = end
        }
    }

    // MARK: - 自动重连（固定 2 秒、单挂起令牌、仅活跃场景）

    private func scheduleReconnectIfNeeded() {
        guard isActive else { return }
        guard autoReconnectEnabled, let id = rememberedPeripheralID else { return }
        // 生命周期取消屏障不再阻止排程：挂起的取消只在 2 秒重连宽限期内有效，
        // 由 `attemptReconnect` 在尝试前强制过期（有界恢复）；屏障仍阻止宽限期内
        // 对同一设备发起新连接（`startConnecting` 守卫）。
        guard !isConnected, connectionState != .connecting else { return }
        guard !reconnectTaskPending else { return } // 单挂起令牌：已有任务时不重复排程
        reconnectTaskPending = true
        let gen = generation
        reconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectTaskPending = false
            guard self.isActive, gen == self.generation else { return }
            self.attemptReconnect(to: id)
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconnectDelaySeconds,
                                      execute: workItem)
    }

    private func attemptReconnect(to id: UUID) {
        guard isActive, bluetoothState.isUsable else { return }
        // 生命周期取消屏障：2 秒宽限期结束、终止回调未在宽限期内消费挂起取消时，
        // 此处强制过期匹配的挂起取消——有界恢复，重连尝试不再受阻（无永久锁死）。
        // 宽限期内回调已消费则无匹配，直接放行。过期必须先于下方连接状态复检：
        // 否则复检直接 return 时，旧标识的屏障会一直挂起、再无到期清理点。
        expirePendingLifecycleCancellationIfNeeded(peripheralID: id)
        // 排程后 2 秒内连接状态可能已变化（用户手动连接了其它设备、或扫描命中已
        // 发起连接）：尝试前重新校验仍处于「断开且无连接流程在途」——陈旧的排程
        // 重连不会覆盖更新的手动/他设备连接（见 `ReconnectDecision`）。
        guard ReconnectDecision.shouldProceed(isConnected: isConnected,
                                              connectionState: connectionState) else { return }
        if let peripheral = centralManager.retrievePeripherals(withIdentifiers: [id]).first {
            startConnecting(to: peripheral, remember: false)
            return
        }
        // 系统不认识的旧设备：依赖宽泛扫描，命中目标（`reconnectTargetID`）后自动连接。
        reconnectTargetID = id
        startScan()
    }

    private func cancelReconnectTask() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectTaskPending = false
    }

    private func cancelPollingAndReconnect() {
        stopPolling()
        cancelReconnectTask()
    }

    // MARK: - 生命周期取消屏障（Lifecycle cancellation barrier）

    /// 记录挂起的生命周期取消（`stopForegroundSession()` 对被取消连接的 peripheral 调用；
    /// 内部测试缝：无需真实 `CBPeripheral`，注入标识即可驱动屏障状态机）。
    /// 重复记录以最近一次为准（最近一次取消的终止回调先到达；旧标识的迟到回调
    /// 因标识不匹配落入普通路径，被当前连接引用守卫丢弃，方向安全）。
    func recordLifecycleCancellation(peripheralID: UUID) {
        pendingLifecycleCancellationID = peripheralID
    }

    /// 按标识消费挂起的生命周期取消（`didDisconnectPeripheral`/`didFailToConnect` 的
    /// 统一入口；内部测试缝可直接注入标识模拟迟到终止回调）。
    ///
    /// - 消费成功（返回 true）：该回调是旧会话取消的终止回调——清除屏障，仅当尚无
    ///   挂起重连任务时在活跃场景排程一次（重连宽限期；单挂起令牌：回前台已排程的
    ///   同设备重连不会被重复排程或撤销）；不发布错误、不触碰任何连接/数据状态；
    /// - 消费失败（返回 false）：无挂起取消或标识不匹配，按正常的当前连接处理。
    @discardableResult
    func consumePendingLifecycleCancellationIfNeeded(peripheralID: UUID) -> Bool {
        guard LifecycleCancellationDecision.shouldConsume(pendingID: pendingLifecycleCancellationID,
                                                          callbackID: peripheralID) else {
            return false
        }
        pendingLifecycleCancellationID = nil
        if isActive {
            scheduleReconnectIfNeeded()
        }
        return true
    }

    /// 强制过期匹配的挂起生命周期取消（`attemptReconnect` 在 2 秒重连宽限期结束时
    /// 调用；内部测试缝：可直接注入标识模拟「终止回调未返回」的缺失回调状态）。
    ///
    /// - 返回 true：存在匹配的挂起取消且已清除——终止回调未在宽限期内到达，重连尝试
    ///   不再受阻（有界恢复）；不排程、不发布错误、不触碰任何连接/数据状态；
    /// - 返回 false：无匹配挂起取消（宽限期内已被终止回调消费，或从未建立），直接放行。
    @discardableResult
    func expirePendingLifecycleCancellationIfNeeded(peripheralID: UUID) -> Bool {
        guard LifecycleCancellationDecision.shouldConsume(pendingID: pendingLifecycleCancellationID,
                                                          callbackID: peripheralID) else {
            return false
        }
        pendingLifecycleCancellationID = nil
        return true
    }

    // MARK: - 蓝牙状态变化处理

    /// 蓝牙可用性变化后的统一处理（内部缝：`centralManagerDidUpdateState` 调用，
    /// 测试可直接注入状态断言分支行为）。
    ///
    /// - 变可用：恢复扫描并排程重连（如存在记住的设备）；
    /// - 变不可用：立即停止扫描/轮询/重连任务，**同步清除当前连接与数据状态**（不再请求
    ///   `cancelPeripheralConnection`——适配器已不可用，取消操作无意义且可能产生噪音回调；
    ///   清除 `currentPeripheral` 引用后，迟到的终止回调无法再匹配恢复后的同设备连接尝试），
    ///   立即发布断开快照——不等 `didDisconnectPeripheral` 回调，避免适配器关闭期间
    ///   UI 仍显示已连接。
    func handleBluetoothStateChange(to state: BluetoothState) {
        bluetoothState = state
        guard isActive else { return }
        if state.isUsable {
            startScan()
            scheduleReconnectIfNeeded()
        } else {
            stopScan()
            teardownConnectionForUnusableAdapter()
        }
    }

    /// 适配器不可用的统一 teardown：**不请求** `cancelPeripheralConnection`（适配器已
    /// 不可用，取消操作无意义且可能失败/产生噪音回调），而是**同步**清除本地连接状态：
    /// 轮询/查询与挂起重连任务停止、`currentPeripheral` 引用先于迟到终止回调清除
    /// （`didDisconnectPeripheral`/`didFailToConnect` 因 `peripheral === currentPeripheral`
    /// 守卫不再匹配，无法污染恢复后的同设备连接尝试）、数据特征与帧缓冲清空，
    /// 并立即发布断开快照。已记住设备标识与最后遥测保留，待 `poweredOn` 再恢复
    /// 扫描与重连。
    private func teardownConnectionForUnusableAdapter() {
        stopPolling()
        cancelReconnectTask()
        currentPeripheral = nil
        dataCharacteristic = nil
        assembler.reset()
        connectionState = .idle
        isConnected = false
        // 保留最后一次遥测数值，仅标记断开（立即发布，不等 didDisconnect 回调）。
        var updatedSnapshot = snapshot
        updatedSnapshot.isConnected = false
        snapshot = updatedSnapshot
    }
}

/// `CBManagerState` → 纯值 `BluetoothState` 的映射（保持 Domain 层不依赖 CoreBluetooth）。
private extension BluetoothState {
    init(cbState: CBManagerState) {
        switch cbState {
        case .poweredOn: self = .poweredOn
        case .poweredOff: self = .poweredOff
        case .unauthorized: self = .unauthorized
        case .unsupported: self = .unsupported
        case .resetting: self = .resetting
        @unknown default: self = .unknown
        }
    }
}

// MARK: - 前台会话（ForegroundSessionService）

extension BmsBluetoothService: ForegroundSessionService {
    func startForegroundSession() {
        guard !isActive else { return }
        isActive = true
        generation += 1
        guard bluetoothState.isUsable else { return }
        startScan()
        scheduleReconnectIfNeeded()
    }

    func stopForegroundSession() {
        guard isActive else { return }
        isActive = false
        generation += 1
        stopScan()
        cancelPollingAndReconnect()
        reconnectTargetID = nil
        assembler.reset()
        connectionState = .idle
        isConnected = false
        if let peripheral = currentPeripheral {
            // 生命周期取消屏障：先按标识记录挂起取消，并**先清除**当前连接引用，
            // 再请求系统取消——旧 peripheral 的迟到终止回调只能消费该屏障，
            // 无法再通过 `peripheral === currentPeripheral` 匹配并清掉新会话的
            // 同设备连接尝试。
            pendingLifecycleCancellationID = peripheral.identifier
            currentPeripheral = nil
            dataCharacteristic = nil
            centralManager.cancelPeripheralConnection(peripheral)
        }
        // 保留最后一次遥测数值，仅标记断开。
        var updatedSnapshot = snapshot
        updatedSnapshot.isConnected = false
        snapshot = updatedSnapshot
    }
}

// MARK: - CBCentralManagerDelegate

extension BmsBluetoothService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleBluetoothStateChange(to: BluetoothState(cbState: central.state))
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard isActive, isScanning else { return }
        discoveredPeripherals[peripheral.identifier] = peripheral
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String

        // 决策顺序：重连目标 UUID 命中优先（无条件连接，不要求名称匹配/存在）；
        // 普通发现展示仍按 ANT 名称过滤（无关的无名设备不进入列表）。
        switch DiscoveryPolicy.decide(
            peripheralID: peripheral.identifier,
            reconnectTargetID: reconnectTargetID,
            isConnected: isConnected,
            isConnecting: connectionState == .connecting,
            localName: localName,
            peripheralName: peripheral.name
        ) {
        case .autoConnect:
            reconnectTargetID = nil
            startConnecting(to: peripheral, remember: false)
        case .display:
            scanRegistry.upsert(id: peripheral.identifier,
                                name: localName ?? peripheral.name,
                                rssi: RSSI.intValue)
            discoveredDevices = scanRegistry.sortedForDisplay().map {
                BleDevice(id: $0.id, name: $0.name, rssi: $0.rssi)
            }
        case .ignore:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isActive, peripheral === currentPeripheral else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        stopScan()
        connectionState = .discoveringServices
        peripheral.discoverServices([AntUUID.service])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        // 生命周期取消屏障：取消进行中的连接可能以 didFailToConnect 收尾——
        // 先按标识消费旧会话的挂起取消；消费后不得再按「当前连接」处理
        // （不发布虚假错误、不触碰任何连接/数据状态）。
        if consumePendingLifecycleCancellationIfNeeded(peripheralID: peripheral.identifier) {
            return
        }
        guard peripheral === currentPeripheral else { return }
        currentPeripheral = nil
        dataCharacteristic = nil
        connectionState = .idle
        isConnected = false
        if isActive {
            lastError = .connectFailed(error?.localizedDescription)
            scheduleReconnectIfNeeded()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // 生命周期取消屏障：先按标识消费旧会话取消的迟到终止回调；消费后不得再
        // 触碰当前连接状态（旧身份回调不能污染新会话的同设备连接尝试）。
        if consumePendingLifecycleCancellationIfNeeded(peripheralID: peripheral.identifier) {
            return
        }
        guard peripheral === currentPeripheral else { return }
        currentPeripheral = nil
        dataCharacteristic = nil
        stopPolling()
        connectionState = .idle
        isConnected = false
        // 保留最后一次遥测数值，仅标记断开。
        var updatedSnapshot = snapshot
        updatedSnapshot.isConnected = false
        snapshot = updatedSnapshot
        guard isActive else { return }
        if let error {
            lastError = .connectFailed(error.localizedDescription)
        }
        if autoReconnectEnabled {
            scheduleReconnectIfNeeded()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BmsBluetoothService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isActive, peripheral === currentPeripheral else { return }
        if let error {
            lastError = .connectFailed(error.localizedDescription)
            teardownConnectionAndRetry(peripheral: peripheral)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == AntUUID.service }) else {
            lastError = .serviceNotFound
            teardownConnectionAndRetry(peripheral: peripheral)
            return
        }
        connectionState = .discoveringCharacteristics
        peripheral.discoverCharacteristics([AntUUID.dataCharacteristic], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard isActive, peripheral === currentPeripheral else { return }
        if let error {
            lastError = .connectFailed(error.localizedDescription)
            teardownConnectionAndRetry(peripheral: peripheral)
            return
        }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == AntUUID.dataCharacteristic }) else {
            lastError = .characteristicNotFound
            teardownConnectionAndRetry(peripheral: peripheral)
            return
        }
        // 能力校验：轮询使用 `.withResponse` 写入，依赖 Notify 接收分片。
        guard characteristic.properties.contains(.notify),
              characteristic.properties.contains(.write) else {
            lastError = .capabilityMissing(required: "notify + write")
            teardownConnectionAndRetry(peripheral: peripheral)
            return
        }
        connectionState = .enablingNotify
        dataCharacteristic = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard isActive, peripheral === currentPeripheral,
              characteristic.uuid == AntUUID.dataCharacteristic else { return }
        guard error == nil, characteristic.isNotifying else {
            lastError = .notifyFailed(error?.localizedDescription)
            teardownConnectionAndRetry(peripheral: peripheral)
            return
        }
        // Notify 就绪（CCCD 已由栈写入并确认）后才进入轮询。
        connectionState = .ready
        isConnected = true
        var updatedSnapshot = snapshot
        updatedSnapshot.isConnected = true
        snapshot = updatedSnapshot
        startPolling()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard isActive, peripheral === currentPeripheral else { return }
        if let error {
            lastError = .writeFailed(error.localizedDescription)
            queryScheduler.reset()
            return
        }
        if queryScheduler.writeCompleted() {
            writeQueryCommand(peripheral: peripheral, characteristic: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard isActive, peripheral === currentPeripheral,
              characteristic.uuid == AntUUID.dataCharacteristic else { return }
        guard error == nil else {
            lastError = .notifyFailed(error?.localizedDescription)
            return
        }
        handleIncomingChunk(Array(characteristic.value ?? Data()))
    }
}
