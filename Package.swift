// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SAKMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SAKMac",
            path: "Sources/SAKMac"
        )
    ]
)
