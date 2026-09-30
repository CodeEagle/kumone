import ComposableArchitecture
import KumoneCore
import SwiftUI

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
            }
            .overlay(alignment: .trailing) {
                rightPanel
                    .opacity(chromeOpacity)
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

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .overlay {
                // Center the fade inside a full-height container, then ignore
                // the safe area: the band has to sit at the window's y=0 (the
                // titlebar rail), not at the navigation content's top inset.
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .frame(height: height)
                    .mask(
                        LinearGradient(
                            colors: [.black, .black.opacity(0.92), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
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
    func topFadeBlur(height: CGFloat = 52) -> some View {
        modifier(TopFadeBlur(height: height))
    }
}

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
