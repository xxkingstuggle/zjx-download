// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "zjx-download",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ZJXDownloadCore", targets: ["ZJXDownloadCore"]),
        .executable(name: "zjx-download-cli", targets: ["ZJXDownloadCLI"]),
        .executable(name: "zjx-download-native-host", targets: ["ZJXDownloadNativeHost"]),
    ],
    targets: [
        .target(name: "ZJXDownloadNetworkShim", path: "Sources/ZJXDownloadNetworkShim", publicHeadersPath: "include", linkerSettings: [.linkedFramework("Network")]),
        .target(name: "ZJXDownloadCore", dependencies: ["ZJXDownloadNetworkShim"], path: "Sources/ZJXDownloadCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "ZJXDownloadCLI", dependencies: ["ZJXDownloadCore"], path: "Sources/ZJXDownloadCLI", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "ZJXDownloadNativeHost", dependencies: ["ZJXDownloadCore"], path: "Sources/ZJXDownloadNativeHost", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ZJXDownloadCoreTests", dependencies: ["ZJXDownloadCore"], path: "Tests/ZJXDownloadCoreTests", swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
