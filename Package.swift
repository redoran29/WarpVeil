// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WarpVeil",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "WarpVeil", path: "Sources")
    ]
)
