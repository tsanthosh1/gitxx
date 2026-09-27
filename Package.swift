// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "GitXX",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "GitXX",
            path: "Sources"
        )
    ]
)
