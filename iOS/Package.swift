// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xToolF1MVP",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "xToolF1Core", targets: ["xToolF1Core"]),
        .executable(name: "xToolF1App", targets: ["xToolF1App"]),
        .executable(name: "xtool-f1", targets: ["xtool-f1"])
    ],
    targets: [
        .target(name: "xToolF1Core"),
        .executableTarget(name: "xToolF1App", dependencies: ["xToolF1Core"], exclude: ["Info.plist", "Assets.xcassets"]),
        .executableTarget(name: "xtool-f1", dependencies: ["xToolF1Core"]),
        .testTarget(name: "xToolF1CoreTests", dependencies: ["xToolF1Core"])
    ]
)
