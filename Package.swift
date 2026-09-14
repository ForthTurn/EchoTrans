// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "EchoTrans",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "EchoTrans",
            path: "Sources/EchoTrans",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
