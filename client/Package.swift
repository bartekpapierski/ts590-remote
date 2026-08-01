// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RemoteRig",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "RemoteRig", targets: ["RemoteRig"])
    ],
    targets: [
        .target(
            name: "OpusC",
            path: "Sources/OpusC",
            cSettings: [.unsafeFlags(["-I/opt/homebrew/include"])],
            linkerSettings: [.unsafeFlags(["-L/opt/homebrew/lib", "-lopus"])]
        ),
        .target(
            name: "OpusWrapper",
            dependencies: ["OpusC"],
            swiftSettings: [.unsafeFlags(["-Xcc", "-I/opt/homebrew/include"])]
        ),
        .executableTarget(
            name: "RemoteRig",
            dependencies: ["OpusWrapper"],
            path: "Sources/RemoteRig",
            swiftSettings: [.unsafeFlags(["-Xcc", "-I/opt/homebrew/include"])]
        ),
        .testTarget(
            name: "RemoteRigTests",
            dependencies: ["RemoteRig"],
            path: "Tests/RemoteRigTests",
            swiftSettings: [.unsafeFlags(["-Xcc", "-I/opt/homebrew/include"])]
        )
    ]
)
