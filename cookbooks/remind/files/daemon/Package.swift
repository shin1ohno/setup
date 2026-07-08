// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "remindd",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "remindd",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist (NSRemindersFullAccessUsageDescription) into the
                // binary so the macOS 14+ full-access TCC request works for a bare
                // executable. Path is resolved relative to the build CWD (package root).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/remindd/Info.plist",
                ]),
            ]
        ),
    ]
)
