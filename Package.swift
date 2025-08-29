// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VidyScaler",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VidyScaler", targets: ["VidyScaler"])
    ],
    targets: [
        .executableTarget(
            name: "VidyScaler",
            path: ".",
            sources: ["main.swift"]
        )
    ]
)