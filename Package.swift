// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeTray",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeTray",
            path: ".",
            sources: ["ClaudeTray.swift"]
        )
    ]
)
