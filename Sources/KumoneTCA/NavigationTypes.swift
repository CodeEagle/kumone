// NavigationTypes.swift
//
// Pure navigation value types shared by the TCA feature layer and the UI layer.
// Kept free of `View`/`ViewModifier` dependencies so the navigation model can be
// reasoned about (and unit-tested) independently of SwiftUI.

/// Sidebar selection in the main navigation split view.
public enum SidebarItem: Hashable {
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
public enum Destination: Hashable {
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
    public mutating func appendIfNotCurrent(_ destination: Destination) {
        guard last != destination else { return }
        append(destination)
    }
}
