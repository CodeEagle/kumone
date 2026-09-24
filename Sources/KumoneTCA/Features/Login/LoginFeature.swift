import ComposableArchitecture
import Dependencies
import Foundation
import KumoneCore

/// The login sheet: QR-code scan or SMS verification code.
///
/// The QR flow holds a unikey, renders the code image from `qrLoginURL`, and
/// long-polls `/login/qrcode/client/login` until it is scanned, confirmed or
/// expires. Both flows funnel into `loginSucceeded`, which the app layer turns
/// into an account bootstrap.
@Reducer
public struct LoginFeature {
    @ObservableState
    public struct State: Equatable {
        public var mode: Mode = .qr
        public var phase: Phase = .loading
        /// The string rendered into the QR image (kept as a string so the view
        /// can regenerate the image and the state stays `Equatable` for tests).
        public var qrLoginURL: String?
        public var unikey: String?

        public var phone = ""
        public var code = ""
        public var smsCooldown = 0
        public var isSendingCode = false
        public var isLoggingIn = false
        /// Status line for the SMS section (sent / error).
        public var statusMessage: String?
    }

    public enum Mode: String, CaseIterable, Identifiable, Equatable {
        case qr = "扫码登录"
        case sms = "手机验证码"

        public var id: String { rawValue }
    }

    public enum Phase: Equatable {
        case loading
        case waiting          // QR code shown, not yet scanned (801)
        case scanned(String)  // scanned, awaiting confirm (802, nickname)
        case expired          // QR code timed out (800)
        case success          // logged in (803)
        case failed(String)
    }

    public enum Action: Equatable {
        case onAppear
        case dismiss
        case switchMode(Mode)

        case startQR
        case qrKeyResponse(Result<String, AppError>)
        case qrCheckResponse(Result<NeteaseAPI.QRCheckResponse, AppError>)
        case stopPolling

        case setPhone(String)
        case setCode(String)
        case sendCode
        case sendCodeResponse(Result<Bool, AppError>)
        case codeCooldownTick
        case loginWithCode
        case loginResponse(Result<Bool, AppError>)

        /// Both login paths converge here.
        case loginSucceeded
    }

    public enum CancelID: Hashable {
        case qrPoll
        case smsCooldown
    }

    @Dependency(\.netease) public var api
    @Dependency(\.musicProvider) public var provider
    @Dependency(\.continuousClock) public var clock

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                switch state.phase {
                case .loading, .failed:
                    // Fresh start, or a retry that keeps the existing key.
                    return .send(.startQR)
                default:
                    return .none
                }

            case .dismiss:
                return .send(.stopPolling)

            case let .switchMode(mode):
                state.mode = mode
                switch mode {
                case .qr:
                    if case .loading = state.phase { return .send(.startQR) }
                    return .none
                case .sms:
                    return .send(.stopPolling)
                }

            case .startQR:
                if state.unikey == nil {
                    state.phase = .loading
                    state.qrLoginURL = nil
                } else {
                    state.phase = .waiting
                }
                let reusingKey = state.unikey
                return .run { send in
                    do {
                        let key: String
                        if let reusingKey {
                            key = reusingKey
                        } else {
                            key = try await provider.qrKey()
                            await send(.qrKeyResponse(.success(key)))
                        }
                        var consecutiveErrors = 0
                        while !Task.isCancelled {
                            try await clock.sleep(for: .seconds(1.2))
                            do {
                                let check = try await api.qrCheck(unikey: key)
                                consecutiveErrors = 0
                                await send(.qrCheckResponse(.success(check)))
                            } catch {
                                consecutiveErrors += 1
                                if consecutiveErrors >= 15 {
                                    await send(.qrCheckResponse(.failure(AppError(wrapping: error))))
                                    return
                                }
                            }
                        }
                    } catch {
                        await send(.qrKeyResponse(.failure(AppError(wrapping: error))))
                    }
                }
                .cancellable(id: CancelID.qrPoll, cancelInFlight: true)

            case let .qrKeyResponse(.success(key)):
                state.unikey = key
                state.qrLoginURL = api.qrLoginURL(key)
                state.phase = .waiting
                return .none

            case let .qrKeyResponse(.failure(error)):
                state.phase = .failed(error.message)
                return .none

            case let .qrCheckResponse(.success(check)):
                switch check.code {
                case 800:
                    state.phase = .expired
                    state.unikey = nil
                    return .send(.stopPolling)
                case 801:
                    if case .waiting = state.phase {} else { state.phase = .waiting }
                    return .none
                case 802:
                    state.phase = .scanned(check.nickname ?? "")
                    return .none
                case 803:
                    state.phase = .success
                    return .merge(
                        .send(.stopPolling),
                        .send(.loginSucceeded)
                    )
                default:
                    return .none
                }

            case let .qrCheckResponse(.failure(error)):
                state.phase = .failed(error.message)
                return .none

            case .stopPolling:
                return .cancel(id: CancelID.qrPoll)

            case let .setPhone(phone):
                state.phone = phone
                return .none

            case let .setCode(code):
                state.code = code
                return .none

            case .sendCode:
                state.isSendingCode = true
                state.statusMessage = nil
                let phone = state.phone
                return .run { send in
                    do {
                        try await api.sendSMSCode(phone, "86")
                        await send(.sendCodeResponse(.success(true)))
                    } catch {
                        await send(.sendCodeResponse(.failure(AppError(wrapping: error))))
                    }
                }

            case .sendCodeResponse(.success):
                state.isSendingCode = false
                state.statusMessage = String(localized: "验证码已发送")
                state.smsCooldown = 60
                return .run { send in
                    var remaining = 60
                    while remaining > 0 {
                        try? await clock.sleep(for: .seconds(1))
                        remaining -= 1
                        await send(.codeCooldownTick)
                    }
                }
                .cancellable(id: CancelID.smsCooldown, cancelInFlight: true)

            case let .sendCodeResponse(.failure(error)):
                state.isSendingCode = false
                state.statusMessage = error.message
                return .none

            case .codeCooldownTick:
                guard state.smsCooldown > 0 else { return .none }
                state.smsCooldown -= 1
                return .none

            case .loginWithCode:
                state.isLoggingIn = true
                state.statusMessage = nil
                let phone = state.phone
                let code = state.code
                return .run { send in
                    do {
                        try await api.loginCellphone(phone, code, "86")
                        await send(.loginResponse(.success(true)))
                    } catch {
                        await send(.loginResponse(.failure(AppError(wrapping: error))))
                    }
                }

            case .loginResponse(.success):
                state.isLoggingIn = false
                return .merge(
                    .send(.stopPolling),
                    .send(.loginSucceeded)
                )

            case let .loginResponse(.failure(error)):
                state.isLoggingIn = false
                state.statusMessage = error.message
                return .none

            case .loginSucceeded:
                state.phase = .success
                return .none
            }
        }
    }
}
