// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Notchy",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Notchy", path: "Sources/Notchy",
                          resources: [.process("Resources")],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "NotchyTests", dependencies: ["Notchy"], path: "Tests/NotchyTests"),
    ]
)
