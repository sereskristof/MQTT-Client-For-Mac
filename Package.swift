// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MQTTClientForMac",
    platforms: [.macOS(.v14)],   // runs on macOS 14 and newer
    targets: [
        .executableTarget(
            name: "MQTTClientForMac",
            path: "Sources/MQTTClientForMac"
        )
    ]
)
