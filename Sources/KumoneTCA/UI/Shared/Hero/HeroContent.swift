import SwiftUI
import KumoneCore

/// Payload and destination styling of a flying stand-in.
enum HeroContent: Equatable {
    case artwork(url: URL?, cornerRadius: CGFloat)
    case playerTitle(String)
    case playerArtist(Track)
    case vipBadge
    case qualityBadge(String, isAvailable: Bool)
    case text(String, color: Color, fontSize: CGFloat, weight: Font.Weight = .regular)
    case icon(name: String, tint: Color, background: HeroFill, diameter: CGFloat, fontSize: CGFloat, weight: Font.Weight = .bold)
    /// The system AirPlay route picker itself: an SF Symbol stand-in cannot
    /// match AVRoutePickerView's private glyph, so the flight carries the
    /// real button's styling and the stand-in renders the real control.
    case routePicker(diameter: CGFloat, glyphSize: CGFloat, tint: Color, background: Color)

    var cornerRadius: CGFloat {
        switch self {
        case let .artwork(_, cornerRadius): return cornerRadius
        case .text, .playerTitle, .playerArtist, .vipBadge, .qualityBadge, .routePicker: return 0
        case let .icon(_, _, background, diameter, _, _): return background == .none ? 0 : diameter / 2
        }
    }
}

enum HeroFill: Equatable {
    case accent, white, none, translucentWhite, translucentBlack

    var style: AnyShapeStyle {
        switch self {
        case .accent: return AnyShapeStyle(Theme.accentGradient)
        case .white: return AnyShapeStyle(Color.white)
        case .none: return AnyShapeStyle(Color.clear)
        case .translucentBlack: return AnyShapeStyle(Color.black.opacity(0.28))
        case .translucentWhite: return AnyShapeStyle(Color.white.opacity(0.1))
        }
    }
}
