// swift-tools-version: 5.9
import PackageDescription

// GPSANTBMS 纯 Swift 领域包：仅覆盖 Sources/Domain（协议 + 模型 + 传输纯逻辑），
// 与 Xcode 工程（XcodeGen project.yml 生成的 GPSAntBMS.app）共享同一批源码与测试文件。
// App/Services/Features 等依赖系统框架的部分由 Xcode 工程管理，不参与 SPM。
let package = Package(
    name: "GPSANTBMS",
    products: [
        .library(name: "GPSAntBMS", targets: ["GPSAntBMS"])
    ],
    targets: [
        .target(name: "GPSAntBMS", path: "Sources/Domain"),
        .testTarget(
            name: "GPSAntBMSTests",
            dependencies: ["GPSAntBMS"],
            path: "Tests/UnitTests",
            exclude: [
                // 以下测试依赖 App/Services 层（CoreBluetooth/SwiftUI/App 组合根），
                // 仅由 Xcode 工程（GPSAntBMSTests target，TEST_HOST = App）编译运行；
                // SPM 纯域层测试目标将其排除，保证 `swift test` 可独立通过。
                "AppLifecycleControllerTests.swift",
                "DashboardViewModelTests.swift",
                "BmsBluetoothServiceTests.swift",
                "LocationServiceTests.swift",
                "TripSessionControllerTests.swift",
                "RangePoolControllerTests.swift",
                "DashcamRecordingControllerTests.swift",
                "DashcamMediaCaptureTests.swift"
            ]
        )
    ]
)
