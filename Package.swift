// swift-tools-version: 6.2
import PackageDescription

let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "CRTPlayer",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "CRTCore"),
        .executableTarget(
            name: "CRTPlayer",
            dependencies: ["CRTCore"],
            exclude: ["Info.plist"],
            swiftSettings: mainActorByDefault,
            linkerSettings: [
                // Embed Info.plist so `swift run` behaves like the bundled app (document types, name).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Sources/CRTPlayer/Info.plist",
                ]),
            ]
        ),
        .executableTarget(
            name: "crt-snapshot",
            dependencies: ["CRTCore"],
            swiftSettings: mainActorByDefault
        ),
    ]
)
