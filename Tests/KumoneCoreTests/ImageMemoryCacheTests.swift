import XCTest
import CoreGraphics
import ImageIO
@testable import KumoneCore

private final class WeakImageReference {
    weak var value: PlatformImage?
    init(_ value: PlatformImage?) { self.value = value }
}

final class ImageMemoryCacheTests: XCTestCase {
    func testVisibleEvictedBitmapCanBeReusedWithoutExtendingItsLifetime() {
        let cache = ImageMemoryCache(limit: 128)
        var visibleImage: PlatformImage? = PlatformImage()
        let reference = WeakImageReference(visibleImage)
        cache.insert(visibleImage!, for: "visible-card", cost: 128)
        cache.insert(PlatformImage(), for: "another-card", cost: 128)

        XCTAssertNil(cache.image(for: "visible-card"), "strong cache obeys its budget")
        XCTAssertTrue(cache.liveImage(for: "visible-card") === visibleImage,
                      "hero reuses the bitmap the card still displays")
        XCTAssertEqual(cache.retainedBytes, 128)
        XCTAssertEqual(cache.count, 1)

        visibleImage = nil
        XCTAssertNil(reference.value, "weak lookup must not pin offscreen artwork")
        XCTAssertNil(cache.liveImage(for: "visible-card"))
    }

    func testDiagnosticClearsMemoryAndBlocksCacheHitsAndInserts() {
        let cache = ImageMemoryCache()
        let image = PlatformImage(size: CGSize(width: 2, height: 2))
        cache.insert(image, for: "cover", cost: 16)
        XCTAssertNotNil(cache.image(for: "cover"))
        cache.setLoadingDisabled(true)
        XCTAssertEqual(cache.retainedBytes, 0)
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.liveImage(for: "cover"))
        cache.insert(image, for: "blocked", cost: 16)
        XCTAssertNil(cache.image(for: "blocked"))
        cache.setLoadingDisabled(false)
        cache.insert(image, for: "restored", cost: 16)
        XCTAssertNotNil(cache.image(for: "restored"))
    }
    func testResidencyTracksEvictedImagesWithoutRetainingThem() {
        let cache = ImageMemoryCache(limit: 128)
        var offscreenImage: PlatformImage? = PlatformImage()
        let reference = WeakImageReference(offscreenImage)
        cache.insert(offscreenImage!, for: "old-row", cost: 128)
        let current = PlatformImage()
        cache.insert(current, for: "new-row", cost: 128)
        XCTAssertEqual(cache.retainedBytes, 128)
        XCTAssertEqual(cache.residency.liveBytes, 256)
        XCTAssertEqual(cache.residency.outsideCacheBytes, 128)
        offscreenImage = nil
        XCTAssertNil(reference.value)
        XCTAssertEqual(cache.residency.liveBytes, 128)
        XCTAssertEqual(cache.residency.liveImages, 1)
        XCTAssertEqual(cache.residency.outsideCacheBytes, 0)
        withExtendedLifetime(current) {}
    }

    #if os(macOS)
    func testRepeatedDecodeReleasesNativeImagesBeforeOuterPoolDrains() throws {
        let data: Data = try autoreleasepool {
            let context = try XCTUnwrap(CGContext(data: nil, width: 1024, height: 1024,
                bitsPerComponent: 8, bytesPerRow: 4096,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let bitmap = try XCTUnwrap(context.makeImage())
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, bitmap, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
        func nativeImageCount() throws -> Int {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/heap")
            process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "-sortBySize"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0, output.contains("CLASS_NAME") else {
                throw NSError(domain: "ArtworkLifecycle.heap", code: Int(process.terminationStatus))
            }
            return output.split(separator: "\n").first(where: { $0.contains("   CGImage ") })
                .flatMap { Int($0.split(whereSeparator: { $0.isWhitespace }).first ?? "") } ?? 0
        }
        // Warm ImageIO, then keep the caller's pool open throughout turnover.
        autoreleasepool { _ = ImageCache.decode(data, rendition: .playback) }
        try autoreleasepool {
            let before = try nativeImageCount()
            var retained: [PlatformImage] = []
            for _ in 0..<40 {
                retained.append(try XCTUnwrap(ImageCache.decode(data, rendition: .playback)))
                if retained.count > 4 { retained.removeFirst() }
            }
            let after = try nativeImageCount()
            print("ARTWORK LIFECYCLE CGImage before=\(before) after=\(after) retained=\(retained.count)")
            XCTAssertLessThanOrEqual(after - before, 8,
                "Evicted covers must not retain native bitmaps until the caller's pool drains")
            withExtendedLifetime(retained) {}
        }
    }
    #endif

    func testHugeOriginalIsDownsampledAndBudgetUsesDecodedPixelBytes() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3072, height: 1536,
            bitsPerComponent: 8, bytesPerRow: 3072 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bitmap = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, bitmap, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let image = try XCTUnwrap(ImageCache.decode(data as Data))
        let decoded = try XCTUnwrap(image.cgImageRef)
        XCTAssertEqual(decoded.width, 1536)
        XCTAssertEqual(decoded.height, 768)
        let cost = decoded.bytesPerRow * decoded.height
        let cache = ImageMemoryCache(limit: cost * 2)
        for index in 0..<100 {
            cache.insert(image, for: "track-\(index)", cost: cost)
            XCTAssertEqual(cache.retainedBytes, cost * min(index + 1, 2))
        }
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(ImageCache.decode(Data([0, 1, 2])))
    }

    func testRepeatedTrackArtworkStaysWithinBudgetAndEvictsLRU() {
        let cache = ImageMemoryCache(limit: 1024)
        let image = PlatformImage()
        for index in 0..<1000 {
            cache.insert(image, for: "track-\(index)", cost: 256)
            XCTAssertLessThanOrEqual(cache.retainedBytes, 1024)
            XCTAssertLessThanOrEqual(cache.count, 4)
        }
        XCTAssertNil(cache.image(for: "track-0"))
        XCTAssertNotNil(cache.image(for: "track-996"))
        cache.insert(image, for: "new", cost: 256)
        XCTAssertNil(cache.image(for: "track-997"))
        XCTAssertNotNil(cache.image(for: "track-996"))
    }

    func testOversizedAndReplacementCostsAreAccounted() {
        let cache = ImageMemoryCache(limit: 1024)
        let image = PlatformImage()
        cache.insert(image, for: "a", cost: 512)
        cache.insert(image, for: "a", cost: 128)
        XCTAssertEqual(cache.retainedBytes, 128)
        cache.insert(image, for: "huge", cost: 2048)
        XCTAssertNil(cache.image(for: "huge"))
        XCTAssertEqual(cache.retainedBytes, 128)
    }

    func testEvictionReleasesImage() {
        let cache = ImageMemoryCache(limit: 128)
        var image: PlatformImage? = PlatformImage()
        let reference = WeakImageReference(image)
        cache.insert(image!, for: "old", cost: 128)
        image = nil
        XCTAssertNotNil(reference.value)
        cache.insert(PlatformImage(), for: "new", cost: 128)
        XCTAssertNil(reference.value)
    }

    func testTinyArtworkAlsoHasObjectCountLimit() {
        let cache = ImageMemoryCache()
        for index in 0..<1000 {
            cache.insert(PlatformImage(), for: "tiny-\(index)", cost: 4)
        }
        XCTAssertEqual(cache.count, 300)
        XCTAssertEqual(cache.retainedBytes, 1200)
    }
}
