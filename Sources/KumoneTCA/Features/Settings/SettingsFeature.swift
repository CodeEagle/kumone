import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore

/// Every persisted user preference, as a single source of truth.
///
/// Replaces `SettingsManager` (the `ObservableObject` singleton). The key
/// strings are identical so existing installs keep their preferences.
@Reducer
public struct SettingsFeature {
    @ObservableState
    public struct State: Equatable {
        public var audioQuality: AudioQuality = .exhigh
        public var appearance: AppAppearance = .auto
        public var nowPlayingMode: NowPlayingMode = .immersive
        public var showLyricsTranslation = true
        /// Reading shown above Japanese lyrics.
        public var lyricsAnnotation: LyricsAnnotation = .off
        /// Karaoke word-by-word highlighting when yrc is available.
        public var verbatimLyrics = true
        /// Resolve gray tracks from third-party sources.
        public var enableUnblock = true
        public var recentFilterEnabled = true
        public var recentFilterDays = 30
        public var autoCheckUpdates = true
        public var showDesktopLyrics = false
        public var desktopLyricsCentered = false
        public var showMainWindowAmbientBackground = true
        public var mainWindowAmbientBackgroundIntensity = 1.0
        /// Flips once `onAppear` has rehydrated from disk.
        public var isLoaded = false
    }

    public enum Action: Equatable {
        case onAppear
        case setAudioQuality(AudioQuality)
        case setAppearance(AppAppearance)
        case setNowPlayingMode(NowPlayingMode)
        case setShowLyricsTranslation(Bool)
        case setLyricsAnnotation(LyricsAnnotation)
        case setVerbatimLyrics(Bool)
        case setEnableUnblock(Bool)
        case setRecentFilterEnabled(Bool)
        case setRecentFilterDays(Int)
        case setAutoCheckUpdates(Bool)
        case setShowDesktopLyrics(Bool)
        case setDesktopLyricsCentered(Bool)
        case setShowMainWindowAmbientBackground(Bool)
        case setMainWindowAmbientBackgroundIntensity(Double)
        /// The app menu / Settings "检查更新…" button.
        case checkForUpdates
    }

    @Dependency(\.persistence) public var persistence

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                guard !state.isLoaded else { return .none }
                state.isLoaded = true
                let p = persistence

                state.audioQuality = p.stringForKey(Keys.quality).flatMap(AudioQuality.init) ?? .exhigh
                state.appearance = p.stringForKey(Keys.appearance).flatMap(AppAppearance.init) ?? .auto
                state.nowPlayingMode = p.stringForKey(Keys.nowPlayingMode).flatMap(NowPlayingMode.init) ?? .immersive
                state.showLyricsTranslation = p.boolForKey(Keys.showTranslation)
                // Carry over the pre-1.0 on/off romaji toggle for anyone who had it on.
                state.lyricsAnnotation = p.stringForKey(Keys.annotation).flatMap(LyricsAnnotation.init)
                    ?? (p.boolForKey(Keys.showRomaji) ? .romaji : .off)
                state.verbatimLyrics = p.boolForKey(Keys.verbatimLyrics)
                state.enableUnblock = p.boolForKey(Keys.unblock)
                // UserDefaults exposes stored Bool values through stringForKey as well.
                state.recentFilterEnabled = p.stringForKey(Keys.recentFilterEnabled) == nil
                    ? true : p.boolForKey(Keys.recentFilterEnabled)
                let recentFilterDays = p.doubleForKey(Keys.recentFilterDays)
                state.recentFilterDays = [7, 14, 30, 90].first { Double($0) == recentFilterDays } ?? 30
                state.autoCheckUpdates = p.boolForKey(Keys.autoCheckUpdates)
                state.showDesktopLyrics = p.boolForKey(Keys.desktopLyrics)
                state.desktopLyricsCentered = p.boolForKey(Keys.desktopLyricsCentered)
                state.showMainWindowAmbientBackground = p.boolForKey(Keys.mainWindowAmbientBackground)
                let stored = p.doubleForKey(Keys.mainWindowAmbientBackgroundIntensity)
                state.mainWindowAmbientBackgroundIntensity = min(
                    max(stored.isZero ? 1 : stored, Self.intensityRange.lowerBound),
                    Self.intensityRange.upperBound
                )
                return .none

            case let .setAudioQuality(value):
                state.audioQuality = value
                persistence.setString(value.rawValue, Keys.quality)
                return .none

            case let .setAppearance(value):
                state.appearance = value
                persistence.setString(value.rawValue, Keys.appearance)
                return .none

            case let .setNowPlayingMode(value):
                state.nowPlayingMode = value
                persistence.setString(value.rawValue, Keys.nowPlayingMode)
                return .none

            case let .setShowLyricsTranslation(value):
                state.showLyricsTranslation = value
                persistence.setBool(value, Keys.showTranslation)
                return .none

            case let .setLyricsAnnotation(value):
                state.lyricsAnnotation = value
                persistence.setString(value.rawValue, Keys.annotation)
                return .none

            case let .setVerbatimLyrics(value):
                state.verbatimLyrics = value
                persistence.setBool(value, Keys.verbatimLyrics)
                return .none

            case let .setEnableUnblock(value):
                state.enableUnblock = value
                persistence.setBool(value, Keys.unblock)
                return .none

            case let .setRecentFilterEnabled(value):
                state.recentFilterEnabled = value
                persistence.setBool(value, Keys.recentFilterEnabled)
                return .none

            case let .setRecentFilterDays(value):
                state.recentFilterDays = value
                persistence.setDouble(Double(value), Keys.recentFilterDays)
                return .none

            case let .setAutoCheckUpdates(value):
                state.autoCheckUpdates = value
                persistence.setBool(value, Keys.autoCheckUpdates)
                return .none

            // Routed to UpdaterFeature by AppFeature.
            case .checkForUpdates:
                return .none
            case let .setShowDesktopLyrics(value):
                state.showDesktopLyrics = value
                persistence.setBool(value, Keys.desktopLyrics)
                return .none

            case let .setDesktopLyricsCentered(value):
                state.desktopLyricsCentered = value
                persistence.setBool(value, Keys.desktopLyricsCentered)
                return .none

            case let .setShowMainWindowAmbientBackground(value):
                state.showMainWindowAmbientBackground = value
                persistence.setBool(value, Keys.mainWindowAmbientBackground)
                return .none

            case let .setMainWindowAmbientBackgroundIntensity(value):
                state.mainWindowAmbientBackgroundIntensity = min(
                    max(value, Self.intensityRange.lowerBound),
                    Self.intensityRange.upperBound
                )
                persistence.setDouble(
                    state.mainWindowAmbientBackgroundIntensity, Keys.mainWindowAmbientBackgroundIntensity
                )
                return .none
            }
        }
    }
}

extension SettingsFeature {
    /// Must stay byte-identical to the old `SettingsManager` keys.
    public enum Keys {
        public static let quality = "settings.audioQuality"
        public static let appearance = "settings.appearance"
        public static let nowPlayingMode = "settings.nowPlayingMode"
        public static let showTranslation = "settings.showLyricsTranslation"
        public static let showRomaji = "settings.showLyricsRomaji"
        public static let annotation = "settings.lyricsAnnotation"
        public static let verbatimLyrics = "settings.verbatimLyrics"
        public static let unblock = "settings.enableUnblock"
        public static let recentFilterEnabled = "fm.recentFilterEnabled"
        public static let recentFilterDays = "fm.recentFilterDays"
        public static let autoCheckUpdates = "settings.autoCheckUpdates"
        public static let desktopLyrics = "settings.showDesktopLyrics"
        public static let desktopLyricsCentered = "settings.desktopLyricsCentered"
        public static let mainWindowAmbientBackground = "settings.showMainWindowAmbientBackground"
        public static let mainWindowAmbientBackgroundIntensity = "settings.mainWindowAmbientBackgroundIntensity"
    }

    public static let intensityRange = 0.5...1.5
}
