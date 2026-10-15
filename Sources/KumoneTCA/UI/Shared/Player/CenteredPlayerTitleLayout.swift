import SwiftUI

/// How the title shares its row with the playback status badges.
enum PlayerTitleBadgePlacement {
    /// The title centers on its own and the badges follow its trailing edge.
    /// Used on the wide, lyric-less row: a short title keeps its badges close
    /// by, and only a truncating title pushes them all the way to the row's
    /// right edge (the centered title's two-sided badge allowance keeps them
    /// inside the row).
    case trailing
    /// The title and its badges center as one group, with the title yielding
    /// the badges' width only once. Used when a lyrics column narrows the
    /// row, so a long title stays readable for as long as possible.
    case grouped
}

struct CenteredPlayerTitleLayout: Layout {
    var spacing: CGFloat = 8
    var badgePlacement: PlayerTitleBadgePlacement = .grouped

    private func titleWidth(rowWidth: CGFloat, badgesWidth: CGFloat) -> CGFloat {
        switch badgePlacement {
        case .trailing:
            // Center the title; keep its trailing half clear of the badges
            // pinned at the right edge.
            return max(0, rowWidth - 2 * (badgesWidth + spacing))
        case .grouped:
            return max(0, rowWidth - badgesWidth - spacing)
        }
    }

    private func sizes(width: CGFloat, subviews: Subviews) -> (title: CGSize, badges: CGSize) {
        let badges = subviews[1].sizeThatFits(.unspecified)
        let title = subviews[0].sizeThatFits(
            ProposedViewSize(width: titleWidth(rowWidth: width, badgesWidth: badges.width), height: nil)
        )
        return (title, badges)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let idealTitle = subviews[0].sizeThatFits(.unspecified)
        let idealBadges = subviews[1].sizeThatFits(.unspecified)
        let idealWidth: CGFloat
        switch badgePlacement {
        case .trailing:
            idealWidth = idealTitle.width + 2 * (idealBadges.width + spacing)
        case .grouped:
            idealWidth = idealTitle.width + spacing + idealBadges.width
        }
        let width = proposal.width ?? idealWidth
        let size = sizes(width: width, subviews: subviews)
        return CGSize(width: width, height: max(size.title.height, size.badges.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let size = sizes(width: bounds.width, subviews: subviews)
        switch badgePlacement {
        case .trailing:
            subviews[0].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                              proposal: ProposedViewSize(size.title))
            subviews[1].place(at: CGPoint(x: bounds.midX + size.title.width / 2 + spacing,
                                          y: bounds.midY),
                              anchor: .leading, proposal: ProposedViewSize(size.badges))
        case .grouped:
            // The whole group — title plus badges — stays centred in the row;
            // a truncated long title leads just left of the centre and the
            // badges close it out at the trailing edge.
            let groupWidth = size.badges.width > 0
                ? size.title.width + spacing + size.badges.width : size.title.width
            let leading = bounds.midX - groupWidth / 2
            subviews[0].place(at: CGPoint(x: leading, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(size.title))
            subviews[1].place(at: CGPoint(x: leading + size.title.width + spacing, y: bounds.midY),
                              anchor: .leading, proposal: ProposedViewSize(size.badges))
        }
    }
}
