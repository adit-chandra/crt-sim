// swift-tools-version: 6.2
import PackageDescription

let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "CRTPlayer",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "CRTCore", targets: ["CRTCore"]),
        .library(name: "CRTPreferences", targets: ["CRTPreferences"]),
    ],
    targets: [
        .target(name: "CRTCore", path: "Shared/CRTCore"),
        .target(name: "CRTPreferences", dependencies: ["CRTCore"], path: "Shared/CRTPreferences"),
        .systemLibrary(name: "CMpv", path: "Apps/macOS/CMpv", pkgConfig: "mpv", providers: [.brew(["mpv"])]),
        .target(name: "MPVBridge", dependencies: ["CMpv"], path: "Apps/macOS/MPVBridge",
                cSettings: [.define("GL_SILENCE_DEPRECATION")], linkerSettings: [
            .linkedFramework("OpenGL"), .linkedFramework("CoreVideo"),
            .linkedFramework("IOSurface"),
        ]),
        .target(name: "MediaPlayback", dependencies: ["CMpv", "MPVBridge"], path: "Apps/macOS/MediaPlayback",
                swiftSettings: mainActorByDefault),
        .executableTarget(
            name: "CRTPlayer",
            dependencies: ["CRTCore", "CRTPreferences", "MediaPlayback"],
            path: "Apps/macOS/CRTPlayer",
            exclude: ["Info.plist"],
            swiftSettings: mainActorByDefault,
            linkerSettings: [
                // Embed Info.plist so `swift run` behaves like the bundled app (document types, name).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "\(Context.packageDirectory)/Apps/macOS/CRTPlayer/Info.plist",
                ]),
            ]
        ),
        .executableTarget(
            name: "crt-snapshot",
            dependencies: ["CRTCore"],
            path: "Tools/crt-snapshot",
            swiftSettings: mainActorByDefault
        ),
        .testTarget(name: "CRTPlayerTests", dependencies: ["CRTPlayer"],
                    path: "Tests",
                    exclude: ["iOS", "macOS/MediaPlaybackTests"],
                    sources: ["macOS/CRTPlayerTests"],
                    resources: [.copy("Fixtures")],
                    swiftSettings: mainActorByDefault),
        .testTarget(name: "MediaPlaybackTests", dependencies: ["MediaPlayback", "CRTCore"],
                    path: "Tests",
                    exclude: ["iOS", "macOS/CRTPlayerTests"],
                    sources: ["macOS/MediaPlaybackTests"],
                    resources: [.copy("Fixtures")],
                    swiftSettings: mainActorByDefault),
    ]
)
