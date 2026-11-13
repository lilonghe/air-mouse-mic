// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AtvvMenu",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AtvvMenu",
            path: "Sources/AtvvMenu"
        )
    ]
)
