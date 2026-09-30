// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "JichangVerification", platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "5.4.0"), .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(name: "JichangCore", dependencies: ["Yams", "ZIPFoundation"], path: "JichangMac",
                exclude: ["Assets.xcassets", "JichangMacApp.swift"]),
        .testTarget(name: "JichangCoreTests", dependencies: ["JichangCore"], path: "Tests")
    ])
