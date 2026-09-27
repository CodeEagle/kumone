import Foundation

/// Cookie-free transport for anonymous providers; each client owns its session.
enum AnonymousSession {
    static let requestTimeout: TimeInterval = 30

    static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }
}
