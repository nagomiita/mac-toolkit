// swift-tools-version: 5.9

// iPad 側ビューアアプリ。Swift Playgrounds（iPad / Mac）でこのフォルダを
// 開けばそのまま実機で実行できる。Xcode でも開ける。
// ルートの `swift build` からは意図的に外してある（AppleProductTypes は
// macOS 向けの通常ビルドでは解決できない）。
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "MacToolkitDisplay",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "MacToolkit Display",
            targets: ["AppModule"],
            bundleIdentifier: "com.nagomiita.mac-toolkit.display",
            displayVersion: "0.1.0",
            bundleVersion: "1",
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft
            ],
            capabilities: [
                .localNetwork(
                    purposeString: "同じネットワーク内の Mac を探して画面の映像を受信します。",
                    bonjourServiceTypes: ["_mactoolkit-display._tcp"]
                )
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "Sources"
        )
    ]
)
