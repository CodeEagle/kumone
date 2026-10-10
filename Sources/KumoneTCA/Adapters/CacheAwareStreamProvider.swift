import APlay
import Foundation

/// APlay 2.2.0 reports the local read cursor as bufferingProgress even on a
/// completed disk-cache hit. Bytes already on disk are fully available; only
/// sparse `.part` containers must retain the upstream downloaded-byte ratio.
/// This adapter changes progress reporting, not cache naming, HTTP or decoding.
final class CacheAwareStreamProvider: StreamProviderCompatible {
    private static let upstreamBuilder = APlay.Configuration(logPolicy: .disable).streamerBuilder
    private let upstream: StreamProviderCompatible

    required init(config: ConfigurationCompatible) {
        upstream = Self.upstreamBuilder(config)
    }

    init(upstream: StreamProviderCompatible) { self.upstream = upstream }

    var outputPipeline: Delegated<StreamProvider.Event, Void> { upstream.outputPipeline }
    var position: StreamProvider.Position { upstream.position }
    var contentLength: UInt { upstream.contentLength }
    var info: StreamProvider.URLInfo { upstream.info }
    var bufferingProgress: Float {
        Self.availableProgress(info: info, contentLength: contentLength, readProgress: upstream.bufferingProgress)
    }

    static func availableProgress(info: StreamProvider.URLInfo, contentLength: UInt, readProgress: Float) -> Float {
        if case let .local(url, _) = info, contentLength > 0, url.pathExtension != "part" { return 1 }
        return readProgress
    }

    func open(url: URL, at position: StreamProvider.Position) { upstream.open(url: url, at: position) }
    func destroy() { upstream.destroy() }
    func pause() { upstream.pause() }
    func resume() { upstream.resume() }
}
