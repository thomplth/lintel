// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Lintel",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "LintelCore"),
        .executableTarget(
            name: "Lintel",
            dependencies: ["LintelCore"],
            resources: [.copy("Resources/Modules"), .copy("Resources/Library"), .copy("Resources/Kit")]
        ),
        .testTarget(name: "LintelCoreTests", dependencies: ["LintelCore"]),
    ],
    swiftLanguageModes: [.v5]
)
