import ComposableArchitecture
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
        content
            .overlay(alignment: .bottomTrailing) {
                PlayerBar(appStore: appStore)
                    .frame(width: detailWidth)
            }
            .overlay(alignment: .trailing) {
                rightPanel
            }
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

enum SidebarItem: Hashable {
    case home
    case explore
    case fm
    case search
    case likedSongs
    case daily
    case recents
    case collections
    case cloud
    case playlist(Int)
}

/// A view-level navigation request. `AppFeature.pathElement(for:)` maps this
/// onto the state a pushed page needs; `AppFeature.openDestination` appends it.
enum Destination: Hashable {
    case playlist(Int)
    case radarPlaylist(Int)
    case album(Int)
    case artist(Int)
    case daily
    case toplists
    case recents
    case collections
    case cloud
    case search(String)
}

extension Array where Element == Destination {
    mutating func appendIfNotCurrent(_ destination: Destination) {
        guard last != destination else { return }
        append(destination)
    }
}

extension View {
    func playerChrome(appStore: StoreOf<AppFeature>, detailWidth: CGFloat) -> some View {
        modifier(PlayerChromeModifier(appStore: appStore, detailWidth: detailWidth))
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
