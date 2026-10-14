import KumoneCore
import SwiftUI

/// AsyncImage replacement backed by `ImageCache`, with a crossfade reveal.
struct CachedAsyncImage<Placeholder: View>: View {
    let url: URL?
    var animated: Bool = true
    var rendition: ImageRendition?
    var fallbackURL: URL?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: PlatformImage?
    @State private var loadedURL: URL?
    @State private var loadedRendition: ImageRendition?
    @State private var loadGeneration: UInt64 = 0
    @ObservedObject private var imageLoading = ImageLoadingControl.shared

    private struct RequestID: Equatable {
        let url: URL?
        let rendition: ImageRendition?
        let disabled: Bool
    }

    init(url: URL?, animated: Bool = true, rendition: ImageRendition? = nil,
         fallbackURL: URL? = nil, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.animated = animated
        self.rendition = rendition
        self.fallbackURL = fallbackURL
        self.placeholder = placeholder
        // Keep State's initial value empty: lazy lists can retain the view
        // value as well as its mounted State location. A strong image seed
        // there would survive clearing the mounted state on disappearance.
        // The body still reads resident images synchronously, without flashing.
        _image = State(initialValue: nil)
        _loadedURL = State(initialValue: nil)
    }

    private var residentImage: PlatformImage? {
        guard let url else { return nil }
        if let exact = ImageCache.shared.cachedImage(for: url, rendition: rendition) { return exact }
        // A cold minibar -> page hero can draw the already-visible thumbnail
        // while the page-sized image loads. Do not pin a 768px cover in the
        // minibar just to keep that transition populated.
        if rendition == .playback {
            return ImageCache.shared.cachedImage(for: url, rendition: .thumbnail)
        }
        if let fallbackURL { return ImageCache.shared.cachedImage(for: fallbackURL) }
        return nil
    }

    var body: some View {
        ZStack {
            placeholder()
            if !imageLoading.isDisabled,
               let image = (loadedURL == url && loadedRendition == rendition ? image : nil)
                ?? residentImage {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(animated ? .opacity.animation(.easeIn(duration: 0.22)) : .identity)
            }
        }
        .task(id: RequestID(url: url, rendition: rendition, disabled: imageLoading.isDisabled)) {
            guard !Task.isCancelled else { return }
            loadGeneration &+= 1
            let generation = loadGeneration
            guard !imageLoading.isDisabled, let url else {
                image = nil
                loadedURL = nil
                loadedRendition = nil
                return
            }
            guard url != loadedURL || rendition != loadedRendition else { return }
            image = nil
            loadedURL = nil
            loadedRendition = nil
            // Synchronous memory hit first — no actor hop, no placeholder frame.
            if let memoryHit = ImageCache.shared.cachedImage(for: url, rendition: rendition) {
                image = memoryHit
                loadedURL = url
                loadedRendition = rendition
                return
            }
            if let cached = await ImageCache.shared.image(for: url, rendition: rendition) {
                guard !imageLoading.isDisabled, !Task.isCancelled, generation == loadGeneration else { return }
                image = cached
                loadedURL = url
                loadedRendition = rendition
            }
        }
        .onChange(of: imageLoading.isDisabled) { _, disabled in
            if disabled {
                loadGeneration &+= 1
                image = nil
                loadedURL = nil
                loadedRendition = nil
            }
        }
        .onDisappear {
            if rendition == .playback, ArtworkLifetimeDiagnostics.isEnabled {
                let address = image.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
                KumoneLogger.player.notice("ARTLIFE flight-image-disappear image=\(address, privacy: .public)")
            }
            // Lazy lists may retain offscreen row state after the shared cache
            // evicts its cover. Do not let that state pin a second image cache.
            // Reset the URL too, so the next appearance reloads normally.
            loadGeneration &+= 1
            image = nil
            loadedURL = nil
            loadedRendition = nil
            if rendition == .playback { ArtworkLifetimeDiagnostics.snapshot(reason: "flight-image-cleared") }
        }
    }
}

extension CachedAsyncImage where Placeholder == AnyView {
    /// Default placeholder: a quiet neutral fill with a music note.
    init(url: URL?, animated: Bool = true, rendition: ImageRendition? = nil, fallbackURL: URL? = nil) {
        self.init(url: url, animated: animated, rendition: rendition, fallbackURL: fallbackURL) {
            AnyView(
                ZStack {
                    Rectangle().fill(.quaternary.opacity(0.5))
                    Image(systemName: "music.note")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.quaternary)
                }
            )
        }
    }
}
