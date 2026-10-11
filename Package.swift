// swift-tools-version:5.9
import PackageDescription
import Foundation

// Embed Info.plist in the binary so camera access works even when run from Xcode / `swift run`.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Info.plist").path

let package = Package(
    name: "UniqueAVCountdown",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "UniqueAVCountdown",
            path: "Sources/UniqueAVCountdown",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreMIDI"),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        )
    ]
)
