// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "coreml-vsr-cli",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "coreml-vsr-cli",
            path: "."
        )
    ]
)