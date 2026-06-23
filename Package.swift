// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeTray",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeTray",
            path: ".",
            exclude: ["LICENSE", "README.md", "Info.plist", "build-app.sh", "make-icon.swift", "images", "dist", "AppIcon.icns"],
            sources: ["ClaudeTray.swift"]
        )
    ]
)
