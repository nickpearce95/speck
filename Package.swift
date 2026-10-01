// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Speck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Speck", path: "Sources/Speck")
    ]
)
