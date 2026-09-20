import ComposableArchitecture
import Dependencies
@testable import KumoneCore
import XCTest

@MainActor
final class AppFeatureTests: XCTestCase {
    /// `UserProfile` has a Decodable-only conformance, so build one from JSON.
    nonisolated private static func makeProfile(_ nickname: String = "tester") -> UserProfile {
        let json = "{\"userId\": 42, \"nickname\": \"\(nickname)\", \"vipType\": 11}"
        return try! JSONDecoder().decode(UserProfile.self, from: Data(json.utf8))
    }

    /// The account bootstrap chain: cookie check → profile → library refresh.
    private func configureAccount(_ deps: inout DependencyValues) {
        deps.session.hasAuthCookie = { true }
        deps.persistence.doubleForKey = { _ in 0 }
        deps.persistence.setDouble = { _, _ in }
        deps.netease.refreshLogin = {}
        deps.netease.userAccount = { Self.makeProfile() }
        deps.netease.userPlaylists = { _, _, _ in [] }
        deps.netease.likedTrackIDs = { _ in [] }
    }

    // MARK: - Player → toasts

    func testPlayerToastIsForwardedToTheToastOverlay() async {
        let toastID = UUID()
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.uuid = .init { toastID }
        }
        await store.send(.player(.toast("无法播放")))
        await store.receive(.toasts(.presented("无法播放"))) {
            $0.toasts.current = Toast(id: toastID, message: "无法播放")
        }
        await store.receive(.toasts(.autoDismissTimerCompleted(toastID))) {
            $0.toasts.current = nil
        }
    }

    // MARK: - Settings → player mirrors

    func testSettingsAreMirroredIntoThePlayer() async {
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            $0.persistence.setBool = { _, _ in }
            $0.persistence.setString = { _, _ in }
        }
        await store.send(.settings(.setAudioQuality(.lossless))) {
            $0.settings.audioQuality = .lossless
            $0.player.audioQuality = .lossless
        }
        await store.send(.settings(.setEnableUnblock(false))) {
            $0.settings.enableUnblock = false
            $0.player.enableUnblock = false
        }
    }

    // MARK: - Account → player mirrors

    func testBootstrapMirrorsLoginIntoThePlayerAndWelcomesTheUser() async {
        let toastID = UUID()
        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        } withDependencies: {
            configureAccount(&$0)
            $0.continuousClock = ImmediateClock()
            $0.uuid = .init { toastID }
        }
        await store.send(.account(.bootstrap)) {
            $0.account.hasAuthCookie = true
            $0.account.isBootstrapping = true
        }
        await store.receive(.account(.bootstrapResponse(.success(Self.makeProfile())))) {
            $0.account.profile = Self.makeProfile()
            $0.account.isBootstrapped = true
            $0.account.isBootstrapping = false
            $0.player.isLoggedIn = true
            $0.player.vipType = 11
        }
        // Bootstrap chains into a library refresh; the mirror is already live.
        await store.receive(.account(.refreshLibrary))
        // "欢迎回来" fires once the profile is known.
        await store.receive(.toasts(.presented("欢迎回来，tester"))) {
            $0.toasts.current = Toast(id: toastID, message: "欢迎回来，tester")
        }
        await store.receive(.account(.libraryResponse(.success(
            AccountFeature.LibraryRefresh(playlists: [], likedTrackIDs: [])
        ))))
        await store.receive(.toasts(.autoDismissTimerCompleted(toastID))) {
            $0.toasts.current = nil
        }
    }

    func testLogoutDropsThePlayerLoginMirror() async {
        var state = AppFeature.State()
        state.account.hasAuthCookie = true
        state.account.profile = Self.makeProfile()
        state.player.isLoggedIn = true
        state.player.vipType = 11
        let store = TestStore(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.session.clearAuth = {}
        }
        await store.send(.account(.logoutResponse)) {
            $0.account.hasAuthCookie = false
            $0.account.profile = nil
            $0.player.isLoggedIn = false
            $0.player.vipType = 0
        }
    }
}
