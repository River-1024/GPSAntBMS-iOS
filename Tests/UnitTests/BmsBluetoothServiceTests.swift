import XCTest
@testable import GPSAntBMS

/// 服务级测试（Xcode 工程目标编译，SPM 纯域层排除——依赖 App/Services 层）：
/// 不依赖真实蓝牙硬件，通过内部数据缝（`handleIncomingChunk`）与生命周期缝
/// （`start/stopForegroundSession`、`handleBluetoothStateChange`）验证 Notify →
/// 合包 → 解析 → 快照链路、前台约束（非活跃丢弃数据）、遥测保留、间隔钳制、记忆
/// 持久化，以及生命周期取消屏障（经内部标识缝 `recordLifecycleCancellation` /
/// `consumePendingLifecycleCancellationIfNeeded` / `expirePendingLifecycleCancellationIfNeeded`
/// / 纯决策缝驱动，无需真实 CBPeripheral）。重连尝试的连接状态复检（宽限期结束时
/// 防止陈旧排程重连覆盖更新连接）经纯决策缝 `ReconnectDecision` 覆盖——服务状态
/// 只能经真实连接流程进入 connected/connecting，无法在单元测试中构造，故决策逻辑
/// 单独可测；`attemptReconnect` 的完整调用路径留待硬件/Xcode 集成门禁。
final class BmsBluetoothServiceTests: XCTestCase {
    private func makeService() -> BmsBluetoothService {
        BmsBluetoothService(peripheralUUIDStore: InMemoryPeripheralUUIDStore())
    }

    /// 9 段 Notify 分片依次注入：合包 → 解析 → 快照发布（与 Android 抓包结果一致）。
    /// 注意：注入分片只验证遥测链路，**不代表真实 BLE 连接**——快照连接标记取服务实际
    /// 连接状态（此处未连接，故为 false；真实链路中由 `didUpdateNotificationStateFor`
    /// 就绪后才为 true）。
    func testIncomingChunksAssembleParseAndPublishSnapshot() {
        let service = makeService()
        service.startForegroundSession()

        for segment in TestFixtures.messageTxtSegments {
            service.handleIncomingChunk(segment)
        }

        XCTAssertFalse(service.snapshot.isConnected)
        XCTAssertEqual(service.snapshot.totalVoltage, 81.602, accuracy: 0.001)
        XCTAssertEqual(service.snapshot.soc, 93, accuracy: 0.001)
        XCTAssertEqual(service.snapshot.bmsStatusText, "待机")
    }

    /// 非活跃期间到达的分片一律丢弃（前台约束；迟到回调不污染新会话）。
    func testPartialFrameThenInactiveIgnoresLateChunks() {
        let service = makeService()
        service.startForegroundSession()
        service.handleIncomingChunk(TestFixtures.messageTxtSegments[0])
        XCTAssertEqual(service.snapshot.totalVoltage, 0) // 帧未完成，尚无快照

        service.stopForegroundSession()
        for segment in TestFixtures.messageTxtSegments.dropFirst() {
            service.handleIncomingChunk(segment)
        }

        XCTAssertEqual(service.snapshot.totalVoltage, 0) // 非活跃期间全部丢弃
        XCTAssertFalse(service.snapshot.isConnected)
    }

    /// 停止前台会话：保留最后一次遥测数值，仅连接标记置为断开。
    func testStopForegroundSessionPreservesTelemetryButMarksDisconnected() {
        let service = makeService()
        service.startForegroundSession()
        for segment in TestFixtures.messageTxtSegments {
            service.handleIncomingChunk(segment)
        }
        XCTAssertEqual(service.snapshot.totalVoltage, 81.602, accuracy: 0.001)
        XCTAssertFalse(service.snapshot.isConnected) // 未建立真实连接，遥测不携带连接标记

        service.stopForegroundSession()

        XCTAssertEqual(service.snapshot.totalVoltage, 81.602, accuracy: 0.001)
        XCTAssertEqual(service.snapshot.soc, 93, accuracy: 0.001)
        XCTAssertFalse(service.snapshot.isConnected)
    }

    /// 蓝牙适配器不可用：立即清除连接/数据状态并发布断开快照（不等 didDisconnect 回调），
    /// 遥测数值保留。
    func testBluetoothUnavailableClearsConnectionAndPublishesDisconnectedSnapshot() {
        let service = makeService()
        service.startForegroundSession()
        for segment in TestFixtures.messageTxtSegments {
            service.handleIncomingChunk(segment)
        }
        XCTAssertEqual(service.snapshot.totalVoltage, 81.602, accuracy: 0.001)

        service.handleBluetoothStateChange(to: .poweredOff)

        XCTAssertEqual(service.bluetoothState, .poweredOff)
        XCTAssertFalse(service.isScanning)
        XCTAssertFalse(service.isConnected)
        XCTAssertEqual(service.connectionState, .idle)
        XCTAssertFalse(service.snapshot.isConnected)
        XCTAssertEqual(service.snapshot.totalVoltage, 81.602, accuracy: 0.001) // 遥测保留
    }

    /// 蓝牙变为可用（活跃场景）：开始扫描并排程重连（无记忆设备时仅扫描）。
    func testBluetoothPoweredOnStartsScanWhenActive() {
        let service = makeService()
        service.startForegroundSession()
        XCTAssertFalse(service.isScanning) // 初始状态未知，不扫描

        service.handleBluetoothStateChange(to: .poweredOn)

        XCTAssertTrue(service.isScanning)
        XCTAssertTrue(service.bluetoothState.isUsable)

        service.handleBluetoothStateChange(to: .poweredOff)
        XCTAssertFalse(service.isScanning)
    }

    // MARK: - 适配器不可用 teardown（状态缝）

    /// 适配器不可用（活跃场景、已记住设备、重连已排程）：同步清除连接/数据状态与
    /// 挂起重连任务、立即发布断开快照；不可用期间不遗留任何挂起重连（待 poweredOn
    /// 才恢复），已记住设备标识与遥测保留，且不触碰生命周期取消屏障。
    func testPoweredOffProducesIdleDisconnectedAndNoPendingReconnect() {
        let store = InMemoryPeripheralUUIDStore()
        let service = BmsBluetoothService(peripheralUUIDStore: store)
        let id = UUID()
        store.save(id)

        service.startForegroundSession()
        service.handleBluetoothStateChange(to: .poweredOn)
        XCTAssertTrue(service.isScanning)
        XCTAssertTrue(service.reconnectTaskPending) // 已排程重连（待适配器恢复）

        service.handleBluetoothStateChange(to: .poweredOff)

        XCTAssertEqual(service.bluetoothState, .poweredOff)
        XCTAssertFalse(service.isScanning)
        XCTAssertFalse(service.isConnected)
        XCTAssertEqual(service.connectionState, .idle)
        XCTAssertFalse(service.reconnectTaskPending) // 不可用期间无挂起重连
        XCTAssertFalse(service.snapshot.isConnected) // 断开快照已立即发布
        XCTAssertEqual(service.rememberedPeripheralID, id) // 记忆保留
        XCTAssertNil(service.pendingLifecycleCancellationID) // 屏障不受影响
    }

    /// 适配器从不可用恢复为 poweredOn：恢复扫描，并为已记住设备排程**恰好一次**重连
    /// （单挂起令牌：重复 poweredOn 不重复排程）。
    func testPoweredOnAfterAdapterLossResumesScanAndSchedulesAtMostOneReconnect() {
        let store = InMemoryPeripheralUUIDStore()
        let service = BmsBluetoothService(peripheralUUIDStore: store)
        let id = UUID()
        store.save(id)

        service.startForegroundSession()
        service.handleBluetoothStateChange(to: .poweredOn)
        service.handleBluetoothStateChange(to: .poweredOff)
        XCTAssertFalse(service.isScanning)
        XCTAssertFalse(service.reconnectTaskPending)

        service.handleBluetoothStateChange(to: .poweredOn)

        XCTAssertTrue(service.isScanning) // 恢复扫描
        XCTAssertTrue(service.reconnectTaskPending) // 重连排程恰好一次

        service.handleBluetoothStateChange(to: .poweredOn)
        XCTAssertTrue(service.isScanning)
        XCTAssertTrue(service.reconnectTaskPending) // 重复恢复不重复排程
        XCTAssertEqual(service.rememberedPeripheralID, id)
    }

    /// 用户主动断开：立即发布断开快照、状态回 idle；已记住设备标识不被清除
    /// （只是关闭自动重连，回前台仍可恢复）。
    func testDisconnectKeepsRememberedDeviceAndPublishesDisconnectedState() {
        let store = InMemoryPeripheralUUIDStore()
        let service = BmsBluetoothService(peripheralUUIDStore: store)
        let id = UUID()
        store.save(id)
        service.startForegroundSession()
        for segment in TestFixtures.messageTxtSegments {
            service.handleIncomingChunk(segment)
        }

        service.disconnect()

        XCTAssertFalse(service.isConnected)
        XCTAssertEqual(service.connectionState, .idle)
        XCTAssertFalse(service.snapshot.isConnected)
        XCTAssertEqual(service.snapshot.totalVoltage, 81.602, accuracy: 0.001) // 遥测保留
        XCTAssertEqual(service.rememberedPeripheralID, id) // 记忆不清除（仅禁用自动重连）
    }

    /// 轮询间隔钳制在 200...60000（默认 1000）。
    func testPollingIntervalIsClamped() {
        let service = makeService()

        XCTAssertEqual(service.pollingIntervalMilliseconds, PollInterval.defaultMilliseconds)

        service.setPollingInterval(50)
        XCTAssertEqual(service.pollingIntervalMilliseconds, 200)

        service.setPollingInterval(90_000)
        XCTAssertEqual(service.pollingIntervalMilliseconds, 60_000)

        service.setPollingInterval(500)
        XCTAssertEqual(service.pollingIntervalMilliseconds, 500)
    }

    /// 已记住的设备标识在停止前台会话后保留（回前台时恢复连接的依据）。
    func testRememberedDevicePersistsAcrossForegroundSessionStop() {
        let store = InMemoryPeripheralUUIDStore()
        let service = BmsBluetoothService(peripheralUUIDStore: store)
        let id = UUID()
        store.save(id)

        XCTAssertEqual(service.rememberedPeripheralID, id)

        service.startForegroundSession()
        service.stopForegroundSession()

        XCTAssertEqual(service.rememberedPeripheralID, id) // 停止前台会话不清除记忆
    }

    /// 自动重连延迟固定为 2 秒（与 Android `RECONNECT_DELAY` 一致）。
    func testReconnectDelayIsExactlyTwoSeconds() {
        XCTAssertEqual(BmsBluetoothService.reconnectDelaySeconds, 2)
    }

    /// 同一快照提供者共享：服务发布快照后，注入同一实例的视图模型可收到更新。
    func testSharedServiceSnapshotFlowsToViewModelSubscription() {
        let service = makeService()
        let viewModel = DashboardViewModel(bluetoothService: service)
        service.startForegroundSession()

        for segment in TestFixtures.messageTxtSegments {
            service.handleIncomingChunk(segment)
        }

        waitUntil(viewModel.snapshot.totalVoltage == 81.602)

        XCTAssertEqual(viewModel.snapshot.soc, 93, accuracy: 0.001)
        XCTAssertEqual(viewModel.snapshot.bmsStatusText, "待机")
    }

    // MARK: - 生命周期取消屏障：纯决策缝

    /// 只有终止回调标识与挂起取消标识一致时才消费取消；无挂起取消时不消费。
    func testLifecycleCancellationDecisionConsumesOnlyMatchingIdentifier() {
        let id = UUID()
        let other = UUID()

        XCTAssertFalse(LifecycleCancellationDecision.shouldConsume(pendingID: nil, callbackID: id))
        XCTAssertTrue(LifecycleCancellationDecision.shouldConsume(pendingID: id, callbackID: id))
        XCTAssertFalse(LifecycleCancellationDecision.shouldConsume(pendingID: id, callbackID: other))
        XCTAssertFalse(LifecycleCancellationDecision.shouldConsume(pendingID: other, callbackID: id))
    }

    // MARK: - 生命周期取消屏障：服务级状态机（无真实 BLE 硬件，经内部标识缝驱动）

    /// 停止前台会话时未在连接任何设备 → 不记录挂起取消（屏障仅在取消真实连接时建立）。
    func testStopForegroundSessionWithoutConnectionRecordsNoCancellation() {
        let service = makeService()
        service.startForegroundSession()
        service.handleBluetoothStateChange(to: .poweredOn)

        service.stopForegroundSession()

        XCTAssertNil(service.pendingLifecycleCancellationID)
    }

    /// 无挂起取消时，终止回调消费入口直接放行（返回 false，不改变任何状态）。
    func testConsumeWithoutPendingCancellationFallsThrough() {
        let service = makeService()
        service.startForegroundSession()

        XCTAssertFalse(service.consumePendingLifecycleCancellationIfNeeded(peripheralID: UUID()))
        XCTAssertNil(service.pendingLifecycleCancellationID)
        XCTAssertFalse(service.reconnectTaskPending)
    }

    /// 屏障未消费前：回前台时对同一设备的重连**照常排程**（恰好一个挂起任务），
    /// 屏障保持挂起可消费——2 秒宽限期结束后由 `attemptReconnect` 强制过期兜底，
    /// 无永久锁死。
    func testPendingCancellationSchedulesOneReconnectWhileBarrierPending() {
        let store = InMemoryPeripheralUUIDStore()
        let service = BmsBluetoothService(peripheralUUIDStore: store)
        let id = UUID()
        store.save(id)

        // 模拟「停止前台会话时取消连接该设备」：屏障记录其标识。
        service.recordLifecycleCancellation(peripheralID: id)
        service.startForegroundSession()
        service.handleBluetoothStateChange(to: .poweredOn)

        XCTAssertEqual(service.pendingLifecycleCancellationID, id) // 屏障仍挂起
        XCTAssertTrue(service.reconnectTaskPending) // 同设备重连已排程（恰好一个），不被屏障阻止
    }

    /// 屏障只针对被记录的那个标识：其它已记住设备的重连排程不受影响（照常排程）。
    func testPendingCancellationDoesNotBlockDifferentRememberedIdentifier() {
        let store = InMemoryPeripheralUUIDStore()
        let service = BmsBluetoothService(peripheralUUIDStore: store)
        let blocked = UUID()
        let other = UUID()
        store.save(other)

        service.recordLifecycleCancellation(peripheralID: blocked)
        service.startForegroundSession()
        service.handleBluetoothStateChange(to: .poweredOn)

        XCTAssertEqual(service.pendingLifecycleCancellationID, blocked)
        XCTAssertTrue(service.reconnectTaskPending) // 其它设备正常排程重连
    }

    /// 标识不匹配的终止回调不消费屏障（旧取消仍挂起，直到匹配回调到达）。
    func testMismatchedCallbackDoesNotConsumePendingCancellation() {
        let service = makeService()
        let id = UUID()

        service.recordLifecycleCancellation(peripheralID: id)

        XCTAssertFalse(service.consumePendingLifecycleCancellationIfNeeded(peripheralID: UUID()))
        XCTAssertEqual(service.pendingLifecycleCancellationID, id)
    }

    /// 活跃场景宽限期内消费屏障：重连任务已在排程（恰好一个），消费后仍保持恰好一个
    /// （单挂起令牌：`scheduleReconnectIfNeeded` 不重复排程、不撤销）；不发布虚假
    /// 错误、不触碰连接状态与遥测。
    func testConsumingCancellationDuringGraceKeepsExactlyOnePendingReconnect() {
        let store = InMemoryPeripheralUUIDStore()
        let service = BmsBluetoothService(peripheralUUIDStore: store)
        let id = UUID()
        store.save(id)

        service.recordLifecycleCancellation(peripheralID: id)
        service.startForegroundSession()
        service.handleBluetoothStateChange(to: .poweredOn)
        XCTAssertTrue(service.reconnectTaskPending) // 宽限期：回前台已排程重连（恰好一个）

        // 终止回调在宽限期内到达 → 消费屏障；挂起任务保持恰好一个（不重复、不撤销）。
        XCTAssertTrue(service.consumePendingLifecycleCancellationIfNeeded(peripheralID: id))
        XCTAssertNil(service.pendingLifecycleCancellationID)
        XCTAssertTrue(service.reconnectTaskPending) // 消费后仍恰好一个挂起任务

        XCTAssertFalse(service.consumePendingLifecycleCancellationIfNeeded(peripheralID: id))
        XCTAssertNil(service.lastError) // 旧会话取消不发布虚假错误
        XCTAssertEqual(service.connectionState, .idle)
        XCTAssertFalse(service.isConnected)
        XCTAssertFalse(service.snapshot.isConnected)
    }

    /// 非活跃场景消费屏障：只清除屏障，不重启任何 BLE 工作（无重连排程）。
    func testConsumingCancellationWhileInactiveDoesNotRestartBleWork() {
        let store = InMemoryPeripheralUUIDStore()
        let service = BmsBluetoothService(peripheralUUIDStore: store)
        let id = UUID()
        store.save(id)

        service.recordLifecycleCancellation(peripheralID: id)
        service.startForegroundSession()
        service.handleBluetoothStateChange(to: .poweredOn)
        service.stopForegroundSession()

        XCTAssertTrue(service.consumePendingLifecycleCancellationIfNeeded(peripheralID: id))
        XCTAssertNil(service.pendingLifecycleCancellationID)
        XCTAssertFalse(service.reconnectTaskPending) // 非活跃：不排程任何重连
        XCTAssertEqual(service.connectionState, .idle)
        XCTAssertFalse(service.isConnected)
    }

    /// 消费旧会话取消时，不干扰已为其它设备排程的重连（单挂起令牌不重复、不撤销）。
    func testConsumingCancellationDoesNotDuplicateReconnectForOtherDevice() {
        let store = InMemoryPeripheralUUIDStore()
        let service = BmsBluetoothService(peripheralUUIDStore: store)
        let oldID = UUID()
        let other = UUID()
        store.save(other)

        service.recordLifecycleCancellation(peripheralID: oldID)
        service.startForegroundSession()
        service.handleBluetoothStateChange(to: .poweredOn)
        XCTAssertTrue(service.reconnectTaskPending) // 其它设备的重连已排程

        XCTAssertTrue(service.consumePendingLifecycleCancellationIfNeeded(peripheralID: oldID))
        XCTAssertTrue(service.reconnectTaskPending) // 未被消费路径重复排程或撤销
        XCTAssertNil(service.lastError)
        XCTAssertEqual(service.connectionState, .idle)
        XCTAssertFalse(service.isConnected)
    }

    // MARK: - 生命周期取消屏障：过期缝（重连尝试前的有界恢复）

    /// 终止回调未在宽限期内到达：重连尝试前强制过期**匹配**的挂起取消
    /// （返回 true 并清除屏障，重连不再受阻）。
    func testExpireMatchingPendingCancellationClearsBarrier() {
        let service = makeService()
        let id = UUID()

        service.recordLifecycleCancellation(peripheralID: id)

        XCTAssertTrue(service.expirePendingLifecycleCancellationIfNeeded(peripheralID: id))
        XCTAssertNil(service.pendingLifecycleCancellationID)
    }

    /// 过期调用标识不匹配：不消费屏障（挂起取消保留，等待匹配回调或下一次过期）。
    func testExpireNonMatchingPendingCancellationKeepsBarrier() {
        let service = makeService()
        let id = UUID()

        service.recordLifecycleCancellation(peripheralID: id)

        XCTAssertFalse(service.expirePendingLifecycleCancellationIfNeeded(peripheralID: UUID()))
        XCTAssertEqual(service.pendingLifecycleCancellationID, id)
    }

    /// 无挂起取消时过期调用直接放行（返回 false，不改变任何状态）。
    func testExpireWithoutPendingCancellationFallsThrough() {
        let service = makeService()

        XCTAssertFalse(service.expirePendingLifecycleCancellationIfNeeded(peripheralID: UUID()))
        XCTAssertNil(service.pendingLifecycleCancellationID)
    }

    /// 「回调永不返回」状态：回前台已排程重连，2 秒宽限期内终止回调未到达 →
    /// `attemptReconnect` 在 retrieve/startConnecting 前经过期缝强制清除屏障，
    /// 保证有界恢复（同一标识不再被任何守卫阻止，无永久锁死）。
    func testCallbackMissingExpiresBarrierBeforeReconnectAttempt() {
        let store = InMemoryPeripheralUUIDStore()
        let service = BmsBluetoothService(peripheralUUIDStore: store)
        let id = UUID()
        store.save(id)

        service.recordLifecycleCancellation(peripheralID: id)
        service.startForegroundSession()
        service.handleBluetoothStateChange(to: .poweredOn)
        XCTAssertTrue(service.reconnectTaskPending) // 宽限期：同设备重连已排程
        XCTAssertEqual(service.pendingLifecycleCancellationID, id)

        // 宽限期结束、回调未到达 → 过期缝（模拟 attemptReconnect 调用点）。
        XCTAssertTrue(service.expirePendingLifecycleCancellationIfNeeded(peripheralID: id))
        XCTAssertNil(service.pendingLifecycleCancellationID) // 屏障已清除，重连不再受阻
        XCTAssertTrue(service.reconnectTaskPending) // 原挂起任务不受影响（由重连尝试消费）
    }

    // MARK: - 重连尝试决策缝（宽限期结束时的连接状态复检）

    /// 已连接（Notify 就绪）时，宽限期结束的重连尝试必须放弃——陈旧排程重连
    /// 不得覆盖现有连接。
    func testReconnectDecisionBlocksWhenConnected() {
        XCTAssertFalse(ReconnectDecision.shouldProceed(isConnected: true, connectionState: .idle))
        XCTAssertFalse(ReconnectDecision.shouldProceed(isConnected: true, connectionState: .connecting))
        XCTAssertFalse(ReconnectDecision.shouldProceed(isConnected: true, connectionState: .ready))
    }

    /// 连接流程在途（用户手动/他设备连接进行中）时，重连尝试必须放弃——不仅
    /// `.connecting`，服务/特征发现与 Notify 使能等中间阶段同样拦截（否则覆盖
    /// `currentPeripheral` 会使在途连接流程悬空）。
    func testReconnectDecisionBlocksAnyInFlightConnectionFlow() {
        for state: BleConnectionState in [.connecting,
                                          .discoveringServices,
                                          .discoveringCharacteristics,
                                          .enablingNotify,
                                          .ready] {
            XCTAssertFalse(ReconnectDecision.shouldProceed(isConnected: false, connectionState: state))
        }
    }

    /// 断开且空闲（无任何连接流程在途）时，宽限期结束的重连尝试放行。
    func testReconnectDecisionAllowsWhenDisconnectedAndIdle() {
        XCTAssertTrue(ReconnectDecision.shouldProceed(isConnected: false, connectionState: .idle))
    }
}
