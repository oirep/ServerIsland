// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ServerIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ServerIsland",
            path: "Sources/ServerIsland"
        )
    ]
)
