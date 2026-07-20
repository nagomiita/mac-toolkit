// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacToolkit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacToolkit",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
