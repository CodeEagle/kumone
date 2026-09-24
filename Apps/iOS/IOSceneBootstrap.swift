import UIKit
import KumoneTCA

@MainActor
enum IOSceneBootstrap {
    /// The iOS window and CarPlay scene will host this shared store once the
    /// UIKit rewrite lands; held here so the composition root is live in the
    /// iOS process during the skeleton phase.
    static let store = IOSAppStore.store
}
