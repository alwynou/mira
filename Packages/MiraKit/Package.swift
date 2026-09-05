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
        .target(name: "MiraCore"),
        .target(name: "MiraData", dependencies: ["MiraCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "MiraProviders", dependencies: ["MiraCore"]),
        .testTarget(name: "MiraCoreTests", dependencies: ["MiraCore", "MiraData"]),
        .testTarget(name: "MiraDataTests", dependencies: ["MiraData", "MiraCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "MiraProvidersTests", dependencies: ["MiraProviders", "MiraCore"])
    ],
    swiftLanguageModes: [.v6]
)
