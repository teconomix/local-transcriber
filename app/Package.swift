// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Transcriber", path: "Sources/Transcriber")
    ]
)
