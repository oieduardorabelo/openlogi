// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OpenLogi",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenLogi", targets: ["OpenLogi"])
    ],
    targets: [
        .executableTarget(
            name: "OpenLogi",
            resources: [.process("Resources/Brand/DMSans-Variable.ttf")]
        ),
        .testTarget(name: "OpenLogiTests", dependencies: ["OpenLogi"])
    ],
    swiftLanguageModes: [.v5]
)
