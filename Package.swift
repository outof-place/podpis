// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Podpis",
    defaultLocalization: "pl",
    platforms: [.macOS(.v26)],
    targets: [
        // Everything that is not UI: the podpisz CLI client, page geometry, file checks.
        .target(
            name: "PodpisCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Podpis",
            dependencies: ["PodpisCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PodpisCoreTests",
            dependencies: ["PodpisCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PodpisAppTests",
            dependencies: ["Podpis"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
