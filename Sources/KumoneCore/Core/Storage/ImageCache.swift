import CryptoKit
import Foundation
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Two-tier (memory + disk) image cache with in-flight request coalescing.
public actor ImageCache {
    public static let shared = ImageCache()

    private nonisolated let memory = ImageMemoryCache()
    private let diskURL: URL
    private let session: URLSession
    private struct Flight {
        let id: UUID
        let task: Task<PlatformImage?, Never>
        var waiters: Set<UUID>
    }
    private var inflight: [String: Flight] = [:]
    private var loadingDisabled = false
    private var loadingGeneration: UInt64 = 0

    public func setLoadingDisabled(_ disabled: Bool) {
        guard disabled != loadingDisabled else { return }
        loadingDisabled = disabled
        loadingGeneration &+= 1
        memory.setLoadingDisabled(disabled)
        if disabled {
            let tasks = inflight.values.map(\.task)
            inflight.removeAll()
            tasks.forEach { $0.cancel() }
        }
    }

    init(diskURL: URL? = nil, session: URLSession? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.diskURL = diskURL ?? caches.appendingPathComponent("im.missuo.Kumone/images", isDirectory: true)
        // The two-tier cache already owns persistence. Do not also retain the
        // compressed covers in URLCache.shared alongside the decoded bitmaps.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: configuration)
        try? FileManager.default.createDirectory(at: self.diskURL, withIntermediateDirectories: true)
        // Reclaim what earlier sessions accumulated before the first new
        // cover lands; the disk tier has no other automatic sweep.
        ImageDiskCacheMaintenance.trimOnce(at: self.diskURL)
    }

    public func image(for url: URL, rendition: ImageRendition? = nil) async -> PlatformImage? {
        guard !loadingDisabled, !Task.isCancelled else { return nil }
        let generation = loadingGeneration
        let rendition = rendition ?? .automatic(for: url)
        let diskKey = Self.cacheKey(for: url)
        let key = diskKey + rendition.cacheSuffix
        if let cached = memory.image(for: key) {
            return cached
        }
        let waiter = UUID()
        let flight: Flight
        if var existing = inflight[key] {
            existing.waiters.insert(waiter)
            inflight[key] = existing
            flight = existing
        } else {
            let task = Task<PlatformImage?, Never> { [diskURL, session] in
                guard !Task.isCancelled else { return nil }
                let fileURL = diskURL.appendingPathComponent(diskKey)
                let diskImage = autoreleasepool { () -> PlatformImage? in
                    guard let data = try? Data(contentsOf: fileURL) else { return nil }
                    return Self.decode(data, rendition: rendition)
                }
                if let image = diskImage {
                    return image
                }
                guard let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      !Task.isCancelled,
                      let image = Self.decode(data, rendition: rendition) else { return nil }
                try? data.write(to: fileURL, options: .atomic)
                // Sweep the disk tier after a batch of writes rather than per
                // cover: enumeration is IO, and a cover is tens of KB.
                ImageDiskCacheMaintenance.recordWrite(at: diskURL)
                return image
            }
            flight = Flight(id: UUID(), task: task, waiters: [waiter])
            inflight[key] = flight
        }
        let result = await withTaskCancellationHandler {
            await flight.task.value
        } onCancel: {
            Task { await self.removeWaiter(waiter, key: key, flightID: flight.id) }
        }
        if !loadingDisabled, generation == loadingGeneration,
           !Task.isCancelled, inflight[key]?.id == flight.id, let result {
            let cost = autoreleasepool {
                result.cgImageRef.map { $0.bytesPerRow * $0.height }
            }
            if let cost {
                memory.insert(result, for: key, cost: cost, transient: rendition.transient)
                let residency = memory.residency
                KumoneLogger.player.info("ARTWORK cache bytes=\(self.memory.retainedBytes) entries=\(self.memory.count) limit=\(self.memory.limit) liveDecodedBytes=\(residency.liveBytes) liveDecodedImages=\(residency.liveImages) outsideCacheBytes=\(residency.outsideCacheBytes) pixelLimit=\(rendition.maxPixelSize) transient=\(rendition.transient)")
            }
        }
        removeWaiter(waiter, key: key, flightID: flight.id)
        return Task.isCancelled || loadingDisabled || generation != loadingGeneration ? nil : result
    }

    var pendingWaiterCount: Int { inflight.values.reduce(0) { $0 + $1.waiters.count } }

    private func removeWaiter(_ waiter: UUID, key: String, flightID: UUID) {
        guard var flight = inflight[key], flight.id == flightID else { return }
        flight.waiters.remove(waiter)
        if flight.waiters.isEmpty {
            inflight[key] = nil
            flight.task.cancel()
        } else {
            inflight[key] = flight
        }
    }

    /// Synchronous, lock-protected lookup. Returns nil unless resident; use
    /// `image(for:)` for disk/network loads.
    public nonisolated func cachedImage(for url: URL, rendition: ImageRendition? = nil) -> PlatformImage? {
        let rendition = rendition ?? .automatic(for: url)
        return memory.image(for: Self.cacheKey(for: url) + rendition.cacheSuffix)
    }

    /// Retain one decoded bitmap, not an NSImage holding compressed data plus
    /// lazily created representations. Bound huge originals before decoding.
    static func decode(_ data: Data, rendition: ImageRendition = .init(maxPixelSize: 1536, square: false)) -> PlatformImage? {
        // ImageIO/AppKit bridge objects must drain per cover, not at the end of
        // a long-lived worker's pool. The returned image owns its backing bitmap.
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            var thumbnailSize = rendition.maxPixelSize
            if rendition.square,
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
               let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
                let shortest = max(1, min(width.doubleValue, height.doubleValue))
                let ratio = max(width.doubleValue, height.doubleValue) / shortest
                thumbnailSize = Int(min(1536, ceil(Double(rendition.maxPixelSize) * ratio)))
            }
            guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: thumbnailSize
                  ] as CFDictionary) else { return nil }
            let output: CGImage
            var backing = "not-copied"
            if rendition.square {
                let cropSide = min(bitmap.width, bitmap.height)
                let side = min(cropSide, rendition.maxPixelSize)
                let rect = CGRect(x: (bitmap.width - cropSide) / 2, y: (bitmap.height - cropSide) / 2,
                                  width: cropSide, height: cropSide)
                let colorSpace = bitmap.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
                    ?? CGColorSpaceCreateDeviceRGB()
                guard let crop = bitmap.cropping(to: rect),
                      let context = CGContext(data: nil, width: side, height: side,
                        bitsPerComponent: 8, bytesPerRow: side * 4,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                // A cropped CGImage alone can retain the entire parent bitmap.
                // Copy into an independently owned square backing store.
                context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
                if ArtworkLifetimeDiagnostics.isEnabled, let pointer = context.data {
                    backing = String(describing: pointer)
                }
                guard let detached = context.makeImage() else { return nil }
                output = detached
            } else {
                output = bitmap
            }
            #if os(macOS)
            let image = PlatformImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
            #else
            let image = PlatformImage(cgImage: output)
            #endif
            ArtworkLifetimeDiagnostics.track(image: image, source: bitmap, bitmap: output,
                                             backing: backing, rendition: rendition)
            return image
        }
    }

    private static func cacheKey(for url: URL) -> String {
        let digest = Insecure.MD5.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Bounds the disk tier of `ImageCache`. The memory tier enforces its own
/// limit in `ImageMemoryCache`; the compressed copies written under `diskURL`
/// had no sweep at all until the user opened Settings and cleared by hand,
/// so months of playback grew the directory without end.
///
/// Modelled on `AudioCacheMaintenance`: a serial utility queue owns all
/// mutable state, sweeps are amortized over a batch of writes rather than
/// run per cover, and the byte budget evicts by modification time.
private enum ImageDiskCacheMaintenance {
    /// Logical byte budget for compressed covers on disk — thousands of
    /// albums' worth, while staying a small fraction of any modern volume.
    static let limitBytes: Int64 = 128 * 1_000_000

    /// Successful writes between directory sweeps.
    private static let writesPerSweep = 64

    private static let queue = DispatchQueue(label: "im.missuo.Kumone.image-cache", qos: .utility)
    // All mutable maintenance state is confined to this serial queue.
    private static var unscannedWrites = 0

    /// Records one write and sweeps once enough of them land.
    static func recordWrite(at diskURL: URL) {
        queue.async {
            unscannedWrites += 1
            guard unscannedWrites >= writesPerSweep else { return }
            unscannedWrites = 0
            trim(at: diskURL)
        }
    }

    /// One sweep at process start reclaims what earlier sessions left
    /// behind, before any new write arrives to justify it.
    static func trimOnce(at diskURL: URL) {
        queue.async { trim(at: diskURL) }
    }

    /// Evicts oldest covers until the directory is within `limitBytes`.
    ///
    /// Modification time stands in for recency: an atomic write updates it,
    /// and a cover nobody re-downloads is exactly the one that should go.
    static func trim(at diskURL: URL, limit: Int64 = limitBytes) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: diskURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            files.append((url, size, values.contentModificationDate ?? .distantPast))
            total += size
        }

        guard total > limit else { return }
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            guard total > limit else { break }
            do {
                try fileManager.removeItem(at: file.url)
                total -= file.size
            } catch {
                KumoneLogger.player.error(
                    "IMAGE cache eviction failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        KumoneLogger.player.info(
            "IMAGE cache trimmed logicalBytes=\(total) limit=\(limit)"
        )
    }
}

