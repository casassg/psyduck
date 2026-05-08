// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "gh-prs",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "gh-prs",
            path: "Sources",
            exclude: ["Resources/AppIcon.icns"],
            resources: [
                .copy("Resources/logo.png"),
            ]
        ),
    ]
)
