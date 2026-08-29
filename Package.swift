// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Focusdoro",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FocusdoroCore", targets: ["FocusdoroCore"]),
        .executable(name: "Focusdoro", targets: ["Focusdoro"]),
    ],
    targets: [
        .target(
            name: "FocusdoroCore",
            path: "Sources/FocusdoroCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Focusdoro",
            dependencies: ["FocusdoroCore"],
            path: "Sources/Focusdoro",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FocusdoroCoreTests",
            dependencies: ["FocusdoroCore"],
            path: "Tests/FocusdoroCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
