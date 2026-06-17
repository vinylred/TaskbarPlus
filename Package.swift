// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TaskbarPlus",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TaskbarPlus", targets: ["TaskbarPlus"])
    ],
    targets: [
        // C shim that declares the private CGS / SkyLight symbols.
        // No implementation — symbols resolve at link time against SkyLight.framework.
        .target(
            name: "CSkyLight"
        ),
        .executableTarget(
            name: "TaskbarPlus",
            dependencies: ["CSkyLight"],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/System/Library/PrivateFrameworks",
                    "-framework", "SkyLight",
                ])
            ]
        ),
    ]
)
