// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DuoPlayer",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "DuoPlayer",
            exclude: ["Info.plist"],
            // Embed Info.plist so macOS shows "Duo Player" (not "(null)") in the sign-in prompt.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                           "-Xlinker", "__info_plist", "-Xlinker", "Sources/DuoPlayer/Info.plist"])]
        ),
        .testTarget(name: "DuoPlayerTests", dependencies: ["DuoPlayer"]),
    ]
)
