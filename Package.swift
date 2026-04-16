// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CerealNotes",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.6"),
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
            dependencies: [
                "SystemAudioTap",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/CerealNotes",
            exclude: ["Info.plist", "CerealNotes.entitlements"]
        ),
        .testTarget(
            name: "AudioPipelineTests",
            dependencies: [
                "SystemAudioTap",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Tests/AudioPipelineTests",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        )
    ]
)
