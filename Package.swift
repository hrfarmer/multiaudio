// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MultiAudio",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.7.0"),
    ],
    targets: [
        .target(
            name: "MultiAudioCore",
            dependencies: [.product(name: "BigInt", package: "BigInt")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MultiAudio",
            dependencies: ["MultiAudioCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "aptest",
            dependencies: ["MultiAudioCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
