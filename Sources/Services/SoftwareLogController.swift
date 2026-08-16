import Combine
import Foundation

final class SoftwareLogController: ObservableObject {
    @Published private(set) var entries: [SoftwareLogEntry]
    @Published private(set) var storageWarning: String?

    private let store: SoftwareLogStore
    private let now: () -> Date
    private var cancellables: Set<AnyCancellable> = []

    init(
        bluetoothService: BmsBluetoothService? = nil,
        tripSession: TripSessionController? = nil,
        store: SoftwareLogStore = SoftwareLogStore()
            ?? SoftwareLogStore(directoryURL: FileManager.default.temporaryDirectory),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
        let result = store.load()
        entries = result.entries
        storageWarning = result.failure.map(Self.warningText(for:))
        append(level: .info, source: "App", message: "应用前台会话已启动")
        bind(bluetoothService: bluetoothService, tripSession: tripSession)
    }

    func append(level: SoftwareLogLevel, source: String, message: String) {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessage.isEmpty else { return }
        let entry = SoftwareLogEntry(
            timestamp: now(),
            level: level,
            source: normalizedSource.isEmpty ? "App" : normalizedSource,
            message: normalizedMessage)
        entries = store.bounded(entries + [entry])
        persist()
    }

    func clear() {
        do {
            try store.clear()
            entries = []
            storageWarning = nil
        } catch {
            storageWarning = "软件日志清空失败"
        }
    }

    func copyText(minimumLevel: SoftwareLogLevel = .debug) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return entries
            .filter { $0.level >= minimumLevel }
            .map { "\(formatter.string(from: $0.timestamp)) [\($0.level.displayText)] \($0.source): \($0.message)" }
            .joined(separator: "\n")
    }

    private func bind(bluetoothService: BmsBluetoothService?, tripSession: TripSessionController?) {
        bluetoothService?.$connectionState
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] state in
                self?.append(level: state == .ready ? .info : .debug,
                             source: "BLE", message: "连接状态：\(state.displayText)")
            }
            .store(in: &cancellables)

        bluetoothService?.$lastError
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.append(level: .error, source: "BLE", message: error.displayText)
            }
            .store(in: &cancellables)

        tripSession?.$isRecording
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] recording in
                self?.append(level: .info, source: "行程", message: recording ? "开始记录" : "结束记录")
            }
            .store(in: &cancellables)

        tripSession?.$storageWarning
            .compactMap { $0 }
            .sink { [weak self] warning in
                self?.append(level: .warning, source: "存储", message: warning)
            }
            .store(in: &cancellables)
    }

    private func persist() {
        do {
            try store.save(entries)
            storageWarning = nil
        } catch {
            storageWarning = "软件日志保存失败"
        }
    }

    private static func warningText(for failure: SoftwareLogStore.LoadFailure) -> String {
        switch failure {
        case .unreadable: return "软件日志无法读取"
        case .decodingFailed: return "软件日志文件损坏，已从空日志开始"
        }
    }
}
