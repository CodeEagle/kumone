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

        let judgedCounts = HeroID.nowPlayingPairs.map { pair in
            "\(pair.source):\(HeroProbe.shared.records.filter { $0.id == pair.source && $0.verdict != nil }.count)"
        }.joined(separator: ",")
        HeroProbe.writeFile(
            "HERO SELFTEST END pass=\(didPass ? 1 : 0) fail=\(didPass ? 0 : 1)"
                + " | \(verdictDescription())"
                + " | judged \(judgedCounts)"
        )
        await flushAndTerminate()
    }

    /// One now-playing hero round trip: waits for the mini player's anchor
    /// set to settle, arms the probe from each anchor's cached geometry,
    /// presents the page, waits for the flight to be judged, and dismisses
    /// again. Returns whether the landing passed.
    @discardableResult
    @MainActor
    public static func driveRoundTrip(appStore: StoreOf<AppFeature>) async -> Bool {
        let pairs = HeroID.nowPlayingPairs

        // Arm only after the anchor set has stopped growing. The transport
        // buttons register their anchors in a burst a beat after launch, and a
        // fixed per-pair wait both skips the early pairs on a cold start and
        // burns the whole timeout on mutually-exclusive ids (the FM-only trash
        // button never appears for a non-FM track). Waiting for the set to
        // settle covers the late arrivals; whatever is still absent is absent
        // on purpose, so it is skipped rather than waited for.
        await waitForStableAnchors(for: pairs.map { $0.source }, settleInterval: 1.0, deadline: 5.0)

        var drivenPairs: [(source: String, target: String)] = []
        var skipped: [String: Int] = [:]
        for pair in pairs {
            guard let frame = HeroFrameStore.shared.frame(for: pair.source) else {
                // FM and non-FM button groups are mutually exclusive; hidden
                // elements never register an anchor in the current mode.
                continue
            }
            skipped[pair.source] = HeroProbe.shared.records.filter { $0.id == pair.source && $0.verdict != nil }.count
            HeroProbe.shared.begin(pair.source)
            HeroProbe.shared.recordSource(
                id: pair.source, frame: frame,
                scale: HeroFrameStore.shared.scale(for: pair.source) ?? 1,
                cornerRadius: pair.source == HeroID.nowPlayingArtwork ? Theme.Radius.small : 15
            )
            drivenPairs.append(pair)
        }

        // One diagnosable line listing what this round armed and what it gave
        // up on, so a run that flies fewer elements than expected can be
        // triaged from the probe log alone.
        let drivenIDs = drivenPairs.map { $0.source }
        let skippedIDs = pairs.map { $0.source }.filter { !drivenIDs.contains($0) }
        HeroProbe.writeFile(
            "HERO SELFTEST ARMED driven=[\(drivenIDs.joined(separator: ","))]"
                + " skipped=[\(skippedIDs.joined(separator: ","))]"
        )

        guard !drivenPairs.isEmpty else {
            KumoneLogger.hero.error("selftest: no source anchors appeared")
            return false
        }
        appStore.send(.presentNowPlaying)
        var passed = true
        for pair in drivenPairs {
            let verdict = await waitForVerdict(for: pair.source, timeout: 12, skipping: skipped[pair.source] ?? 0)
            passed = (verdict.map { !$0.isFailure } ?? false) && passed
            skipped[pair.source] = HeroProbe.shared.records.filter { $0.id == pair.source && $0.verdict != nil }.count
        }
        appStore.send(.dismissNowPlaying)
        for pair in drivenPairs {
            let verdict = await waitForVerdict(for: pair.source, timeout: 12, skipping: skipped[pair.source] ?? 0)
            passed = (verdict.map { !$0.isFailure } ?? false) && passed
        }
        return passed
    }

    // MARK: - Polling

    /// Waits for the anchor set among `ids` to stop growing: once no new id
    /// has appeared for `settleInterval`, the set counts as stable and the
    /// caller arms whatever is present. `deadline` caps the whole wait, so a
    /// mini player that never appears cannot stall the round trip. Checks
    /// roughly every 50ms; never force-unwraps.
    @MainActor
    private static func waitForStableAnchors(
        for ids: [String], settleInterval: TimeInterval, deadline: TimeInterval
    ) async {
        let start = Date()
        var lastGrowth = start
        var seen: Set<String> = []
        while true {
            let present = Set(ids.filter { HeroFrameStore.shared.frame(for: $0) != nil })
            if !present.isSubset(of: seen) {
                seen = present
                lastGrowth = Date()
            }
            let now = Date()
            if now.timeIntervalSince(lastGrowth) >= settleInterval { return }
            if now.timeIntervalSince(start) >= deadline { return }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Waits up to `timeout` seconds for the newest judged record with this id,
    /// searching `records` from the back so a stale record from an earlier run
    /// never stands in for this one. `skipping` ignores the first N judged
    /// records, so a caller that already saw the present flight's verdict can
    /// wait for the dismiss flight's separately.
    @MainActor
    private static func waitForVerdict(for id: String, timeout: TimeInterval, skipping: Int = 0) async -> HeroProbe.Verdict? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let verdict = judgedRecord(for: id, skipping: skipping)?.verdict { return verdict }
            if Task.isCancelled { return nil }
            guard Date() < deadline else { return judgedRecord(for: id, skipping: skipping)?.verdict }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    private static func judgedRecord(for id: String, skipping: Int = 0) -> HeroProbe.Record? {
        let judged = HeroProbe.shared.records.filter { $0.id == id && $0.verdict != nil }
        guard judged.count > skipping else { return nil }
        return judged.last
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
