import ComposableArchitecture
import Dependencies
import Foundation

/// The composition root. Child features own their state and logic; this reducer
/// only wires cross-feature effects: login → bootstrap, failures → toasts, and
/// the settings/account values the player mirrors at resolve time.
///
/// The content features (home / explore / search / detail pages) land here as
/// they are ported.
@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        var toasts = ToastsFeature.State()
        var settings = SettingsFeature.State()
        var account = AccountFeature.State()
        var login = LoginFeature.State()
        var player = PlayerFeature.State()
        var isLoginPresented = false
    }

    enum Action: Equatable {
        case toasts(ToastsFeature.Action)
        case settings(SettingsFeature.Action)
        case account(AccountFeature.Action)
        case login(LoginFeature.Action)
        case player(PlayerFeature.Action)

        case presentLogin
        case dismissLogin
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.toasts, action: \.toasts) { ToastsFeature() }
        Scope(state: \.settings, action: \.settings) { SettingsFeature() }
        Scope(state: \.account, action: \.account) { AccountFeature() }
        Scope(state: \.login, action: \.login) { LoginFeature() }
        Scope(state: \.player, action: \.player) { PlayerFeature() }

        // Mirrors the values the player reads at URL-resolve time. Runs after the
        // child scopes so it sees the updated sibling state, and handles every
        // child action — the specific cases below return effects and would
        // otherwise skip the sync.
        Reduce { state, action in
            switch action {
            case .settings:
                state.player.audioQuality = state.settings.audioQuality
                state.player.enableUnblock = state.settings.enableUnblock
            case .account:
                state.player.isLoggedIn = state.account.isLoggedIn
                state.player.vipType = state.account.vipType
            default:
                break
            }
            return .none
        }

        Reduce { state, action in
            switch action {
            case .presentLogin:
                state.isLoginPresented = true
                return .send(.login(.onAppear))

            case .dismissLogin:
                state.isLoginPresented = false
                return .send(.login(.dismiss))

            // A login (QR or SMS) landed its cookies: load the account.
            case .login(.loginSucceeded):
                state.isLoginPresented = false
                return .send(.account(.bootstrap))

            // "欢迎回来" needs the profile, so it fires after bootstrap rather
            // than at login time.
            case let .account(.bootstrapResponse(.success(profile?))):
                let nickname = profile.nickname
                return .send(.toasts(.presented(String(localized: "欢迎回来，\(nickname)"))))

            case let .account(.toggleLikeFailed(error)):
                return .send(.toasts(.presented(error.message)))

            // The player surfaces this for the toast overlay; it carries no
            // state of its own.
            case let .player(.toast(message)):
                return .send(.toasts(.presented(message)))

            default:
                return .none
            }
        }
    }
}
