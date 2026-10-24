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
        .executableTarget(name: "Sanketa", dependencies: ["SanketaCore", "SanketaSystem"], swiftSettings: v5),
        .testTarget(name: "SanketaCoreTests", dependencies: ["SanketaCore"],
                    resources: [.copy("Fixtures")], swiftSettings: v5),
    ]
)
