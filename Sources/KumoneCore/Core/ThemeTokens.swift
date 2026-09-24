import Foundation

/// Pure-CGFloat design tokens shared with KumoneCore; UI layer bridges via
/// `Theme` typealias in ThemeUI.swift.
public enum ThemeTokens {
    public enum Radius {
        public static let badge: CGFloat = 4
        public static let small: CGFloat = 6
        public static let standard: CGFloat = 8
        public static let large: CGFloat = 12
        public static let panel: CGFloat = 20
    }

    public enum Layout {
        public static let contentInset: CGFloat = 24
        public static let cardSize: CGFloat = 160
        /// Row height for a shelf of cover cards: artwork, then up to two lines
        /// of title and one of subtitle.
        public static let coverShelfHeight: CGFloat = 226
        /// Row height for a shelf of artist cards: circular artwork, one name.
        public static let artistShelfHeight: CGFloat = 196
        public static let sidebarWidth: CGFloat = 220
        public static let playerBarHeight: CGFloat = 56
        /// Gap between the floating player bar and the window's bottom edge.
        /// Must match the bar's own `.padding(.bottom,)` in PlayerBar.
        public static let playerBarBottomMargin: CGFloat = 16
        /// Bottom inset pages need so scrolled content clears the floating bar.
        public static var playerChromeClearance: CGFloat { playerBarHeight + playerBarBottomMargin }
        /// Extra breathing margin for scrollable content clearing chrome.
        public static let scrollBreathingMargin: CGFloat = 8

        #if os(iOS)
        public enum FloatingChrome {
            /// Total height of GlassTabBar: 56pt content + 2 * 4pt inset.
            public static let tabBarHeight: CGFloat = 64
            /// Total height of legacy mini player bar: 44pt button + 2 * 4pt vertical padding.
            public static let miniPlayerHeight: CGFloat = 52
            /// Spacing between mini player and tab bar in customTabInterface.
            public static let barSpacing: CGFloat = 8
            /// Bottom padding under the tab bar.
            public static let bottomMargin: CGFloat = 6
            /// Breathing margin ensuring content clears above the floating bars.
            public static let extraPadding: CGFloat = 12

            /// Clearance needed when only the tab bar is visible.
            public static var tabBarClearance: CGFloat {
                tabBarHeight + bottomMargin + extraPadding
            }

            /// Clearance needed when both mini player and tab bar are visible.
            public static var fullChromeClearance: CGFloat {
                miniPlayerHeight + barSpacing + tabBarHeight + bottomMargin + extraPadding
            }
        }
        #endif
        public static let minWindowWidth: CGFloat = 1020
        /// Width the split view's divider occupies between the two columns.
        public static let splitDividerWidth: CGFloat = 8
        /// Window minimum while the sidebar is collapsed. The window-wide
        /// minimum is a *content* constraint, so with the sidebar hidden it
        /// lands entirely on the detail column; restoring the sidebar would
        /// then add its width on top and `.contentMinSize` would widen the
        /// window every time the now-playing page is dismissed (#19).
        /// Subtracting the sidebar here keeps the restored total at
        /// `minWindowWidth`.
        public static var minWindowWidthSidebarCollapsed: CGFloat {
            minWindowWidth - sidebarWidth - splitDividerWidth
        }
        public static let minWindowHeight: CGFloat = 640
        public static let defaultWindowWidth: CGFloat = 1200
        public static let defaultWindowHeight: CGFloat = 780
    }
}
