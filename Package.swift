// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EasyDisplay",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "EasyDisplay", targets: ["EasyDisplay"])],
    targets: [
        .executableTarget(name: "EasyDisplay", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "EasyDisplayTests", dependencies: ["EasyDisplay"])
    ]
)
