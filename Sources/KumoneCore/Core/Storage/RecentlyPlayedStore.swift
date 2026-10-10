import Foundation

/// Remembers which tracks were played recently so that personal FM
/// (`/v1/radio/get`) and heartbeat mode (`/playmode/intelligence/list`) can
/// skip songs the user already heard within a configurable retention window.
///
/// The on/off toggle and retention length live in UserDefaults
/// (`fm.recentFilterEnabled` / `fm.recentFilterDays`), shared with
/// `SettingsFeature`, so the filter and its UI always agree. Entries are
/// pruned lazily on every read and write, so the store never holds a song
/// longer than the retention window — the "cache clears itself after 1 month".
///
/// Access level: public actor. `shared` is used by the NetEase provider;
/// the internal initializer injects retention/clock state for unit tests.
public actor RecentlyPlayedStore {
    public static let shared = RecentlyPlayedStore()

    // MARK: - Configuration keys (shared with SettingsFeature)

    static let enabledKey = "fm.recentFilterEnabled"
    static let daysKey = "fm.recentFilterDays"
    static let defaultDays = 30
    static let secondsPerDay: TimeInterval = 86_400

    // MARK: - State

    /// `songID -> timestamp played`. Only entries inside the retention window.
    private var played: [Int: TimeInterval] = [:]
    private var dirty = false
    private let storeURL: URL?
    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date

    /// Fixed overrides for tests; nil means "read live from UserDefaults".
    private let injectedDays: Int?
    private let injectedEnabled: Bool?

    // MARK: - Shared

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        storeURL = caches.appendingPathComponent("im.missuo.Kumone/recently-played.json")
        defaults = .standard
        clock = { Date() }
        injectedDays = nil
        injectedEnabled = nil
        Task { await load() }
    }

    /// Test-only: inject retention/enable state and a controllable clock.
    /// A nil `storeURL` disables persistence entirely.
    internal init(
        days: Int? = nil,
        enabled: Bool? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        storeURL: URL? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.injectedDays = days
        self.injectedEnabled = enabled
        self.storeURL = storeURL
        self.defaults = defaults
        self.clock = clock
        Task { await load() }
    }

    // MARK: - Configuration

    private var isEnabled: Bool {
        if let enabled = injectedEnabled { return enabled }
        // object(forKey:) distinguishes "never set" (nil → default on)
        // from an explicit false, which a plain boolForKey cannot.
        return defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private var retentionSeconds: TimeInterval {
        let days: Int
        if let injected = injectedDays {
            days = injected
        } else {
            // SettingsFeature persists this as a Double via persistence.setDouble.
            let raw = defaults.double(forKey: Self.daysKey)
            days = raw > 0 ? Int(raw) : Self.defaultDays
        }
        return TimeInterval(days) * Self.secondsPerDay
    }

    // MARK: - API

    /// Records that `trackID` started playing right now. Called once per track
    /// from the same hook as scrobble start. Re-playing a song refreshes its
    /// timestamp, pushing its expiry out again.
    public func record(trackID: Int) {
        guard isEnabled, retentionSeconds > 0 else { return }
        played[trackID] = clock().timeIntervalSince1970
        dirty = true
        pruneAndSave()
    }

    /// Drops songs played within the retention window. Returns the input
    /// untouched when the filter is off or retention is zero.
    public func filter(_ tracks: [Track]) -> [Track] {
        guard isEnabled, retentionSeconds > 0 else { return tracks }
        prune()
        // After prune, every remaining entry is inside the window.
        return tracks.filter { played[$0.id] == nil }
    }

    // MARK: - Pruning & persistence

    private func prune() {
        let cutoff = clock().timeIntervalSince1970 - retentionSeconds
        let stale = played.filter { _, playedAt in playedAt <= cutoff }
        guard !stale.isEmpty else { return }
        played = played.filter { _, playedAt in playedAt > cutoff }
        dirty = true
    }

    private func pruneAndSave() {
        prune()
        save()
    }

    private func load() {
        guard let storeURL,
              let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode([Int: TimeInterval].self, from: data)
        else { return }
        played = stored
        // Drop anything already past its window on launch.
        prune()
        // Prune-only changes need not be written back on load; the next
        // record() or a future load will persist the trimmed set.
        dirty = false
    }

    private func save() {
        guard let storeURL, dirty else { return }
        guard let data = try? JSONEncoder().encode(played) else { return }
        try? data.write(to: storeURL, options: .atomic)
        dirty = false
    }
}
