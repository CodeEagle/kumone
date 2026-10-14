#if os(macOS)
import AppKit

/// Layout markers sampled by the shader renderer, in the same native window.
/// Weak references prevent a dismissed page from keeping blur regions alive.
@MainActor
public enum ShaderBlurRegions {
    public struct Region {
        public var rectangle: SIMD4<Float>
        public var feather: SIMD2<Float>
    }

    private final class Marker {
        weak var view: NSView?
        var feather: SIMD2<Float>
        init(_ view: NSView, feather: SIMD2<Float>) {
            self.view = view
            self.feather = feather
        }
    }
    private static var markers: [ObjectIdentifier: Marker] = [:]

    public static func register(_ view: NSView, feather: SIMD2<Float> = SIMD2(0.12, 0.16)) {
        markers[ObjectIdentifier(view)] = Marker(view, feather: feather)
    }
    public static func unregister(_ view: NSView) {
        markers.removeValue(forKey: ObjectIdentifier(view))
    }
    public static func rectangles(in surface: NSView) -> [SIMD4<Float>] {
        regions(in: surface).map(\.rectangle)
    }
    public static func regions(in surface: NSView) -> [Region] {
        markers = markers.filter { $0.value.view != nil }
        guard let window = surface.window, surface.bounds.width > 0, surface.bounds.height > 0 else { return [] }
        return markers.values.compactMap { marker in
            guard let view = marker.view, view.window === window,
                  !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0 else { return nil }
            let rect = surface.convert(view.bounds, from: view)
            guard rect.width > 0, rect.height > 0 else { return nil }
            let y = surface.isFlipped ? rect.minY : surface.bounds.height - rect.maxY
            return Region(rectangle: SIMD4(Float(rect.minX / surface.bounds.width), Float(y / surface.bounds.height),
                         Float(rect.width / surface.bounds.width), Float(rect.height / surface.bounds.height)),
                          feather: marker.feather)
        }
    }
}
#endif
