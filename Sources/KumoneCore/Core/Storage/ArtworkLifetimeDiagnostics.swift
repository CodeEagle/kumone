import Foundation
import CoreGraphics
import ObjectiveC

/// Opt-in observations only: no image/provider data copies or strong image
/// references survive a call. Enable with the KumoneArtworkDiagnostics default.
public enum ArtworkLifetimeDiagnostics {
    private final class Record {
        weak var image: PlatformImage?
        weak var source: CGImage?
        weak var bitmap: CGImage?
        let id: String
        init(image: PlatformImage, source: CGImage, bitmap: CGImage, id: String) {
            self.image = image; self.source = source; self.bitmap = bitmap; self.id = id
        }
    }

    private final class Registry: @unchecked Sendable {
        // All mutable bookkeeping is protected by this lock. Records are weak;
        // scalar snapshot descriptions are built while holding the lock.
        let lock = NSLock()
        var records: [Record] = []
    }

    private final class ReleaseMarker {
        let id: String
        init(id: String) { self.id = id }
        deinit {
            KumoneLogger.player.notice("ARTLIFE image-deinit id=\(self.id, privacy: .public)")
        }
    }

    private static let registry = Registry()
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "KumoneArtworkDiagnostics")
            || ProcessInfo.processInfo.environment["KUMONE_ARTWORK_DIAGNOSTICS"] == "1"
    }

    static func track(image: PlatformImage, source: CGImage, bitmap: CGImage,
                      backing: String, rendition: ImageRendition) {
        guard isEnabled, rendition == .playback else { return }
        let id = UUID().uuidString
        let imageAddress = String(describing: Unmanaged.passUnretained(image).toOpaque())
        let sourceAddress = String(describing: Unmanaged.passUnretained(source).toOpaque())
        let bitmapAddress = String(describing: Unmanaged.passUnretained(bitmap).toOpaque())
        registry.lock.withLock {
            if registry.records.count >= 256 {
                registry.records.removeAll { $0.image == nil && $0.source == nil && $0.bitmap == nil }
                if registry.records.count >= 256 { registry.records.removeFirst() }
            }
            registry.records.append(Record(image: image, source: source, bitmap: bitmap, id: id))
        }
        // Associated marker owns just the UUID, never its image or CGImage.
        objc_setAssociatedObject(image, Unmanaged.passUnretained(registry).toOpaque(),
                                 ReleaseMarker(id: id), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        KumoneLogger.player.notice("ARTLIFE decoded id=\(id, privacy: .public) image=\(imageAddress, privacy: .public) source=\(sourceAddress, privacy: .public) bitmap=\(bitmapAddress, privacy: .public) contextBacking=\(backing, privacy: .public) width=\(bitmap.width) height=\(bitmap.height) bytes=\(bitmap.bytesPerRow * bitmap.height)")
    }

    public static func snapshot(reason: String) {
        guard isEnabled else { return }
        let lines: [String] = autoreleasepool {
            registry.lock.withLock {
                let lines = registry.records.map {
                    "ARTLIFE sample reason=\(reason) id=\($0.id) imageAlive=\($0.image != nil) sourceAlive=\($0.source != nil) bitmapAlive=\($0.bitmap != nil)"
                }
                registry.records.removeAll { $0.image == nil && $0.source == nil && $0.bitmap == nil }
                return lines
            }
        }
        for line in lines { KumoneLogger.player.notice("\(line, privacy: .public)") }
        KumoneLogger.player.notice("ARTLIFE snapshot reason=\(reason, privacy: .public) records=\(lines.count)")
    }

    @MainActor
    public static func sampleAfterTransition(reason: String) async {
        guard isEnabled else { return }
        snapshot(reason: reason + ":now")
        for (delay, label) in [(2, "2s"), (3, "5s"), (10, "15s")] {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            snapshot(reason: reason + ":" + label)
        }
    }
}
