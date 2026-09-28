#if os(macOS) && DEBUG
import AppKit
import ComposableArchitecture
import KumoneCore

/// Zero-human hero-transition verification. When the app launches with
/// `KUMONE_HERO_SELF_TEST=1` in its environment, it drives one now-playing
/// round trip on its own — the same sequence the command-shift-h self-check
/// menu item runs — waits for `HeroProbe` to judge the landing, appends a
/// summary line to the probe log, and quits. A shell script can then assert
/// the transition by tailing a file: no GUI automation, no eyeballing.
///
/// `run(appStore:)` is the launch-flag tour (summary line + quit);
/// `driveRoundTrip(appStore:)` is the shared sequence, which the menu
/// self-check reuses without quitting.
public enum HeroSelfTest {
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["KUMONE_HERO_SELF_TEST"] == "1"
    }

    /// The launch-flag tour: one round trip, one summary line, then quit so an
    /// outer script can tell the run is over. Does nothing unless the flag is
    /// set, so it is safe to call unconditionally at launch.
    @MainActor
    public static func run(appStore: StoreOf<AppFeature>) async {
        guard isEnabled else { return }
        let didPass = await driveRoundTrip(appStore: appStore)

        HeroProbe.writeFile(
            "HERO SELFTEST END pass=\(didPass ? 1 : 0) fail=\(didPass ? 0 : 1)"
                + " | \(verdictDescription())"
        )
        await flushAndTerminate()
    }

    /// One now-playing hero round trip: waits for the PlayerBar anchor, arms the
    /// probe from its cached geometry, presents the page, waits for the flight
    /// to be judged, and dismisses again. Returns whether the landing passed.
    @discardableResult
    @MainActor
    public static func driveRoundTrip(appStore: StoreOf<AppFeature>) async -> Bool {
        let heroID = HeroID.nowPlayingArtwork

        // The PlayerBar artwork has to have reported its frame before there is
        // anything to fly from.
        guard let sourceFrame = await waitForFrame(for: heroID, timeout: 5) else {
            KumoneLogger.hero.error("selftest: source anchor never appeared")
            return false
        }
        let sourceScale = HeroFrameStore.shared.scale(for: heroID) ?? 1

        // Arm the probe from the cached source geometry and open the page.
        HeroProbe.shared.begin(heroID)
        HeroProbe.shared.recordSource(frame: sourceFrame, scale: sourceScale)
        appStore.send(.presentNowPlaying)

        // The flight springs on the next layout pass; wait for it to settle and
        // for the probe to archive its verdict.
        let verdict = await waitForVerdict(for: heroID, timeout: 12)

        // Leave the page so the round trip closes cleanly.
        appStore.send(.dismissNowPlaying)

        return verdict.map { !$0.isFailure } ?? false
    }

    // MARK: - Polling

    /// Waits up to `timeout` seconds for an anchor's cached frame, checking
    /// roughly every 50ms. Never force-unwraps: a missing frame is reported as
    /// nil and the caller decides what to do.
    @MainActor
    private static func waitForFrame(for id: String, timeout: TimeInterval) async -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let frame = HeroFrameStore.shared.frame(for: id) { return frame }
            if Task.isCancelled { return nil }
            guard Date() < deadline else { return HeroFrameStore.shared.frame(for: id) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Waits up to `timeout` seconds for the newest judged record with this id,
    /// searching `records` from the back so a stale record from an earlier run
    /// never stands in for this one.
    @MainActor
    private static func waitForVerdict(for id: String, timeout: TimeInterval) async -> HeroProbe.Verdict? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let verdict = judgedRecord(for: id)?.verdict { return verdict }
            if Task.isCancelled { return nil }
            guard Date() < deadline else { return judgedRecord(for: id)?.verdict }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    private static func judgedRecord(for id: String) -> HeroProbe.Record? {
        HeroProbe.shared.records.last { $0.id == id && $0.verdict != nil }
    }

    /// Describes the latest verdict for the now-playing artwork, for the summary
    /// line; the record is already archived by the time this runs.
    @MainActor
    private static func verdictDescription() -> String {
        guard let verdict = judgedRecord(for: HeroID.nowPlayingArtwork)?.verdict else {
            return "no verdict (flight did not settle)"
        }
        switch verdict {
        case .pass:
            return "PASS"
        case let .fail(reason):
            return "FAIL: \(reason)"
        }
    }

    /// `HeroProbe.writeFile` hands the write to a detached task, so give it a
    /// beat before quitting or the summary line could be cut off by the
    /// terminate that follows it.
    private static func flushAndTerminate() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
        NSApp.terminate(nil)
    }
}
#endif
