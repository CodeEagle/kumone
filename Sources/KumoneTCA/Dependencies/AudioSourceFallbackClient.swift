import ComposableArchitecture
import Foundation
import KumoneCore

/// Third-party audio source fallback (upstream 07225a5, adapted to appkit's
/// provider architecture).
///
/// `resolveURLEffect` tries the main provider and then the unblock service.
/// When both refuse a track (or only offer a trial clip), this client retries
/// on the Kuwo mirror: a keyword search for the track, a duration match, and
/// the mirror's own playable URL. The Kuwo/QQ providers already implement the
/// `MusicProvider` protocol this app uses everywhere else, so nothing is
/// reimplemented — the fallback only composes existing calls.
public struct AudioSourceFallbackClient: Sendable {
    /// Searches the mirror for a track and returns its playable URL plus the
    /// display name of the source that served it. `nil` when no match or no
    /// playable URL.
    public var resolve: @Sendable (_ track: Track) async -> (url: URL, source: String)? = { _ in nil }

    public init(resolve: @Sendable @escaping (_ track: Track) async -> (url: URL, source: String)?) {
        self.resolve = resolve
    }

    public init() {}
}

extension AudioSourceFallbackClient: DependencyKey {
    /// App composition roots inject the live platform adapter. The default
    /// stays inert in tests: mirror selector resolution is a network call a
    /// unit test should not make, and tests that want a retry override the
    /// endpoint per-store.
    /// Mirror resolution is a network call a unit test should not make;
    /// tests that want a retry override the endpoint per-store.
    public static let testValue = AudioSourceFallbackClient(
        resolve: { _ in nil }
    )

    public static let previewValue = testValue

    public static let liveValue = AudioSourceFallbackClient(
        resolve: { track in
            let keyword = AudioSourceFallbackClient.keyword(for: track)
            guard !keyword.isEmpty else { return nil }

            // The Kuwo mirror resolves by keyword + duration, not by the
            // NetEase track id — the ids belong to a different catalog.
            let kuwo = KuwoMusicProvider()
            guard
                let result = try? await kuwo.search(
                    keyword, category: .songs, limit: 10, offset: 0
                ),
                let match = AudioSourceFallbackClient.match(track, in: result.songs)
            else { return nil }

            guard
                let data = try? await kuwo.songURL(
                    ids: [MusicID(match.id)], quality: .standard
                ).first,
                let urlString = data.url, !urlString.isEmpty,
                let url = URL(string: urlString)
            else { return nil }

            return (url, String(localized: "酷我音乐"))
        }
    )
}

extension DependencyValues {
    var audioSourceFallback: AudioSourceFallbackClient {
        get { self[AudioSourceFallbackClient.self] }
        set { self[AudioSourceFallbackClient.self] = newValue }
    }
}

extension AudioSourceFallbackClient {
    /// "Song name first artist" — the same keyword shape the upstream matcher
    /// uses, trimmed so a missing artist does not leave a trailing space.
    static func keyword(for track: Track) -> String {
        "\(track.name) \(track.artists.first?.name ?? "")"
            .trimmingCharacters(in: .whitespaces)
    }

    /// Picks the mirror candidate that matches the original by duration (the
    /// catalog ids differ, so the title alone picks wrong versions, covers and
    /// remixes of the same name). Accepts a ±5 second tolerance; a lyric-less
    /// upload often shaves or adds a beat.
    static func match(_ track: Track, in candidates: [Track]) -> Track? {
        guard track.duration > 0 else {
            // No original duration to compare against: trust the top hit, the
            // search ranking already prefers the exact title.
            return candidates.first
        }
        return candidates.min(by: { lhs, rhs in
            abs(lhs.duration - track.duration) < abs(rhs.duration - track.duration)
        }).flatMap { candidate in
            abs(candidate.duration - track.duration) <= 5 ? candidate : nil
        }
    }
}
