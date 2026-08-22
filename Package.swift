// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeatJSONTools",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "IconComposer",
            path: "IconComposer"
        ),
    ]
)
