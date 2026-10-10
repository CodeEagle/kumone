import APlay
import Foundation
import KumoneCore

/// Keeps APlay's on-disk stream cache bounded.
///
/// APlay sweeps once per process. Enforce the user-selected logical-byte
/// budget throughout playback too, while protecting the current track.
public enum AudioCacheMaintenance {
    public static let limitKey = "settings.audioCacheLimitMB"
    public static var limitBytes: Int64 {
        let stored = UserDefaults.standard.integer(forKey: limitKey)
        return Int64(min(max(stored == 0 ? 256 : stored, 64), 4095)) * 1_000_000
    }

    public static var directory: URL {
        URL(fileURLWithPath: APlay.Configuration.defaultCachedDirectory,
            isDirectory: true)
    }

    private static let queue = DispatchQueue(label: "im.missuo.Kumone.audio-cache", qos: .utility)
    // All mutable maintenance state is confined to this serial queue.
    private static var protectedName: String?
    private static var timer: DispatchSourceTimer?

    static func protect(url: URL) {
        // Match APlay.Configuration.defaultPolicy (its name(for:) is internal).
        let name = Data(url.path.utf8).base64EncodedString()
        queue.async {
            protectedName = name
            if timer == nil {
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.schedule(deadline: .now(), repeating: .seconds(15))
                source.setEventHandler { trimSynchronously() }
                timer = source
                source.resume()
            }
            trimSynchronously()
        }
    }

    /// Evict the oldest completed cache files until the directory is within
    /// the configured limit, without unlinking the active track or its sidecars.
    public static func trimIfNeeded(completion: (@MainActor @Sendable () -> Void)? = nil) {
        queue.async {
            trimSynchronously()
            if let completion { DispatchQueue.main.async { completion() } }
        }
    }

    public static func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static func trimSynchronously(at root: URL? = nil, limit: Int64? = nil, protecting name: String? = nil) {
        let fileManager = FileManager.default
        let root = root ?? directory
        let limit = limit ?? limitBytes
        let protected = name ?? protectedName
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            files.append((url, size, values.contentModificationDate ?? .distantPast))
            total += size
        }

        guard total > limit else { return }
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard total > limit else { break }
            if let protected,
               [protected, protected + ".part", protected + ".part.meta", protected + ".part.meta.tmp", protected + ".tmp"].contains(file.url.lastPathComponent) { continue }
            do {
                try fileManager.removeItem(at: file.url)
                total -= file.size
            } catch {
                KumoneLogger.player.error("CACHE eviction failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        KumoneLogger.player.notice("CACHE trimmed logicalBytes=\(total) limit=\(limit)")
    }
}
