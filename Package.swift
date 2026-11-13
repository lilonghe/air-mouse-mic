// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "air-mouse-mic",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "amm",
            path: "Sources/amm"
        )
    ]
)
