// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Momento",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Momento", targets: ["Momento"]),
        .executable(name: "coreml-vsr-cli", targets: ["CoreMLVSRCLI"]),
        .executable(name: "Diagnostics", targets: ["Diagnostics"]),
        .executable(name: "RBVGuard", targets: ["RBVGuard"]) 
    ],
    dependencies: [
        // No direct Sparkle link in SwiftPM to avoid resource duplication; Sparkle is embedded at packaging time.
    ],
    targets: [
        .executableTarget(
            name: "Momento",
            path: ".",
            exclude: [
                "dist",
                ".build",
                "venv",
                "venv_coreml",
                "bin",
                "docs",
                ".github",
                "branding", // only used by packaging script
                "third_party",
                "external_models",
                "converted_models",
                "fastdvdnet",
                "RealBasicVSR",
                "models",
                "Tools/coreml-vsr-cli/Package.swift"
            ],
            sources: ["AppEntry.swift", "AppUI.swift", "Updates.swift"],
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
