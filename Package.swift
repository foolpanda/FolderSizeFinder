// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FolderSize",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "FolderSize",
            path: "Sources/FolderSize"
        ),
        .testTarget(
            name: "FolderSizeTests",
            dependencies: ["FolderSize"],
            path: "Tests/FolderSizeTests"
        )
    ]
)
