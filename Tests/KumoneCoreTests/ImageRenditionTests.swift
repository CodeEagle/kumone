import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import KumoneCore

private final class RenditionResponseProtocol: URLProtocol {
    static let lock = NSLock()
    static var data = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data = Self.lock.withLock { Self.data }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class WeakRenditionImage {
    weak var image: PlatformImage?
    init(_ image: PlatformImage) { self.image = image }
}

private final class WeakDiagnosticBitmap {
    weak var bitmap: CGImage?
    init(_ bitmap: CGImage) { self.bitmap = bitmap }
}

final class ImageRenditionTests: XCTestCase {
    func testLifetimeDiagnosticsDoNotKeepImageOrBitmapAlive() throws {
        let previous = UserDefaults.standard.object(forKey: "KumoneArtworkDiagnostics")
        UserDefaults.standard.set(true, forKey: "KumoneArtworkDiagnostics")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "KumoneArtworkDiagnostics") }
            else { UserDefaults.standard.removeObject(forKey: "KumoneArtworkDiagnostics") }
        }
        let data = try original()
        let references = try autoreleasepool { () throws -> (WeakRenditionImage, WeakDiagnosticBitmap) in
            let image = try XCTUnwrap(ImageCache.decode(data, rendition: .playback))
            let bitmap = try XCTUnwrap(image.cgImageRef)
            ArtworkLifetimeDiagnostics.snapshot(reason: "test-owner-live")
            return (WeakRenditionImage(image), WeakDiagnosticBitmap(bitmap))
        }
        ArtworkLifetimeDiagnostics.snapshot(reason: "test-owner-dropped")
        XCTAssertNil(references.0.image, "Diagnostics must not retain NSImage")
        XCTAssertNil(references.1.bitmap, "Diagnostics must not retain native CGImage")
    }

    private func original() throws -> Data {
        try autoreleasepool {
            let context = try XCTUnwrap(CGContext(data: nil, width: 3000, height: 1500,
                bitsPerComponent: 8, bytesPerRow: 3000 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1500))
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 1000, y: 0, width: 1000, height: 1500))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 2000, y: 0, width: 1000, height: 1500))
            let bitmap = try XCTUnwrap(context.makeImage())
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, bitmap, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
    }

    func testPlaybackLocationsProduceIndependentSquareBitmapsAtTheirPixelBudget() throws {
        let data = try original()
        for rendition in [ImageRendition.thumbnail, .systemArtwork, .playback] {
            let image = try XCTUnwrap(ImageCache.decode(data, rendition: rendition))
            let bitmap = try XCTUnwrap(image.cgImageRef)
            XCTAssertEqual(bitmap.width, rendition.maxPixelSize)
            XCTAssertEqual(bitmap.height, rendition.maxPixelSize)
            XCTAssertLessThanOrEqual(bitmap.bytesPerRow * bitmap.height,
                                    rendition.maxPixelSize * rendition.maxPixelSize * 4)
            // The center of the source is green; left/right edges were cropped.
            let pixel = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let center = try XCTUnwrap(bitmap.cropping(to: CGRect(x: bitmap.width / 2,
                y: bitmap.height / 2, width: 1, height: 1)))
            pixel.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let bytes = try XCTUnwrap(pixel.data).assumingMemoryBound(to: UInt8.self)
            XCTAssertGreaterThan(bytes[1], 240)
            XCTAssertLessThan(bytes[0], 15)
            XCTAssertLessThan(bytes[2], 15)
        }
    }

    func testAutomaticUsesLastCDNSizeAndClampsOversizedRequests() {
        XCTAssertEqual(ImageRendition.automatic(for: URL(string: "https://image.test/c?param=768y768&param=120y120")!),
                       ImageRendition(maxPixelSize: 120))
        XCTAssertEqual(ImageRendition.automatic(for: URL(string: "https://image.test/c?param=9000y9000")!).maxPixelSize, 1536)
        XCTAssertFalse(ImageRendition.automatic(for: URL(string: "https://image.test/banner")!).square)
    }

    func testTransientMemoryEntryDoesNotRetainPreviousTrack() {
        let cache = ImageMemoryCache()
        var image: PlatformImage? = PlatformImage()
        let weak = WeakRenditionImage(image!)
        cache.insert(image!, for: "track", cost: 96 * 96 * 4, transient: true)
        XCTAssertTrue(cache.image(for: "track") === image)
        XCTAssertEqual(cache.retainedBytes, 0)
        image = nil
        XCTAssertNil(weak.image)
        XCTAssertNil(cache.image(for: "track"))
        XCTAssertEqual(cache.residency.liveBytes, 0)
    }

    func testRepeatedTrackRenditionsReleaseEveryPreviousImage() throws {
        let data = try original()
        let cache = ImageMemoryCache()
        var references: [WeakRenditionImage] = []
        for index in 0..<20 {
            try autoreleasepool {
                let image = try XCTUnwrap(ImageCache.decode(data, rendition: .playback))
                cache.insert(image, for: "track-\(index)", cost: 768 * 768 * 4, transient: true)
                references.append(WeakRenditionImage(image))
            }
        }
        XCTAssertTrue(references.allSatisfy { $0.image == nil })
        XCTAssertEqual(cache.retainedBytes, 0)
        XCTAssertEqual(cache.residency.liveBytes, 0)
    }

    func testOversizedServerResponseIsBoundedAndTransientCacheReleasesAfterLastConsumer() async throws {
        let data = try original()
        RenditionResponseProtocol.lock.withLock { RenditionResponseProtocol.data = data }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RenditionResponseProtocol.self]
        let session = URLSession(configuration: config)
        let cache = ImageCache(diskURL: directory, session: session)
        defer {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: directory)
            RenditionResponseProtocol.lock.withLock { RenditionResponseProtocol.data = Data() }
        }
        let url = URL(string: "https://image.test/cover?param=120y120")!
        let loadedListImage = await cache.image(for: url)
        let listImage = try XCTUnwrap(loadedListImage)
        XCTAssertEqual(listImage.cgImageRef?.width, 120)
        XCTAssertEqual(listImage.cgImageRef?.height, 120)
        var playbackImage = await cache.image(for: url, rendition: .playback)
        let weak = WeakRenditionImage(try XCTUnwrap(playbackImage))
        XCTAssertEqual(playbackImage?.cgImageRef?.width, 768)
        XCTAssertTrue(cache.cachedImage(for: url, rendition: .playback) === playbackImage)
        XCTAssertTrue(cache.cachedImage(for: url) === listImage)
        playbackImage = nil
        await Task.yield()
        XCTAssertNil(weak.image)
        XCTAssertNil(cache.cachedImage(for: url, rendition: .playback))
        // Persistent list thumbnail is independent from the transient page.
        XCTAssertNotNil(cache.cachedImage(for: url))
    }
}
