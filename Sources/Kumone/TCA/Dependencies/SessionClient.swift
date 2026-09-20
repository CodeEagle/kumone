import ComposableArchitecture
import Foundation

/// The NetEase session (cookie jar), behind a dependency.
///
/// QR and SMS logins land their cookies via `Set-Cookie` absorption inside the
/// transport, so the client surface here is read-mostly: "do we have a
/// `MUSIC_U`?" plus wiping it on logout.
@DependencyClient
struct SessionClient {
    var hasAuthCookie: @Sendable () -> Bool = { false }
    var clearAuth: @Sendable () -> Void = { }
}

extension SessionClient: DependencyKey {
    static let liveValue = SessionClient(
        hasAuthCookie: { NeteaseClient.shared.isLoggedIn },
        clearAuth: { NeteaseClient.shared.clearAuthCookies() }
    )
}

extension DependencyValues {
    var session: SessionClient {
        get { self[SessionClient.self] }
        set { self[SessionClient.self] = newValue }
    }
}
