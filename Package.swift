// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CerealNotes",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "CerealNotes",
            path: "Sources/CerealNotes",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/CerealNotes/Info.plist"
                ])
            ]
        )
    ]
)
