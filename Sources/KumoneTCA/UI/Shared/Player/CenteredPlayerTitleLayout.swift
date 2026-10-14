import SwiftUI

/// Center the title itself. Badges start after its trailing edge and reserve
/// matching space on the left when a long title needs to truncate.
struct CenteredPlayerTitleLayout: Layout {
    var spacing: CGFloat = 8

    private func sizes(width: CGFloat, subviews: Subviews) -> (title: CGSize, badges: CGSize) {
        let badges = subviews[1].sizeThatFits(.unspecified)
        let titleWidth = max(0, width - 2 * (badges.width + spacing))
        let title = subviews[0].sizeThatFits(ProposedViewSize(width: titleWidth, height: nil))
        return (title, badges)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let idealTitle = subviews[0].sizeThatFits(.unspecified)
        let idealBadges = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width ?? idealTitle.width + 2 * (idealBadges.width + spacing)
        let size = sizes(width: width, subviews: subviews)
        return CGSize(width: width, height: max(size.title.height, size.badges.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let size = sizes(width: bounds.width, subviews: subviews)
        subviews[0].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(size.title))
        subviews[1].place(at: CGPoint(x: bounds.midX + size.title.width / 2 + spacing, y: bounds.midY),
                          anchor: .leading, proposal: ProposedViewSize(size.badges))
    }
}
