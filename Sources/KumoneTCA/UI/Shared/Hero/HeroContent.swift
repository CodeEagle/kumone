import SwiftUI

/// Payload and destination styling of a flying stand-in.
enum HeroContent: Equatable {
    case artwork(url: URL?, cornerRadius: CGFloat)
    case text(String, color: Color, fontSize: CGFloat, weight: Font.Weight = .regular)
    case icon(name: String, tint: Color, background: HeroFill, diameter: CGFloat, fontSize: CGFloat)

    var cornerRadius: CGFloat {
        switch self {
        case let .artwork(_, cornerRadius): return cornerRadius
        case .text: return 0
        case let .icon(_, _, _, diameter, _): return diameter / 2
        }
    }
}

enum HeroFill: Equatable {
    case accent, white

    var style: AnyShapeStyle {
        switch self {
        case .accent: return AnyShapeStyle(Theme.accentGradient)
        case .white: return AnyShapeStyle(Color.white)
        }
    }
}
