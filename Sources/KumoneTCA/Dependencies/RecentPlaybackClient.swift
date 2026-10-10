import ComposableArchitecture
import KumoneCore

/// Local recommendation history, independent of remote scrobble latency.
public struct RecentPlaybackClient: Sendable {
    public var record: @Sendable (Int) async -> Void
    public var filter: @Sendable ([Track]) async -> [Track]
}

extension RecentPlaybackClient: DependencyKey {
    public static let liveValue = Self(
        record: { await RecentlyPlayedStore.shared.record(trackID: $0) },
        filter: { await RecentlyPlayedStore.shared.filter($0) })
    public static let testValue = Self(record: { _ in }, filter: { $0 })
}

extension DependencyValues {
    public var recentPlayback: RecentPlaybackClient {
        get { self[RecentPlaybackClient.self] }
        set { self[RecentPlaybackClient.self] = newValue }
    }
}
