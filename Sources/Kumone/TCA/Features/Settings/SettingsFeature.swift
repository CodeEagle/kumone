import ComposableArchitecture
import Dependencies
import Foundation
import SwiftUI

/// Every persisted user preference, as a single source of truth.
///
/// Replaces `SettingsManager` (the `ObservableObject` singleton). The key
/// strings are identical so existing installs keep their preferences.
@Reducer
struct SettingsFeature {
    @ObservableState
    struct State: Equatable {
        var audioQuality: AudioQuality = .exhigh
        var appearance: AppAppearance = .auto
        var nowPlayingMode: NowPlayingMode = .immersive
        var showLyricsTranslation = true
        /// Reading shown above Japanese lyrics.
        var lyricsAnnotation: LyricsAnnotation = .off
        /// Karaoke word-by-word highlighting when yrc is available.
        var verbatimLyrics = true
        /// Resolve gray tracks from third-party sources.
        var enableUnblock = true
        var autoCheckUpdates = true
        var showDesktopLyrics = false
        var desktopLyricsCentered = false
        var showMainWindowAmbientBackground = true
        var mainWindowAmbientBackgroundIntensity = 1.0
        /// Flips once `onAppear` has rehydrated from disk.
        var isLoaded = false
    }

    enum Action: Equatable {
        case onAppear
        case setAudioQuality(AudioQuality)
        case setAppearance(AppAppearance)
        case setNowPlayingMode(NowPlayingMode)
        case setShowLyricsTranslation(Bool)
        case setLyricsAnnotation(LyricsAnnotation)
        case setVerbatimLyrics(Bool)
        case setEnableUnblock(Bool)
        case setAutoCheckUpdates(Bool)
        case setShowDesktopLyrics(Bool)
        case setDesktopLyricsCentered(Bool)
        case setShowMainWindowAmbientBackground(Bool)
        case setMainWindowAmbientBackgroundIntensity(Double)
    }

    @Dependency(\.persistence) var persistence

    var body: some ReducerOf<Self> {
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

            case let .setAutoCheckUpdates(value):
                state.autoCheckUpdates = value
                persistence.setBool(value, Keys.autoCheckUpdates)
                return .run { _ in
                    await MainActor.run {
                        #if os(macOS)
                        UpdaterManager.shared.setAutomaticChecks(value)
                        #endif
                    }
                }

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
    enum Keys {
        static let quality = "settings.audioQuality"
        static let appearance = "settings.appearance"
        static let nowPlayingMode = "settings.nowPlayingMode"
        static let showTranslation = "settings.showLyricsTranslation"
        static let showRomaji = "settings.showLyricsRomaji"
        static let annotation = "settings.lyricsAnnotation"
        static let verbatimLyrics = "settings.verbatimLyrics"
        static let unblock = "settings.enableUnblock"
        static let autoCheckUpdates = "settings.autoCheckUpdates"
        static let desktopLyrics = "settings.showDesktopLyrics"
        static let desktopLyricsCentered = "settings.desktopLyricsCentered"
        static let mainWindowAmbientBackground = "settings.showMainWindowAmbientBackground"
        static let mainWindowAmbientBackgroundIntensity = "settings.mainWindowAmbientBackgroundIntensity"
    }

    static let intensityRange = 0.5...1.5
}
