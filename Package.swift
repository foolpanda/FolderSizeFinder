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
            path: "Sources/FolderSize",
            resources: [
                .copy("Resources/AppIcon.png") // 程序图标:bundle 走 .icns,裸二进制运行时加载
            ]
        ),
        .testTarget(
            name: "FolderSizeTests",
            dependencies: ["FolderSize"],
            path: "Tests/FolderSizeTests"
        )
    ]
)
