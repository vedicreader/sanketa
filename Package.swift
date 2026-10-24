// swift-tools-version: 6.2
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Sanketa",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder", exact: "0.4.5"),
    ],
    targets: [
        .target(name: "SanketaCore",
                dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")],
                swiftSettings: v5),
        .target(name: "SanketaSystem", dependencies: ["SanketaCore"], swiftSettings: v5),
        .target(name: "SanketaUI", dependencies: ["SanketaCore", "SanketaSystem"], swiftSettings: v5),
        .executableTarget(name: "Sanketa", dependencies: ["SanketaCore", "SanketaSystem", "SanketaUI"], swiftSettings: v5),
        .testTarget(name: "SanketaCoreTests", dependencies: ["SanketaCore"],
                    resources: [.copy("Fixtures")], swiftSettings: v5),
        // test helper: an AppKit window whose title tests set through stdin
        .executableTarget(name: "SanketaTitleHost", swiftSettings: v5),
        .testTarget(name: "SanketaSystemTests", dependencies: ["SanketaCore", "SanketaSystem", "SanketaTitleHost", "Sanketa"], swiftSettings: v5),
        .testTarget(name: "SanketaUITests", dependencies: ["SanketaCore", "SanketaSystem", "SanketaUI", "SanketaTitleHost"],
                    swiftSettings: v5),
    ]
)
