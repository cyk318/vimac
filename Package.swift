// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Vimac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Vimac", targets: ["VimacApp"]), .executable(name: "VimacFixture", targets: ["VimacFixture"])],
    targets: [
        .target(name: "VimCore"),
        .target(name: "MacAdapters", dependencies: ["VimCore"]),
        .executableTarget(name: "VimacApp", dependencies: ["VimCore", "MacAdapters"]),
        .executableTarget(name: "VimacFixture"),
        .executableTarget(name: "VimacProbe", dependencies: ["VimCore", "MacAdapters"]),
        .testTarget(name: "VimCoreTests", dependencies: ["VimCore"])
    ]
)
