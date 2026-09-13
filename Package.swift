// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ABDownloadManager",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ABDownloadManager", targets: ["ABDownloadManagerApp"]),
        .library(name: "ABDownloadManagerCore", targets: ["ABDownloadManagerCore"]),
    ],
    targets: [
        .target(
            name: "ABDownloadManagerCore",
            path: "Sources/ABDownloadManagerCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ABDownloadManagerApp",
            dependencies: ["ABDownloadManagerCore"],
            path: "Sources/ABDownloadManagerApp",
            exclude: ["Info.plist"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ABDownloadManagerTests",
            dependencies: ["ABDownloadManagerCore"],
            path: "Tests/ABDownloadManagerTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
