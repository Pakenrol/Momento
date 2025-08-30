// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MaccyScaler",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MaccyScaler", targets: ["MaccyScaler"]),
        .executable(name: "coreml-vsr-cli", targets: ["CoreMLVSRCLI"]) 
    ],
    targets: [
        .executableTarget(
            name: "MaccyScaler",
            path: ".",
            sources: ["main.swift"]
        ),
        .executableTarget(
            name: "CoreMLVSRCLI",
            path: "Tools/coreml-vsr-cli",
            sources: ["main.swift"]
        )
    ]
)
