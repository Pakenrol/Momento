// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MaccyScaler",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MaccyScaler", targets: ["MaccyScaler"]),
        .executable(name: "coreml-vsr-cli", targets: ["CoreMLVSRCLI"]),
        .executable(name: "Diagnostics", targets: ["Diagnostics"]),
        .executable(name: "RBVGuard", targets: ["RBVGuard"]) 
    ],
    targets: [
        .executableTarget(
            name: "MaccyScaler",
            path: ".",
            sources: ["AppEntry.swift", "AppUI.swift"],
            resources: [
                // Embed Core ML models into the app bundle
                .copy("FastDVDnet.mlpackage"),
                .copy("RealBasicVSR_x2.mlpackage")
            ]
        ),
        .executableTarget(
            name: "CoreMLVSRCLI",
            path: "Tools/coreml-vsr-cli",
            sources: ["main.swift"]
        ),
        .executableTarget(
            name: "Diagnostics",
            path: "Tools/Diagnostics",
            sources: ["main.swift"]
        ),
        .executableTarget(
            name: "RBVGuard",
            path: "Tools/RBVGuard",
            sources: ["main.swift"]
        )
    ]
)
