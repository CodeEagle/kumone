import ComposableArchitecture
import Foundation
import KumoneCore
import KumoneTCA

/// Headless leak reproduction: run with `KUMONE_LEAK_STRESS=1`.
///
/// Plays through a playlist, skipping every few seconds — the "rapid track
/// switching" reported to pile memory up — and logs the resident footprint
/// after each skip. No window interaction required: the whole loop drives the
/// store, so it runs on any machine (local debug or workmini release) with a
/// logged-in account.
///
/// Output lands in /tmp/kumone-leak.log:
///   LEAK STRESS skip=01 rss=312MiB delta=+0MiB
///   ...
///   LEAK STRESS END skips=20 start=312MiB end=1217MiB growth=+905MiB
@MainActor
enum LeakStress {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["KUMONE_LEAK_STRESS"] == "1"
    }

    /// Seconds on each track before the skip. Fast enough to stress the
    /// resolve/load/teardown cycle, slow enough for the engine to actually
    /// start each stream (the state the leak was reported in).
    private static let secondsPerTrack: TimeInterval = 3
    private static let skipCount = 20
    private static let logURL = URL(fileURLWithPath: "/tmp/kumone-leak.log")

    /// Drives one stress run: build a queue from the first recommended
    /// playlist, start playback, then skip repeatedly while sampling memory.
    static func run(appStore: StoreOf<AppFeature>) async {
        guard let tracks = await queuedTracks(appStore: appStore), !tracks.isEmpty else {
            write("LEAK STRESS END error=no-tracks")
            return
        }
        write("LEAK STRESS START tracks=\(tracks.count)")
        appStore.send(.player(.play(
            tracks: tracks,
            source: .playlist(tracks.first?.id ?? 0),
            startAt: nil,
            context: .playlist(id: tracks.first?.id ?? 0, name: "leak-stress")
        )))

        let start = residentFootprint()
        var last = start
        for skip in 1...skipCount {
            try? await Task.sleep(nanoseconds: UInt64(secondsPerTrack * 1_000_000_000))
            guard appStore.player.hasCurrentTrack else { write("LEAK STRESS stop=playback-ended"); break }
            appStore.send(.player(.next))
            let now = residentFootprint()
            let delta = now - last
            write(String(format: "LEAK STRESS skip=%02d rss=%.0fMiB delta=%+.0fMiB",
                         skip, Double(now) / 1_048_576, Double(delta) / 1_048_576))
            last = now
        }
        let end = residentFootprint()
        write(String(format: "LEAK STRESS END skips=%d start=%.0fMiB end=%.0fMiB growth=%+.0fMiB",
                     skipCount, Double(start) / 1_048_576, Double(end) / 1_048_576,
                     Double(end - start) / 1_048_576))
    }

    /// Pulls playable tracks from the first recommended playlist on the home
    /// shelf; needs a logged-in account (the same source the hero card
    /// self-test uses).
    private static func queuedTracks(appStore: StoreOf<AppFeature>) async -> [Track]? {
        let limit = Date().addingTimeInterval(20)
        while Date() < limit {
            if let id = appStore.home.recommendPlaylists.first?.id {
                if let response = try? await NeteaseAPI.playlistDetail(id: id) {
                    return response.playlist.tracks
                }
                return nil
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return nil
    }

    /// Physical footprint of this process, the same number Activity Monitor's
    /// "Memory" column shows.
    private static func residentFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    private static func write(_ line: String) {
        KumoneLogger.app.notice("\(line, privacy: .public)")
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
            try? handle.close()
        } else {
            try? payload.write(to: logURL, options: [.atomic])
        }
    }
}
