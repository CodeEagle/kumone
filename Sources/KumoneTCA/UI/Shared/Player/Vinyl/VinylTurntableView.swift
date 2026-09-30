import KumoneCore
import SwiftUI

/// The vinyl disc's role as the now-playing artwork's hero landing.
///
/// In vinyl mode the square cover is replaced by a turntable, so the cover's
/// flight would have nothing to land on. This bundles the flight target
/// plumbing (landing id, anchor id, payload, presentation state) so the
/// turntable can carry it exactly where the now-playing page carries the
/// square cover's.
public struct VinylHeroTarget {
    /// The hero id the armed mini-player source pairs with
    /// (`HeroID.nowPlayingArtwork`).
    public let id: String
    /// The anchor id the record's label reports its frame under
    /// (`HeroID.nowPlayingArtworkTarget`).
    public let anchorID: String
    public let artworkURL: URL?
    /// Landing corner radius — the label is a circle, so pass
    /// `labelDiameter / 2`.
    public let cornerRadius: CGFloat
    public let scale: CGFloat
    public let isPresented: Bool
    public var hasStarted: Binding<Bool>

    public init(
        id: String,
        anchorID: String,
        artworkURL: URL?,
        cornerRadius: CGFloat,
        scale: CGFloat = 1,
        isPresented: Bool,
        hasStarted: Binding<Bool>
    ) {
        self.id = id
        self.anchorID = anchorID
        self.artworkURL = artworkURL
        self.cornerRadius = cornerRadius
        self.scale = scale
        self.isPresented = isPresented
        self.hasStarted = hasStarted
    }
}

/// Complete interactive turntable stage combining rotating vinyl disc, tonearm,
/// continuous timeline rotation, tap-to-flip, and horizontal swipe-to-switch tracks.
public struct VinylTurntableView: View {
    public let artworkImage: PlatformImage?
    public let isPlaying: Bool
    public let trackId: Int?
    public let size: CGFloat
    public var onTap: (() -> Void)? = nil
    public var onNextTrack: (() -> Void)? = nil
    public var onPreviousTrack: (() -> Void)? = nil
    /// When set, the record's center label anchors a hero flight: the cover
    /// flies from the mini player and lands on the label. Nil on platforms
    /// without the hero machinery, where the modifier below is a no-op.
    public var heroTarget: VinylHeroTarget? = nil

    @State private var rotationState = RecordRotationState()
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var isTransitioningTrack = false

    public init(
        artworkImage: PlatformImage?,
        isPlaying: Bool,
        trackId: Int? = nil,
        size: CGFloat = 280,
        onTap: (() -> Void)? = nil,
        onNextTrack: (() -> Void)? = nil,
        onPreviousTrack: (() -> Void)? = nil,
        heroTarget: VinylHeroTarget? = nil
    ) {
        self.artworkImage = artworkImage
        self.isPlaying = isPlaying
        self.trackId = trackId
        self.size = size
        self.onTap = onTap
        self.onNextTrack = onNextTrack
        self.onPreviousTrack = onPreviousTrack
        self.heroTarget = heroTarget
    }

    public var body: some View {
        let discSize = size
        let armHeight = discSize * 0.68
        let stageWidth = discSize + 48
        let stageHeight = discSize + armHeight * 0.38

        return ZStack(alignment: .top) {
            // MARK: 1. Rotating Vinyl Disc (with horizontal drag & slide transitions)
            TimelineView(.animation(paused: !isPlaying || isDragging || isTransitioningTrack)) { timeline in
                let currentAngle = rotationState.currentAngle(at: timeline.date)

                VinylRecordView(artworkImage: artworkImage, size: discSize)
                    .rotationEffect(.degrees(currentAngle))
            }
            .labelAnchor(heroTarget, discSize: discSize)
            .offset(x: dragOffset)
            .padding(.top, armHeight * 0.36)
            .contentShape(Circle())
            .gesture(dragAndSwipeGesture(discSize: discSize))
            .onTapGesture {
                onTap?()
            }
            .zIndex(1)

            // MARK: 2. Tonearm (Placed at the top-center above the disc, reaching down)
            VinylTonearmView(
                isPlaying: isPlaying && !isDragging && !isTransitioningTrack,
                height: armHeight
            )
            .offset(x: discSize * 0.12, y: -armHeight * 0.08)
            .allowsHitTesting(false)
            .zIndex(2)
        }
        .frame(width: stageWidth, height: stageHeight, alignment: .top)
        .onAppear {
            if isPlaying {
                rotationState.start(at: Date())
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                rotationState.start(at: Date())
            } else {
                rotationState.stop(at: Date())
            }
        }
        .onChange(of: trackId) {
            // Temporarily lift tonearm on track change
            isTransitioningTrack = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 320_000_000)
                isTransitioningTrack = false
            }
        }
    }
}

private extension View {
    /// Anchors the record's center label for a hero landing.
    ///
    /// A clear circle stands in for the label's geometry: the label sits at the
    /// disc's exact centre and is itself circular, so a centred circle of the
    /// label's diameter (`0.64 × disc`) reports the same frame without threading
    /// the anchor into the spinning sub-tree — where every geometry pass would
    /// run under the rotation transform and the reported frame would wobble
    /// with the record's sway. Attached outside the rotation, it reports the
    /// stable layout frame and follows the disc when the column re-centres.
    @ViewBuilder
    func labelAnchor(_ target: VinylHeroTarget?, discSize: CGFloat) -> some View {
        if let target {
            overlay {
                // Match `VinylRecordView`'s label-to-disc ratio.
                Color.clear
                    .frame(width: discSize * 0.64, height: discSize * 0.64)
                    .heroAnchor(target.anchorID, scale: target.scale)
                    .nowPlayingHeroTarget(
                        id: target.id,
                        content: .artwork(url: target.artworkURL, cornerRadius: target.cornerRadius),
                        scale: target.scale,
                        anchorID: target.anchorID,
                        isPresented: target.isPresented,
                        hasStarted: target.hasStarted
                    )
            }
        }
    }
}

// MARK: - Gestures

private extension VinylTurntableView {
    func dragAndSwipeGesture(discSize: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                // Only track horizontal gestures
                if abs(value.translation.width) > abs(value.translation.height) * 0.6 {
                    isDragging = true
                    let raw = value.translation.width
                    // Damped elastic feel
                    dragOffset = raw
                }
            }
            .onEnded { value in
                let translation = value.translation.width
                let velocity = value.predictedEndTranslation.width
                let swipeThreshold: CGFloat = 45

                if translation < -swipeThreshold || velocity < -100 {
                    // Swipe Left -> Next Track (下一首)
                    withAnimation(.easeOut(duration: 0.20)) {
                        dragOffset = -discSize * 1.25
                    }
                    onNextTrack?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        dragOffset = discSize * 1.25
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) {
                            dragOffset = 0
                            isDragging = false
                        }
                    }
                } else if translation > swipeThreshold || velocity > 100 {
                    // Swipe Right -> Previous Track (上一首)
                    withAnimation(.easeOut(duration: 0.20)) {
                        dragOffset = discSize * 1.25
                    }
                    onPreviousTrack?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        dragOffset = -discSize * 1.25
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) {
                            dragOffset = 0
                            isDragging = false
                        }
                    }
                } else {
                    // Reset back to center
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.76)) {
                        dragOffset = 0
                        isDragging = false
                    }
                }
            }
    }
}
