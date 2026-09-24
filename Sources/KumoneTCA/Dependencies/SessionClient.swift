import ComposableArchitecture
import Foundation
import KumoneCore

/// The NetEase session (cookie jar), behind a dependency.
///
/// QR and SMS logins land their cookies via `Set-Cookie` absorption inside the
/// transport, so the client surface here is read-mostly: "do we have a
/// `MUSIC_U`?" plus wiping it on logout.
@DependencyClient
public struct SessionClient {
    public var hasAuthCookie: @Sendable () -> Bool = { false }
    public var clearAuth: @Sendable () -> Void = { }
}

extension SessionClient: DependencyKey {
    public static let liveValue = SessionClient(
        hasAuthCookie: { NeteaseClient.shared.isLoggedIn },
        clearAuth: { NeteaseClient.shared.clearAuthCookies() }
    )
}

extension DependencyValues {
    public var session: SessionClient {
        get { self[SessionClient.self] }
        set { self[SessionClient.self] = newValue }
    }
}
