import ComposableArchitecture
import KumoneCore
import SwiftUI

#if os(macOS)
import AppKit
#endif

// MARK: - Environment

extension EnvironmentValues {
    /// The composition root, injected by `MainWindow` / `IOSMainWindow`. Shared
    /// leaf views (the clearance spacer, the track row) read it here rather than
    /// threading player/account/settings stores through every page.
    @Entry var appStore: StoreOf<AppFeature>?
}

private struct OpenLoginKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private struct OpenDestinationKey: EnvironmentKey {
    static let defaultValue: (Destination) -> Void = { _ in }
}

extension EnvironmentValues {
    var openLogin: () -> Void {
        get { self[OpenLoginKey.self] }
        set { self[OpenLoginKey.self] = newValue }
    }

    var openDestination: (Destination) -> Void {
        get { self[OpenDestinationKey.self] }
        set { self[OpenDestinationKey.self] = newValue }
    }
}

struct PlayerChromeModifier: ViewModifier {
    let appStore: StoreOf<AppFeature>
    let detailWidth: CGFloat

    func body(content: Content) -> some View {
        // Hidden but mounted while the immersive page is up: keeping layout
        // means the mini player's hero anchors keep measuring their frames,
        // and the window-level shader shows through the page's thin veil.
        let chromeOpacity = appStore.isNowPlayingPresented ? 0.0 : 1.0
        content
            .overlay(alignment: .bottomTrailing) {
                PlayerBar(appStore: appStore)
                    .frame(width: detailWidth)
                    .opacity(chromeOpacity)
                    // The chrome stays mounted (the mini player's hero anchors
                    // keep measuring) but must not soak up taps while the
                    // immersive page is up: an invisible LyricsPanel over the
                    // right edge was eating the page's top-trailing buttons.
                    .allowsHitTesting(chromeOpacity > 0)
            }
            .overlay(alignment: .trailing) {
                rightPanel
                    .opacity(chromeOpacity)
                    .allowsHitTesting(chromeOpacity > 0)
            }
            .animation(AppAnimation.quick, value: appStore.isNowPlayingPresented)
            .animation(AppAnimation.standard, value: appStore.player.activePanel)
    }

    @ViewBuilder
    private var rightPanel: some View {
        if let panel = appStore.player.activePanel {
            Group {
                switch panel {
                case .lyrics:
                    LyricsPanel(appStore: appStore)
                case .queue:
                    QueuePanel(appStore: appStore)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, Theme.Layout.playerChromeClearance + 10)
            .padding(.trailing, 16)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
}

extension View {
    func playerChrome(appStore: StoreOf<AppFeature>, detailWidth: CGFloat) -> some View {
        modifier(PlayerChromeModifier(appStore: appStore, detailWidth: detailWidth))
    }
}

/// A blurred fade covering the window's top edge: full-strength material at
/// the titlebar's bottom rail thinning to nothing over `height` points. The
/// window toolbar's Liquid Glass sits above this band, so content scrolling
/// up to it softens out instead of colliding with the chrome (same trick as
/// the lyrics column's edge fade). Non-interactive and a no-op on iOS, whose
/// main window has no titlebar to clear.
struct TopFadeBlur: ViewModifier {
    var height: CGFloat = 52
    var progress: CGFloat = 0

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .overlay {
                // Center the fade inside a full-height container, then ignore
                // the safe area: the band has to sit at the window's y=0 (the
                // titlebar rail), not at the navigation content's top inset.
                Rectangle()
                    // Material only: blur the content underneath without
                    // tinting it black or white. The mask controls how far
                    // the transparent blur reaches into the page.
                    .fill(.ultraThinMaterial)
                    .frame(height: height)
                    .mask(
                        LinearGradient(
                            colors: [.white, .white.opacity(0.62), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
                    .opacity(progress)
                    .animation(.easeOut(duration: 0.12), value: progress)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        #else
        content
        #endif
    }
}

extension View {
    /// Blurred top fade so content clears the window titlebar (macOS only).
    func topFadeBlur(height: CGFloat = 52, progress: CGFloat = 0) -> some View {
        modifier(TopFadeBlur(height: height, progress: progress))
    }
}

#if os(macOS)
/// Publishes a normalized scroll distance for the window's content. The
/// navigation stack owns several lazily-created NSScrollViews, so observing
/// the window keeps this independent from individual page implementations.
@MainActor
final class TopScrollProgress: ObservableObject {
    @Published var value: CGFloat = 0
}

struct TopScrollProgressProbe: NSViewRepresentable {
    @ObservedObject var progress: TopScrollProgress

    func makeNSView(context: Context) -> ProbeView {
        ProbeView(progress: progress)
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.progress = progress
    }

    @MainActor
    final class ProbeView: NSView {
        var progress: TopScrollProgress
        private var timer: Timer?
        private var samplingStartsAt = Date.distantPast

        init(progress: TopScrollProgress) {
            self.progress = progress
            super.init(frame: .zero)
            isHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate()
            guard window != nil else { return }
            samplingStartsAt = Date().addingTimeInterval(0.35)
            progress.value = 0
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sample()
                }
            }
            sample()
        }

        deinit { timer?.invalidate() }

        func sample() {
            guard Date() >= samplingStartsAt else { return }
            guard let root = window?.contentView else {
                progress.value = 0
                return
            }
            // The window also contains the sidebar's scroll view and transient
            // navigation scroll views. The largest visible scroll view is the
            // page content; using its offset avoids treating a sidebar/layout
            // transition as a real content scroll.
            let contentScrollView = scrollViews(in: root)
                .filter { $0.bounds.width > 300 && $0.bounds.height > 300 }
                .max { lhs, rhs in
                    (lhs.bounds.width * lhs.bounds.height) < (rhs.bounds.width * rhs.bounds.height)
                }
            let offset = max(0, contentScrollView?.contentView.bounds.origin.y ?? 0)
            let next = min(max(offset / 64, 0), 1)
            guard abs(progress.value - next) > 0.001 else { return }
            progress.value = next
        }

        private func scrollViews(in view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { child in
                ((child as? NSScrollView).map { [$0] } ?? [])
                    + scrollViews(in: child)
            }
        }
    }
}
#endif

/// Trailing spacer for scrollable pages so the last row clears the
/// floating player bar.
struct PlayerClearanceSpacer: View {
    @Environment(\.appStore) private var appStore

    var body: some View {
        let hasCurrentTrack = appStore?.player.hasCurrentTrack ?? false
        #if os(iOS)
        if #available(iOS 26.0, *) {
            // On iOS 26+, the native TabView bottom accessory automatically
            // expands the content safe area insets; keep only the breathing margin.
            Color.clear.frame(height: Theme.Layout.scrollBreathingMargin)
        } else {
            // On iOS < 26, customTabInterface floats above content and requires
            // explicit bottom clearance.
            Color.clear.frame(
                height: hasCurrentTrack
                    ? Theme.Layout.FloatingChrome.fullChromeClearance
                    : Theme.Layout.FloatingChrome.tabBarClearance
            )
        }
        #else
        Color.clear.frame(
            height: Theme.Layout.playerChromeClearance + Theme.Layout.scrollBreathingMargin
        )
        #endif
    }
}
