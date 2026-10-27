// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "PhotoShuffle",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "PhotoShuffle",
            path: "Sources/PhotoShuffle",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
