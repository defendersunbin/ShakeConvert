// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShakeConvert",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ShakeConvert",
            path: "Sources/ShakeConvert"
        )
    ]
)
