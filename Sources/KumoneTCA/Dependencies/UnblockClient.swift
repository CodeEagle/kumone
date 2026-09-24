import ComposableArchitecture
import Foundation
import KumoneCore

/// Third-party source resolution (UnblockNeteaseMusic-style), behind a dependency.
@DependencyClient
public struct UnblockClient {
    /// nil when no alternative source could be found.
    public var resolve: @Sendable (_ track: Track) async -> UnblockService.Resolved?
}

extension UnblockClient: DependencyKey {
    public static let liveValue = UnblockClient(
        resolve: { await UnblockService.resolve($0) }
    )
}

extension DependencyValues {
    public var unblock: UnblockClient {
        get { self[UnblockClient.self] }
        set { self[UnblockClient.self] = newValue }
    }
}
