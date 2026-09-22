// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kumone",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("15.0"), .iOS("17.0")],
    products: [
        .executable(name: "Kumone", targets: ["KumoneLauncher"]),
        .library(name: "KumoneCore", targets: ["KumoneCore"]),
        .plugin(name: "KumoneMetalCompiler", targets: ["KumoneMetalCompiler"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.2"),
        // The playback engine: a self-contained AudioUnit/AVAudioEngine player
        // (streaming decoder, EQ, gapless, Now Playing, remote commands) from the
        // APlay repository. 2.1.1 fixes the release-build silence in the
        // AVAudioEngine manual-rendering path, so the upstream package is used
        // directly (no vendored -Onone copy needed). 2.1.3 makes macOS publish
        // Now Playing info + playback state, so the system routes headset and
        // media-key events to the app. 2.1.4 adds the realtime PCM tap
        // (`APlay.pcmTap`) that drives the audio spectrum behind the shaders.
        .package(url: "https://github.com/CodeEagle/APlay.git", from: "2.1.4"),
    ],
    targets: [
        // Compiles the .metal sources in Sources/KumoneShaders/Shaders into a
        // single default.metallib with the shared header on the include path.
        // SwiftPM compiles recognized .metal itself but gives no way to share a
        // header between files, so the target excludes the shader directory and
        // this plugin compiles them instead.
        .plugin(
            name: "KumoneMetalCompiler",
            capability: .buildTool()
        ),
        // Pure-Metal target: the shaders and their shared types live here, kept
        // out of Swift so the shader-side layout is declared once.
        .target(
            name: "KumoneShaders",
            exclude: ["Shaders"],
            publicHeadersPath: "include",
            plugins: ["KumoneMetalCompiler"]
        ),
        .target(
            name: "KumoneCore",
            dependencies: [
                "KumoneShaders",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "APlay", package: "APlay"),
            ],
            path: "Sources/Kumone",
            exclude: ["Resources"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "KumoneLauncher",
            dependencies: [
                "KumoneCore",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/KumoneLauncher",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                // Sparkle.framework is embedded in Contents/Frameworks by Scripts/build-app.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "KumoneCoreTests",
            dependencies: ["KumoneCore", "KumoneShaders"],
            path: "Tests/KumoneCoreTests"
        ),
    ]
)
