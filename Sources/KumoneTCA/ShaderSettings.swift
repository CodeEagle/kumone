import Combine
import Foundation

/// The switches that shape how every shader surface behaves.
///
/// Three different hosts drive shaders — the full-screen visualizer, the
/// now-playing backdrop and the AppKit shell's window backdrop — and all three
/// have to agree on these. `@AppStorage` only reaches the storage of the view
/// that declares it, so the setting lives here instead: the SwiftUI views
/// observe it, and the AppKit shell subscribes to its publisher.
@MainActor
public final class ShaderSettings: ObservableObject {
    public static let shared = ShaderSettings()

    /// Whether the shader reacts to the live PCM analysis.
    ///
    /// On: the host feeds the renderer the analysed band levels, beat envelope
    /// and loudness, and the shaders modulate their own parameters with them.
    /// Off: the host feeds silence instead, so every shader keeps running on
    /// its own time-driven motion — the visuals never freeze or go black, they
    /// simply stop following the music.
    @Published public var pcmSyncEnabled: Bool {
        didSet { defaults.set(pcmSyncEnabled, forKey: Keys.pcmSyncEnabled) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // On by default: the audio path is part of what a shader does now, and
        // a first-run user should see the music drive the visuals.
        self.pcmSyncEnabled = defaults.object(forKey: Keys.pcmSyncEnabled) as? Bool ?? true
    }

    private enum Keys {
        static let pcmSyncEnabled = "visualizer.pcmSyncEnabled"
    }
}
