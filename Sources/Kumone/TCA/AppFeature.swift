import ComposableArchitecture
import Dependencies
import Foundation

/// The composition root. Child features own their state and logic; this reducer
/// only wires cross-feature effects: login → bootstrap, failures → toasts.
///
/// `player` and the content features (home / explore / search / detail pages)
/// land here as they are ported.
@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        var toasts = ToastsFeature.State()
        var settings = SettingsFeature.State()
        var account = AccountFeature.State()
        var login = LoginFeature.State()
        var isLoginPresented = false
    }

    enum Action: Equatable {
        case toasts(ToastsFeature.Action)
        case settings(SettingsFeature.Action)
        case account(AccountFeature.Action)
        case login(LoginFeature.Action)

        case presentLogin
        case dismissLogin
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.toasts, action: \.toasts) { ToastsFeature() }
        Scope(state: \.settings, action: \.settings) { SettingsFeature() }
        Scope(state: \.account, action: \.account) { AccountFeature() }
        Scope(state: \.login, action: \.login) { LoginFeature() }

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

            default:
                return .none
            }
        }
    }
}
