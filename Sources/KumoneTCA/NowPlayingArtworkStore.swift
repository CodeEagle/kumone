import Foundation
import Combine
import KumoneCore

/// Shares the current track artwork and palette between app surfaces.
@MainActor
public final class NowPlayingArtworkStore: ObservableObject {
    public typealias ImageLoader = (URL) async -> PlatformImage?

    @Published public private(set) var colors: ArtworkColors = .fallback
    @Published private(set) var artwork: PlatformImage?
    @Published private(set) var trackID: Int?

    private struct Request: Equatable {
        let trackID: Int
        let artworkURL: String
        let imageURL: URL
    }

    private let imageLoader: ImageLoader
    private var request: Request?
    private var loadTask: Task<Void, Never>?
    private var artworkURL: String?
    private var artworkIsNeeded = false

    public init(imageLoader: @escaping ImageLoader = { url in
        await ImageCache.shared.image(for: url)
    }) {
        self.imageLoader = imageLoader
    }

    public func update(trackID: Int?, artworkURL: String?) {
        guard self.trackID != trackID || self.artworkURL != artworkURL else { return }

        cancelArtworkLoad()
        self.trackID = trackID
        self.artworkURL = artworkURL
        artwork = nil
        // Keep the previous track's palette while the new cover loads: the
        // shader reads `colors` and its palette mixer eases toward whatever it
        // holds, so resetting to `.fallback` here made every track change flash
        // the grey-blue placeholder before the new colour arrived. When there
        // is nothing to load for this track the loader below leaves the old
        // colours standing, which still reads closer to the artwork than grey.

        loadArtworkForCurrentTrack()
    }

    public func setArtworkNeeded(_ artworkIsNeeded: Bool) {
        guard self.artworkIsNeeded != artworkIsNeeded else { return }
        self.artworkIsNeeded = artworkIsNeeded

        if artworkIsNeeded {
            loadArtworkForCurrentTrack()
        } else {
            cancelArtworkLoad()
            artwork = nil
            colors = .fallback
        }
    }

    private func loadArtworkForCurrentTrack() {
        guard artworkIsNeeded else { return }

        guard let trackID,
              let artworkURL,
              let imageURL = artworkURL.resizedImageURL(768) else {
            return
        }

        let request = Request(
            trackID: trackID,
            artworkURL: artworkURL,
            imageURL: imageURL
        )
        self.request = request
        let imageLoader = imageLoader
        loadTask = Task { [weak self] in
            let image = await imageLoader(request.imageURL)
            guard !Task.isCancelled,
                  let self,
                  self.request == request else {
                return
            }

            self.loadTask = nil
            guard let image else { return }
            self.artwork = image
            if let cgImage = image.cgImageRef {
                self.colors = ArtworkPalette.extract(from: cgImage, cacheKey: request.artworkURL)
            }
        }
    }

    private func cancelArtworkLoad() {
        loadTask?.cancel()
        loadTask = nil
        request = nil
    }
}
