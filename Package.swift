// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProximusPasswords",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "ProximusKit", targets: ["ProximusKit"])],
    targets: [
        .binaryTarget(name: "ProximusCrypto", path: "Vendor/ProximusCrypto.xcframework"),
        .target(name: "ProximusKit", dependencies: ["ProximusCrypto"]),
        .testTarget(name: "ProximusKitTests", dependencies: ["ProximusKit"])
    ],
    swiftLanguageModes: [.v5]
)
