// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kumone",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("15.0"), .iOS("17.0"), .tvOS("17.0"), .visionOS("1.0")],
    products: [
        .executable(name: "Kumone", targets: ["KumoneMac"]),
        .executable(name: "ConfigShots", targets: ["ConfigShots"]),
        .library(name: "KumoneCore", targets: ["KumoneCore"]),
        .library(name: "KumoneShaders", targets: ["KumoneShaders"]),
        .library(name: "KumoneTCA", targets: ["KumoneTCA"]),
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
        // 2.1.5 drives autoplay resume off decoded audio instead of download
        // progress or a 0.5s delay, so a seek back to an early position (below
        // the old whole-stream threshold) no longer leaves the player paused.
        // 2.1.6–2.1.8: serialize the output-unit teardown and the composer-slot
        // preload takeover (render-time disposal race + leak), and play/prepare
        // can take Now Playing metadata so the card does not flash the previous
        // track while the host pushes its own copy.
        // 2.1.9: bound the two ring-buffer writer waits (50 ms with a closed
        // flag). Unbounded waits let a writer miss the single teardown signal,
        // park its thread forever, and pin the whole Composer set on its live
        // stack frame — the rapid-track-switching leak.
        .package(url: "https://github.com/CodeEagle/APlay.git", from: "2.1.9"),
        // YAML for the config-driven UI: screens and themes are user-editable
        // files, so the markup has to be friendly to humans first.
        .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
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
                .product(name: "APlay", package: "APlay"),
            ],
            path: "Sources/KumoneCore",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "KumoneUI",
            dependencies: [
                "KumoneCore",
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/KumoneUI",
            resources: [.copy("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "KumoneTCA",
            dependencies: [
                "KumoneCore",
                "KumoneUI",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            path: "Sources/KumoneTCA",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "ConfigShots",
            dependencies: ["KumoneUI"],
            path: "ConfigShots"
        ),
        .executableTarget(
            name: "KumoneMac",
            dependencies: [
                "KumoneCore",
                "KumoneTCA",
                "KumoneUI",
                .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
            ],
            path: "Apps/Mac",
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
            path: "Tests/KumoneCoreTests",
            swiftSettings: [
                // Matches KumoneCore/KumoneTCA: mock handlers in @Sendable
                // closures capture prebuilt non-Sendable fixtures, which is safe
                // because tests run single-threaded under TestStore.
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "KumoneTCATests",
            dependencies: ["KumoneCore", "KumoneTCA", "KumoneShaders"],
            path: "Tests/KumoneTCATests",
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "KumoneUITests",
            dependencies: ["KumoneUI"],
            path: "Tests/KumoneUITests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "KumoneMacTests",
            dependencies: ["KumoneCore", "KumoneTCA", "KumoneMac"],
            path: "Tests/KumoneMacTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
