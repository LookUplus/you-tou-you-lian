// swift-tools-version: 5.9
import PackageDescription
import Foundation
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist").path
let package = Package(
    name: "YellowPage", platforms: [.macOS(.v13)],
    products: [.library(name: "YellowPageCore", targets: ["YellowPageCore"]),
               .executable(name: "yellowpage", targets: ["yellowpage"]),
               .executable(name: "YellowPageApp", targets: ["YellowPageApp"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "LegacyBody", publicHeadersPath: "include", linkerSettings: [.linkedFramework("Foundation")]),
        .target(name: "YellowPageCore", dependencies: ["CSQLite", "LegacyBody"]),
        .executableTarget(name: "yellowpage", dependencies: ["YellowPageCore"], linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist])]),
        .executableTarget(name: "YellowPageApp", dependencies: ["YellowPageCore"]),
        .testTarget(name: "YellowPageCoreTests", dependencies: ["YellowPageCore", "CSQLite", "YellowPageApp"])
    ])
