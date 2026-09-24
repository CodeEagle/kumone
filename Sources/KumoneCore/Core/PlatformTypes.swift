import Foundation

#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
public typealias PlatformView = NSView
public typealias PlatformFont = NSFont
#elseif os(iOS) || os(tvOS) || os(visionOS)
import UIKit
public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
public typealias PlatformView = UIView
public typealias PlatformFont = UIFont
#endif

#if os(macOS)
public extension PlatformImage {
    /// Backing `CGImage` for the palette/shader pipelines (`ArtworkPalette`,
    /// `ShaderPaletteBuilder`).
    var cgImageRef: CGImage? {
        var rect = NSRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
#elseif os(iOS) || os(tvOS) || os(visionOS)
public extension PlatformImage {
    /// Backing `CGImage` for the palette/shader pipelines (`ArtworkPalette`,
    /// `ShaderPaletteBuilder`).
    var cgImageRef: CGImage? {
        cgImage
    }
}
#endif
