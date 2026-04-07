// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CerealNotes",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .target(
            name: "SystemAudioTap",
            path: "Sources/SystemAudioTap",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreAudio")
            ]
        ),
        .executableTarget(
            name: "CerealNotes",
            dependencies: ["SystemAudioTap"],
            path: "Sources/CerealNotes",
            exclude: ["Info.plist", "CerealNotes.entitlements"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/CerealNotes/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "AudioPipelineTests",
            dependencies: ["SystemAudioTap"],
            path: "Tests/AudioPipelineTests",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        )
    ]
)
