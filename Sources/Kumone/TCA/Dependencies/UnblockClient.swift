import ComposableArchitecture
import Foundation

/// Third-party source resolution (UnblockNeteaseMusic-style), behind a dependency.
@DependencyClient
struct UnblockClient {
    /// nil when no alternative source could be found.
    var resolve: @Sendable (_ track: Track) async -> UnblockService.Resolved?
}

extension UnblockClient: DependencyKey {
    static let liveValue = UnblockClient(
        resolve: { await UnblockService.resolve($0) }
    )
}

extension DependencyValues {
    var unblock: UnblockClient {
        get { self[UnblockClient.self] }
        set { self[UnblockClient.self] = newValue }
    }
}
