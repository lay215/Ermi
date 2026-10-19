// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ermi",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Ermi", targets: ["Ermi"]), .executable(name: "ErmiFanHelper", targets: ["ErmiFanHelper"])],
    targets: [
        .target(name: "ErmiCore"),
        .target(name: "ErmiMenuBarBridge"),
        .executableTarget(name: "ErmiFanHelper", dependencies: ["ErmiCore"]),
        .executableTarget(name: "Ermi", dependencies: ["ErmiCore", "ErmiMenuBarBridge"], resources: [.process("Resources")]),
        .testTarget(name: "ErmiCoreTests", dependencies: ["ErmiCore"]),
        .testTarget(name: "ErmiAppTests", dependencies: ["Ermi"]),
        .testTarget(name: "ErmiFanHelperTests", dependencies: ["ErmiFanHelper"])
    ]
)
