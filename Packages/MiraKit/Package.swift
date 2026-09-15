// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MiraKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MiraCore", targets: ["MiraCore"]),
        .library(name: "MiraData", targets: ["MiraData"]),
        .library(name: "MiraProviders", targets: ["MiraProviders"])
    ],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")],
    targets: [
        .target(name: "MiraCore", resources: [.process("Resources")]),
        .target(name: "MiraData", dependencies: ["MiraCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "MiraProviders", dependencies: ["MiraCore"], resources: [.process("Resources")]),
        .executableTarget(name: "MiraCrashProbe", dependencies: ["MiraCore", "MiraData", .product(name: "GRDB", package: "GRDB.swift")], path: "Tests/MiraCrashProbe"),
        .executableTarget(name: "MiraScaleProbe", dependencies: ["MiraCore", "MiraData", .product(name: "GRDB", package: "GRDB.swift")], path: "Tests/MiraScaleProbe"),
        .testTarget(name: "MiraCoreTests", dependencies: ["MiraCore", "MiraData"]),
        .testTarget(name: "MiraDataTests", dependencies: ["MiraData", "MiraCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "MiraProvidersTests", dependencies: ["MiraProviders", "MiraCore", "MiraData"])
    ],
    swiftLanguageModes: [.v6]
)
