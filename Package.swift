// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppleMusicVesktopRPC",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "apple-music-vesktop-rpc", targets: ["AppleMusicVesktopRPC"])
    ],
    targets: [
        .executableTarget(name: "AppleMusicVesktopRPC")
    ]
)
