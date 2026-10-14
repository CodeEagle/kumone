import Foundation

/// A deterministic decoded-bitmap budget. NSCache's cost limit is advisory.
/// The lock protects every entry, access stamp and byte counter, including the
/// synchronous lookup used while constructing SwiftUI views.
final class ImageMemoryCache: @unchecked Sendable {
    private final class DecodedImage {
        weak var image: PlatformImage?
        let cost: Int
        init(image: PlatformImage, cost: Int) { self.image = image; self.cost = cost }
    }
    struct Residency {
        let liveBytes: Int
        let liveImages: Int
        let outsideCacheBytes: Int
    }
    private struct Entry {
        let image: PlatformImage
        let cost: Int
        var stamp: UInt64
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var liveEntries: [String: DecodedImage] = [:]
    private var transientEntries: [String: DecodedImage] = [:]
    // Weak bookkeeping sees covers still held by UI/Now Playing after eviction,
    // without extending their lifetimes. Pixel bytes, not process footprint.
    private var decodedImages: [ObjectIdentifier: DecodedImage] = [:]
    private var stamp: UInt64 = 0
    private var bytes = 0
    private var disabled = false
    let limit: Int

    init(limit: Int = 16 * 1024 * 1024) { self.limit = max(0, limit) }

    var retainedBytes: Int { lock.withLock { bytes } }
    var count: Int { lock.withLock { entries.count } }

    func setLoadingDisabled(_ value: Bool) {
        lock.withLock {
            disabled = value
            if value { entries.removeAll(); transientEntries.removeAll(); liveEntries.removeAll(); bytes = 0 }
        }
    }

    var residency: Residency {
        lock.withLock {
            decodedImages = decodedImages.filter { $0.value.image != nil }
            let cachedIDs = Set(entries.values.map { ObjectIdentifier($0.image) })
            return Residency(
                liveBytes: decodedImages.values.reduce(0) { $0 + $1.cost },
                liveImages: decodedImages.count,
                outsideCacheBytes: decodedImages.reduce(0) {
                    $0 + (cachedIDs.contains($1.key) ? 0 : $1.value.cost)
                })
        }
    }

    func image(for key: String) -> PlatformImage? {
        lock.withLock {
            guard !disabled else { return nil }
            if let entry = transientEntries[key] {
                if let image = entry.image { return image }
                transientEntries[key] = nil
            }
            guard var entry = entries[key] else { return nil }
            stamp &+= 1
            entry.stamp = stamp
            entries[key] = entry
            return entry.image
        }
    }

    /// Reuse an evicted bitmap still held by a visible image view, without
    /// extending its lifetime or charging a second cache against the budget.
    func liveImage(for key: String) -> PlatformImage? {
        lock.withLock {
            guard !disabled else { return nil }
            guard let image = liveEntries[key]?.image else {
                liveEntries[key] = nil
                return nil
            }
            return image
        }
    }

    func insert(_ image: PlatformImage, for key: String, cost: Int, transient: Bool = false) {
        lock.withLock {
            guard !disabled else { return }
            decodedImages = decodedImages.filter { $0.value.image != nil }
            if cost > 0 {
                decodedImages[ObjectIdentifier(image)] = DecodedImage(image: image, cost: cost)
            }
            liveEntries = liveEntries.filter { $0.value.image != nil }
            if liveEntries.count >= 600, let oldestKey = liveEntries.keys.first {
                liveEntries.removeValue(forKey: oldestKey)
            }
            liveEntries[key] = DecodedImage(image: image, cost: cost)
            if let old = entries.removeValue(forKey: key) { bytes -= old.cost }
            transientEntries = transientEntries.filter { $0.value.image != nil }
            if transient {
                guard cost > 0 else { return }
                if transientEntries.count >= 300 { transientEntries.removeAll() }
                transientEntries[key] = DecodedImage(image: image, cost: cost)
                return
            }
            transientEntries[key] = nil
            guard cost > 0, cost <= limit else { return }
            // Also bound dictionary/object overhead for very small covers.
            while bytes > limit - cost || entries.count >= 300,
                  let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp }) {
                bytes -= oldest.value.cost
                entries.removeValue(forKey: oldest.key)
            }
            stamp &+= 1
            entries[key] = Entry(image: image, cost: cost, stamp: stamp)
            bytes += cost
        }
    }
}
