import Foundation

/// The ruby layout maths that touches neither Core Text nor the UI types.
///
/// The karaoke wipe is driven by one opacity per character of the base text.
/// A reading follows the dimmest character it sits over, so it never lights up
/// ahead of the kanji it belongs to, and an annotated run fades as a whole, on
/// the mean of the characters it covers. Keeping that bookkeeping here lets the
/// Core target carry the ruby text engine without pulling in a render pipeline.
public enum RubyTextEngine {
    /// The opacity a single segment of a lyric line fades to.
    public struct Shading: Hashable {
        /// One opacity per character of the segment's base text, for runs that
        /// can be coloured character by character.
        public let characters: [Double]
        /// The single opacity applied to an annotated run together with its
        /// reading.
        public let level: Double
    }

    /// Spreads `alphas` over the segments of a line, one entry per segment and
    /// in order. A line without an alpha curve is fully opaque.
    public static func shading(for segments: [RubySegment], alphas: [Double]?) -> [Shading] {
        guard let alphas else {
            return segments.map { _ in Shading(characters: [], level: 1) }
        }
        var cursor = 0
        return segments.map { segment in
            let start = cursor
            cursor += segment.text.count
            // Text longer than the alpha curve stays fully lit.
            let characters = (start..<cursor).map { $0 < alphas.count ? alphas[$0] : 1 }
            let level = characters.reduce(0, +) / Double(max(characters.count, 1))
            return Shading(characters: characters, level: level)
        }
    }
}
