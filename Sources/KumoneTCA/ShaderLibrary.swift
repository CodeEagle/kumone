import Foundation
import Combine
import KumoneCore

/// UI observation shell over `ShaderDiscovery`.
///
/// Owns no Metal logic: compilation, caching and directory scanning all live in
/// the discovery layer. This type only publishes the list of available shaders
/// so SwiftUI views re-render when the directory is rescanned.
@MainActor
final class ShaderLibrary: ObservableObject {
    static let shared = ShaderLibrary()

    /// Shaders found the last time the directory was scanned. Published so a
    /// view that read the list before the first `reload()` re-renders once the
    /// scan has something to show.
    @Published private(set) var available: [ShaderDescriptor] = []

    private init() {
        available = ShaderDiscovery.shared.availableDescriptors
    }

    /// Reloads the shader list via the discovery layer, then mirrors the result
    /// into `available`. The discovery layer invalidates its cache itself.
    func reload() {
        ShaderDiscovery.shared.reload()
        available = ShaderDiscovery.shared.availableDescriptors
    }
}
