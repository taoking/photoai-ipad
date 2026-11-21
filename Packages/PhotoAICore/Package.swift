// swift-tools-version: 6.2
import PackageDescription

// 核心层：iPad 应用用，也能在 Mac 上 `swift test`。
let package = Package(
    name: "PhotoAICore",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(name: "PhotoAICore", targets: ["PhotoAICore"])
    ],
    targets: [
        .target(
            name: "PhotoAICore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "PhotoAICoreTests", dependencies: ["PhotoAICore"])
    ]
)
