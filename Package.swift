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
            path: "Sources/CerealNotes"
        )
    ]
)
