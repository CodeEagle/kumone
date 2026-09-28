import Foundation

/// Payload of a flying stand-in. Only artwork is rendered in phase one.
enum HeroContent: Equatable {
    case artwork(url: URL?, cornerRadius: CGFloat)
    case text(String)
    case icon(String)

    var cornerRadius: CGFloat {
        switch self {
        case let .artwork(_, cornerRadius): return cornerRadius
        case .text, .icon: return 0
        }
    }
}
