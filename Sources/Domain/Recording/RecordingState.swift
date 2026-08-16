import Foundation

enum DashcamRecordingState: Equatable {
    case idle
    case authorizing
    case preview
    case starting
    case recording(startedAt: Date)
    case finalizing
    case interrupted(reason: String)
    case failed(RecordingFailure)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

enum RecordingFailure: Error, Equatable {
    case cameraPermissionDenied
    case microphonePermissionDenied
    case photoPermissionDenied
    case unsupportedFormat
    case cameraUnavailable
    case microphoneUnavailable
    case storageUnavailable
    case lockedContentFillsCapacity
    case writerFailed(String)
    case thermalCritical

    var displayText: String {
        switch self {
        case .cameraPermissionDenied: return "未获得摄像头权限"
        case .microphonePermissionDenied: return "未获得麦克风权限"
        case .photoPermissionDenied: return "未获得照片写入权限"
        case .unsupportedFormat: return "此设备不支持 1080p / 30 fps 录像"
        case .cameraUnavailable: return "摄像头当前不可用"
        case .microphoneUnavailable: return "麦克风当前不可用"
        case .storageUnavailable: return "录像存储空间不足"
        case .lockedContentFillsCapacity: return "锁定录像已占满容量"
        case let .writerFailed(message): return "录像写入失败：\(message)"
        case .thermalCritical: return "设备温度过高，录像已停止"
        }
    }
}
