import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore
@testable import KumoneTCA
import XCTest

@MainActor
final class SettingsFeatureTests: XCTestCase {
    /// `onAppear` rehydrates everything; assert the full resulting state.
    func testOnAppearRehydrates() async {
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.persistence.stringForKey = { key in
                switch key {
                case SettingsFeature.Keys.quality: return AudioQuality.lossless.rawValue
                case SettingsFeature.Keys.appearance: return AppAppearance.dark.rawValue
                case SettingsFeature.Keys.nowPlayingMode: return NowPlayingMode.vinyl.rawValue
                case SettingsFeature.Keys.annotation: return LyricsAnnotation.furigana.rawValue
                default: return nil
                }
            }
            $0.persistence.boolForKey = { key in
                switch key {
                case SettingsFeature.Keys.showTranslation: return true
                case SettingsFeature.Keys.verbatimLyrics: return true
                case SettingsFeature.Keys.unblock: return true
                case SettingsFeature.Keys.autoCheckUpdates: return true
                case SettingsFeature.Keys.desktopLyrics: return true
                case SettingsFeature.Keys.desktopLyricsCentered: return true
                case SettingsFeature.Keys.mainWindowAmbientBackground: return true
                default: return false
                }
            }
            $0.persistence.doubleForKey = { _ in 1.25 }
        }
        await store.send(.onAppear) {
            $0.isLoaded = true
            $0.audioQuality = .lossless
            $0.appearance = .dark
            $0.nowPlayingMode = .vinyl
            $0.showLyricsTranslation = true
            $0.lyricsAnnotation = .furigana
            $0.verbatimLyrics = true
            $0.enableUnblock = true
            $0.autoCheckUpdates = true
            $0.showDesktopLyrics = true
            $0.desktopLyricsCentered = true
            $0.showMainWindowAmbientBackground = true
            $0.mainWindowAmbientBackgroundIntensity = 1.25
        }
    }

    /// The pre-1.0 on/off romaji toggle carries over to the annotation enum.
    func testRomajiLegacyKeyMigratesToAnnotation() async {
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.persistence.boolForKey = { $0 == SettingsFeature.Keys.showRomaji }
            $0.persistence.stringForKey = { _ in nil }
            $0.persistence.doubleForKey = { _ in 0 }
        }
        await store.send(.onAppear) {
            $0.isLoaded = true
            $0.showLyricsTranslation = false
            $0.lyricsAnnotation = .romaji
            $0.verbatimLyrics = false
            $0.enableUnblock = false
            $0.autoCheckUpdates = false
            $0.showMainWindowAmbientBackground = false
        }
    }

    func testSettingPersists() async {
        nonisolated(unsafe) var written: String?
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.persistence.setString = { value, key in
                if key == SettingsFeature.Keys.quality { written = value }
            }
        }
        await store.send(.setAudioQuality(.hires)) {
            $0.audioQuality = .hires
        }
        XCTAssertEqual(written, AudioQuality.hires.rawValue)
    }

    func testIntensityClampsToRange() async {
        nonisolated(unsafe) var written: Double?
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.persistence.setDouble = { value, _ in written = value }
        }
        await store.send(.setMainWindowAmbientBackgroundIntensity(5)) {
            $0.mainWindowAmbientBackgroundIntensity = SettingsFeature.intensityRange.upperBound
        }
        XCTAssertEqual(written, SettingsFeature.intensityRange.upperBound)
    }

    func testOnAppearOnlyOnce() async {
        let store = TestStore(initialState: SettingsFeature.State(isLoaded: true)) {
            SettingsFeature()
        } withDependencies: {
            $0.persistence.stringForKey = { _ in AudioQuality.lossless.rawValue }
        }
        // Already loaded: no state change, no reads.
        await store.send(.onAppear)
    }

    func testAllDisplaySettersPersistTheirValues() async {
        nonisolated(unsafe) var strings: [String: String] = [:]
        nonisolated(unsafe) var bools: [String: Bool] = [:]
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.persistence.setString = { strings[$1] = $0 }
            $0.persistence.setBool = { bools[$1] = $0 }
        }
        await store.send(.setAppearance(.dark)) { $0.appearance = .dark }
        await store.send(.setNowPlayingMode(.vinyl)) { $0.nowPlayingMode = .vinyl }
        await store.send(.setShowLyricsTranslation(false)) { $0.showLyricsTranslation = false }
        await store.send(.setLyricsAnnotation(.furigana)) { $0.lyricsAnnotation = .furigana }
        await store.send(.setVerbatimLyrics(false)) { $0.verbatimLyrics = false }
        await store.send(.setShowDesktopLyrics(true)) { $0.showDesktopLyrics = true }
        await store.send(.setDesktopLyricsCentered(true)) { $0.desktopLyricsCentered = true }
        await store.send(.setShowMainWindowAmbientBackground(false)) {
            $0.showMainWindowAmbientBackground = false
        }
        XCTAssertEqual(strings, [
            SettingsFeature.Keys.appearance: AppAppearance.dark.rawValue,
            SettingsFeature.Keys.nowPlayingMode: NowPlayingMode.vinyl.rawValue,
            SettingsFeature.Keys.annotation: LyricsAnnotation.furigana.rawValue,
        ])
        XCTAssertEqual(bools, [
            SettingsFeature.Keys.showTranslation: false,
            SettingsFeature.Keys.verbatimLyrics: false,
            SettingsFeature.Keys.desktopLyrics: true,
            SettingsFeature.Keys.desktopLyricsCentered: true,
            SettingsFeature.Keys.mainWindowAmbientBackground: false,
        ])
    }

    func testInvalidAnnotationFallsBackToDisabledLegacyPreference() async {
        let store = TestStore(initialState: SettingsFeature.State()) {
            SettingsFeature()
        } withDependencies: {
            $0.persistence.stringForKey = { _ in "invalid" }
            $0.persistence.boolForKey = { _ in false }
            $0.persistence.doubleForKey = { _ in 0 }
        }
        await store.send(.onAppear) {
            $0.isLoaded = true
            $0.showLyricsTranslation = false
            $0.verbatimLyrics = false
            $0.enableUnblock = false
            // The mock returns a non-nil string, so the filter reads the
            // mocked `boolForKey` (false) instead of the default-on value.
            $0.recentFilterEnabled = false
            $0.autoCheckUpdates = false
            $0.showMainWindowAmbientBackground = false
        }
        XCTAssertEqual(store.state.lyricsAnnotation, .off)
    }
}
